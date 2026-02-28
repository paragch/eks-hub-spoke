# EKS Hub-and-Spoke Infrastructure

Three EKS clusters across three dedicated AWS accounts, connected by AWS Transit Gateway and managed by Terraform + ArgoCD GitOps.

| Cluster | Name | Account | VPC CIDR | ArgoCD Mode | Node Type |
|---|---|---|---|---|---|
| Hub | `eks-hub` | hub account | `10.0.0.0/16` | HA (2 replicas, LoadBalancer) | t3.medium |
| Dev spoke | `eks-dev` | dev account | `10.1.0.0/16` | Single replica, ClusterIP | t3.medium |
| Prod spoke | `eks-prod` | prod account | `10.2.0.0/16` | Single replica, ClusterIP | t3.large |

## Architecture

```
Management Account
  └── bootstrap/          S3 + DynamoDB state backend
  └── envs/accounts/      Creates hub / dev / prod member accounts (AWS Organizations)

Hub Account               eks-hub  +  ArgoCD HA  +  Transit Gateway
Dev Account               eks-dev  +  ArgoCD spoke
Prod Account              eks-prod +  ArgoCD spoke

Connectivity
  Transit Gateway (hub account)
  ├── RAM-shared to dev account  → VPC attachment + routes
  └── RAM-shared to prod account → VPC attachment + routes

GitOps (Hub ArgoCD)
  ├── registers eks-dev + eks-prod via Kubernetes cluster secrets
  ├── infra-apps ApplicationSet  → cert-manager to each spoke
  └── spoke-apps ApplicationSet → gitops/apps/{env}/* to matching spoke
```

VPCs are connected via AWS Transit Gateway. The TGW lives in the hub account and is shared to dev and prod via AWS RAM. All cross-account attachments, routes, and cluster security group rules (port 443 for ArgoCD → API server) are managed from the hub workspace using aliased Terraform providers.

## Prerequisites

- Terraform >= 1.6
- AWS CLI with management account credentials
- `kubectl`, `helm`, and `jq`
- AWS Organizations enabled on the management account

## Quick Start

### Option A — One command (recommended)

Fill in the three email addresses in `envs/accounts/terraform.tfvars`, then:

```bash
./scripts/startup.sh
```

This script handles everything end-to-end:
1. Creates the S3 state bucket + DynamoDB lock table
2. Provisions hub / dev / prod member accounts
3. Polls until `OrganizationAccountAccessRole` is assumable in each account
4. Deploys dev + prod clusters in parallel
5. Deploys hub cluster + Transit Gateway
6. Updates your local kubeconfig

**Flags**

| Flag | Effect |
|---|---|
| _(none)_ | Interactive — confirms once before starting, shows `terraform plan` before each apply |
| `--auto-approve` | Non-interactive / CI — skips all prompts, applies without plan review |
| `--reset` | Clears the checkpoint file and starts from scratch |
| `--reset --auto-approve` | Both combined |

**Resume after failure**

Progress is saved to `.startup-progress` after each step completes. If the script fails or is interrupted, re-running it resumes from the first incomplete step — all earlier steps are skipped instantly:

```
--- Step 1 — Bootstrap (bucket: eks-hub-spoke-tfstate-a1b2) (already done — skipping)
--- Step 2 — Accounts (hub: 111111111111  dev: 222222222222  prod: ...) (already done — skipping)
```

To force a full restart from scratch:

```bash
./scripts/startup.sh --reset
```

---

### Option B — Step by step

#### 1. Bootstrap state backend

```bash
./scripts/bootstrap.sh
```

Substitute the bucket name in all config files:

```bash
BUCKET=<output-from-bootstrap>
find envs -name '*.tf' -o -name '*.tfvars' | \
  xargs sed -i '' "s/REPLACE_WITH_STATE_BUCKET/$BUCKET/g"
```

#### 2. Create AWS member accounts

Fill in `envs/accounts/terraform.tfvars` with unique email addresses, then:

```bash
cd envs/accounts && terraform init && terraform apply
```

Note the account IDs from the outputs and substitute them in the tfvars:

```bash
HUB=$(terraform output -raw hub_account_id)
DEV=$(terraform output -raw dev_account_id)
PRD=$(terraform output -raw prod_account_id)

sed -i '' "s/REPLACE_WITH_HUB_ACCOUNT_ID/$HUB/g"  envs/hub/terraform.tfvars
sed -i '' "s/REPLACE_WITH_DEV_ACCOUNT_ID/$DEV/g"  envs/dev/terraform.tfvars  envs/hub/terraform.tfvars
sed -i '' "s/REPLACE_WITH_PROD_ACCOUNT_ID/$PRD/g" envs/prod/terraform.tfvars envs/hub/terraform.tfvars
```

Wait ~2 minutes for `OrganizationAccountAccessRole` to propagate.

#### 3. Deploy clusters

```bash
./scripts/apply-all.sh   # accounts → dev + prod (parallel) → hub
```

#### 4. Get kubeconfigs

```bash
./scripts/get-kubeconfigs.sh
# Creates contexts: hub, dev, prod
```

#### 5. Push gitops/ to GitHub and wire up AppSets

```bash
git remote add origin https://github.com/YOUR_ORG/eks-hub-spoke.git
git push -u origin main

REPO=https://github.com/YOUR_ORG/eks-hub-spoke.git
find gitops -name '*.yaml' | xargs sed -i '' "s|YOUR_REPO_URL|$REPO|g"
git add -A && git commit -m "wire up repo URLs" && git push
```

#### 6. Access ArgoCD UI (hub)

```bash
kubectl --context hub port-forward svc/argocd-server -n argocd 8080:80
# Open http://localhost:8080
# Default admin password:
kubectl --context hub get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath='{.data.password}' | base64 -d
```

---

## Teardown

### Full teardown (recommended)

```bash
./scripts/shutdown.sh
```

Destroys hub → dev+prod (parallel) → accounts state. Prompts separately to remove the S3 backend. AWS accounts are **not** auto-closed (see note below).

**Flags**

| Flag | Effect |
|---|---|
| _(none)_ | Interactive — prompts `'destroy'` confirmation, then asks about the S3 backend at the end |
| `--reset` | Clears the checkpoint file and starts from scratch |

**Resume after failure**

Progress is saved to `.shutdown-progress` after each step completes. Re-running resumes from the first incomplete step — the `'destroy'` confirmation is not shown again:

```
✓ hub
○ spokes     ← resumes here
○ accounts
○ bootstrap
```

To force a full restart:

```bash
./scripts/shutdown.sh --reset
```

### Clusters only (keep accounts and state backend)

```bash
./scripts/teardown.sh   # hub → dev + prod (parallel) → accounts state
```

> **Note on account closure**: `aws_organizations_account` is created with `close_on_deletion = false`. Running `terraform destroy` removes the resource from state but does **not** close the AWS account. To permanently close an account:
> ```bash
> aws organizations close-account --account-id <ACCOUNT_ID>
> ```

---

## Directory Structure

```
eks-hub-spoke/
├── bootstrap/                # One-time: S3 bucket + DynamoDB lock table
├── modules/
│   ├── vpc/                  # VPC, subnets, IGW, NAT gateways, route tables
│   ├── eks-cluster/          # EKS cluster, managed node group, addons, KMS
│   ├── iam/                  # Cluster/node roles + OIDC provider (two-phase)
│   ├── argocd/               # Helm release for argo-cd 7.8.26; mode=hub|spoke
│   ├── karpenter/            # Karpenter IRSA, Helm release, EC2NodeClass, NodePool
│   ├── transit-gateway/      # TGW, RAM share, cross-account attachments + routes
│   └── vpc-peering/          # (legacy — superseded by transit-gateway)
├── envs/
│   ├── accounts/             # AWS Organizations member account provisioning
│   ├── hub/                  # Hub EKS + ArgoCD Hub + Transit Gateway
│   ├── dev/                  # Dev spoke EKS + ArgoCD spoke
│   └── prod/                 # Prod spoke EKS + ArgoCD spoke
├── gitops/
│   ├── hub/projects/         # ArgoCD AppProject definitions
│   ├── hub/appsets/          # ArgoCD ApplicationSet definitions
│   ├── infra/                # cert-manager Helm values per env
│   ├── apps/                 # Per-env app manifests (podinfo example)
│   └── spoke-root/           # Root Application per spoke (app-of-apps)
└── scripts/
    ├── startup.sh            # Full from-zero bring-up
    ├── shutdown.sh           # Full teardown including accounts
    ├── bootstrap.sh          # State backend only
    ├── apply-all.sh          # (Re)apply all envs
    ├── teardown.sh           # Destroy clusters + accounts state
    └── get-kubeconfigs.sh    # Update kubeconfig for all clusters
```

## Apply Order

```
bootstrap → accounts → dev + prod (parallel) → hub
```

Hub reads dev and prod remote state to supply VPC/subnet/SG IDs to the transit-gateway module, so the spokes must be applied first.

## Key Design Decisions

| Decision | Detail |
|---|---|
| **Multi-account** | One AWS account per cluster; provisioned via `aws_organizations_account` |
| **Cross-account auth** | `OrganizationAccountAccessRole` — created automatically by Organizations in every member account |
| **Transit Gateway** | Owned by hub account; shared to dev + prod via AWS RAM; `auto_accept_shared_attachments = enable` |
| **TGW managed from hub** | All cross-account TGW resources (attachments, routes, SG rules) are created from the hub workspace using `aws.dev` / `aws.prod` aliased providers — dev and prod workspaces have no TGW resources |
| **RAM propagation delay** | 30 s `time_sleep` before cross-account VPC attachments to avoid `TransitGatewayNotFound` errors |
| **Provider auth** | `assume_role { role_arn }` in every AWS provider; `--role-arn` appended to all `aws eks get-token` exec args |
| **State backend** | S3 + DynamoDB in management account; hub reads dev/prod via `terraform_remote_state` |
| **ArgoCD chart** | `7.8.26` (ArgoCD 2.13.x) |
| **Karpenter** | Deployed on all three clusters via IRSA; EC2NodeClass + NodePool configured for spot/on-demand |
| **SA token** | Long-lived `kubernetes.io/service-account-token` for `argocd-manager` (encrypted in S3 state) |

## Important Notes

1. **Unique emails**: each `aws_organizations_account` requires a globally unique root email address.
2. **Account closure**: `terraform destroy` on `envs/accounts` removes accounts from state but does **not** close them. Close manually if needed.
3. **State bucket access**: the S3 backend uses management-account credentials. If running from CI with member-account roles, add an S3 bucket policy granting the member roles read/write.
4. **`YOUR_REPO_URL`** in appsets and spoke-root manifests must be replaced with your actual GitHub URL after pushing.
5. **Production hardening**: SA tokens are stored in S3 state (AES256 encrypted) — consider AWS Secrets Manager for production workloads. Add `aws-ebs-csi-driver` addon if workloads require PVCs.
