# EKS Hub-and-Spoke Infrastructure

Four EKS clusters across five dedicated AWS accounts (including one database-only account), connected by AWS Transit Gateway and managed by Terraform + ArgoCD GitOps.

> For a detailed breakdown of the internal architecture, provider wiring, network routing, and startup sequence see **[docs/low-level-design.md](docs/low-level-design.md)**.

| Cluster | Name | Account | VPC CIDR | ArgoCD Mode | Node Type | Extra capabilities |
|---|---|---|---|---|---|---|
| Hub | `eks-hub` | hub account | `10.0.0.0/16` | HA (2 replicas, LoadBalancer) | t3.medium | — |
| Dev spoke | `eks-dev` | dev account | `10.1.0.0/16` | Single replica, ClusterIP | t3.medium | Istio service mesh |
| Prod spoke | `eks-prod` | prod account | `10.2.0.0/16` | Single replica, ClusterIP | t3.large | EMR on EKS · MSK · Amazon MQ · JupyterHub · db-writer |
| Data spoke | `eks-data` | data account | `10.3.0.0/16` | Single replica, ClusterIP | t3.large | Istio · EMR on EKS · MSK · Amazon MQ · JupyterHub |
| _(none)_ | — | prod-data account | `10.4.0.0/16` | — | — | OpenSearch · Aurora PostgreSQL · Neptune (VPC-peered to prod only) |

## Architecture

```
Management Account
  └── bootstrap/          S3 + DynamoDB state backend
  └── envs/accounts/      Creates hub / dev / prod / data / prod-data member accounts (AWS Organizations)

Hub Account               eks-hub  +  ArgoCD HA  +  Transit Gateway
Dev Account               eks-dev  +  ArgoCD spoke  +  Istio
Prod Account              eks-prod +  ArgoCD spoke  +  EMR on EKS  +  MSK  +  Amazon MQ  +  JupyterHub  +  db-writer
Data Account              eks-data +  ArgoCD spoke  +  Istio  +  EMR on EKS  +  MSK  +  Amazon MQ  +  JupyterHub
Prod-Data Account         No EKS  +  OpenSearch  +  Aurora PostgreSQL  +  Neptune

Connectivity
  Transit Gateway (hub account)
  ├── RAM-shared to dev account       → VPC attachment + routes
  ├── RAM-shared to prod account      → VPC attachment + routes
  └── RAM-shared to data account      → VPC attachment + routes

  VPC Peering (prod-data workspace)
  └── prod ↔ prod-data (10.2.0.0/16 ↔ 10.4.0.0/16) — isolated, no TGW attachment

GitOps (Hub ArgoCD)
  ├── registers eks-dev + eks-prod + eks-data via Kubernetes cluster secrets
  ├── infra-apps ApplicationSet  → cert-manager to each spoke
  └── spoke-apps ApplicationSet → gitops/apps/{env}/* to matching spoke
```

VPCs are connected via AWS Transit Gateway. The TGW lives in the hub account and is shared to dev and prod via AWS RAM. All cross-account attachments, routes, and cluster security group rules (port 443 from hub VPC to each spoke cluster) are managed from the hub workspace using aliased Terraform providers.

## Prerequisites

- Terraform >= 1.6
- AWS CLI with management account credentials
- `kubectl`, `helm`, and `jq`
- AWS Organizations enabled on the management account

## Quick Start

### Option A — One command (recommended)

Copy the accounts template and fill in five unique email addresses:

```bash
cp envs/accounts/terraform.tfvars.example envs/accounts/terraform.tfvars
# edit envs/accounts/terraform.tfvars — set hub_account_email, dev_account_email, prod_account_email, data_account_email, prod_data_account_email
```

Then run:

```bash
./scripts/startup.sh
```

This script handles everything end-to-end:
1. Creates the S3 state bucket + DynamoDB lock table
2. Provisions hub / dev / prod / data / prod-data member accounts
3. Polls until `OrganizationAccountAccessRole` is assumable in each account
4. Deploys dev + prod + data clusters in parallel
5. Deploys hub cluster + Transit Gateway
6. Deploys prod-data databases (OpenSearch/Aurora/Neptune) + db-writer microservice
7. Updates your local kubeconfig

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
find envs -name 'backend.tf' -o -name 'terraform.tfvars' | \
  xargs sed -i '' "s/REPLACE_WITH_STATE_BUCKET/$BUCKET/g"
```

#### 2. Create AWS member accounts

Copy and fill in the accounts template with unique email addresses:

```bash
cp envs/accounts/terraform.tfvars.example envs/accounts/terraform.tfvars
# edit envs/accounts/terraform.tfvars
```

Then:

```bash
cd envs/accounts && terraform init && terraform apply
```

Note the account IDs from the outputs and substitute them in the tfvars:

```bash
HUB=$(terraform output -raw hub_account_id)
DEV=$(terraform output -raw dev_account_id)
PRD=$(terraform output -raw prod_account_id)
DAT=$(terraform output -raw data_account_id)

# Copy remaining templates first (if not already done)
for env in dev prod data hub; do
  cp envs/$env/terraform.tfvars.example envs/$env/terraform.tfvars
done

sed -i '' "s/REPLACE_WITH_HUB_ACCOUNT_ID/$HUB/g"   envs/hub/terraform.tfvars
sed -i '' "s/REPLACE_WITH_DEV_ACCOUNT_ID/$DEV/g"   envs/dev/terraform.tfvars  envs/hub/terraform.tfvars
sed -i '' "s/REPLACE_WITH_PROD_ACCOUNT_ID/$PRD/g"  envs/prod/terraform.tfvars envs/hub/terraform.tfvars
sed -i '' "s/REPLACE_WITH_DATA_ACCOUNT_ID/$DAT/g"  envs/data/terraform.tfvars envs/hub/terraform.tfvars
```

Wait ~2 minutes for `OrganizationAccountAccessRole` to propagate.

#### 3. Deploy clusters

```bash
./scripts/apply-all.sh
```

Applies accounts → dev+prod+data (parallel) → hub. Saves progress to `.apply-all-progress` — re-running resumes from the first incomplete step. Use `--reset` to restart from scratch.

#### 4. Get kubeconfigs

```bash
./scripts/get-kubeconfigs.sh
# Creates contexts: hub, dev, prod, data
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

Destroys hub → dev+prod+data (parallel) → accounts state. Prompts separately to remove the S3 backend. AWS accounts are **not** auto-closed (see note below).

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
./scripts/teardown.sh
```

Destroys hub → dev+prod+data (parallel) → accounts state. Saves progress to `.teardown-progress` — re-running resumes from the first incomplete step, skipping the `'yes'` confirmation. Use `--reset` to restart from scratch.

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
│   ├── vpc/                          # VPC, subnets, IGW, NAT gateways, route tables
│   ├── eks-cluster/                  # EKS cluster, managed node group, addons, KMS
│   ├── iam/                          # Cluster/node roles + OIDC provider (two-phase)
│   ├── argocd/                       # Helm release for argo-cd 7.8.26; mode=hub|spoke
│   ├── karpenter/                    # Karpenter IRSA, Helm release, EC2NodeClass, NodePool
│   ├── aws-load-balancer-controller/ # AWS LBC Pod Identity, Helm release (all four clusters)
│   ├── istio/                        # Istio base + istiod + ingress gateway (Helm)
│   ├── emr-on-eks/                   # EMR virtual cluster, RBAC, Pod Identity, S3 landing zone, EKS access entry
│   ├── msk/                          # MSK Kafka cluster (Kafka 3.6.0, IAM/TLS, port 9098)
│   ├── amazon-mq/                    # Amazon MQ ActiveMQ broker (ACTIVE_STANDBY_MULTI_AZ, AMQP+SSL)
│   ├── jupyterhub/                   # JupyterHub PySpark notebook environment + NLB
│   ├── transit-gateway/              # TGW, RAM share, cross-account attachments + routes
│   ├── vpc-peering/                  # (legacy — superseded by transit-gateway)
│   ├── opensearch/                   # Amazon OpenSearch domain (VPC, IAM access, AZ-aware)
│   ├── aurora/                       # Aurora PostgreSQL cluster + instances
│   └── neptune/                      # Amazon Neptune cluster + instances (IAM auth)
├── envs/
│   ├── accounts/             # AWS Organizations member account provisioning
│   ├── hub/                  # Hub EKS + ArgoCD Hub + Transit Gateway
│   ├── dev/                  # Dev spoke EKS + ArgoCD spoke + Istio
│   ├── prod/                 # Prod spoke EKS + ArgoCD spoke + EMR on EKS
│   ├── data/                 # Data spoke EKS + ArgoCD spoke + Istio + EMR on EKS
│   └── prod-data/            # prod-data account: OpenSearch + Aurora + Neptune + db-writer microservice
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
bootstrap → accounts → dev + prod + data (parallel) → hub → prod-data
```

Hub reads dev, prod, and data remote state to supply VPC/subnet/SG IDs to the transit-gateway module, so the spokes must be applied first. prod-data reads prod remote state (cluster endpoint, VPC, MQ URL) and must be applied after prod.

## Key Design Decisions

| Decision | Detail |
|---|---|
| **Multi-account** | One AWS account per cluster; provisioned via `aws_organizations_account` |
| **Cross-account auth** | `OrganizationAccountAccessRole` — created automatically by Organizations in every member account |
| **Transit Gateway** | Owned by hub account; shared to dev + prod + data via AWS RAM; `auto_accept_shared_attachments = enable` |
| **TGW managed from hub** | All cross-account TGW resources (attachments, routes, SG rules) are created from the hub workspace using `aws.dev` / `aws.prod` / `aws.data` aliased providers — spoke workspaces have no TGW resources |
| **Istio** | Deployed via 3 `helm_release` resources (`base` → `istiod` → `gateway`) from the official Istio chart repo; enabled on dev and data spokes |
| **EMR on EKS** | Virtual cluster + RBAC + Pod Identity role per cluster; enabled on prod and data spokes |
| **EMR Pod Identity** | Job execution IAM role trusted by `pods.eks.amazonaws.com`; `aws_eks_pod_identity_association` binds it to the `emr-job-runner` SA in the `emr-jobs` namespace — no OIDC issuer URL needed |
| **EMR landing zone** | Per-account S3 bucket (`<cluster>-landing-zone-<account_id>`, AES256, versioned, public-access-blocked) for parquet source files; job execution role scoped to that bucket's ARN only |
| **MSK (Managed Kafka)** | Per-account MSK cluster (Kafka 3.6.0, IAM/TLS auth port 9098, `kafka.m5.large`) in prod and data accounts; EMR Spark jobs write results to topics; `kafka-cluster:*` IAM actions scoped to the specific cluster/topic/group ARNs |
| **Amazon MQ** | ActiveMQ `ACTIVE_STANDBY_MULTI_AZ` broker in each EMR account (prod, data), co-located in the same VPC as MSK; a Kafka consumer bridge (EKS Deployment) reads from MSK topics and publishes to Amazon MQ queues/topics via AMQP+SSL (port 5671); all four VPCs consume from Amazon MQ over the Transit Gateway — no additional routing changes required |
| **Amazon MQ cross-account access** | MQ security group allows `10.0.0.0/8` (all VPC CIDRs) on AMQP+SSL (5671), OpenWire+SSL (61617), STOMP+SSL (61614), MQTT+SSL (8883); web console (8162) restricted to local VPC only |
| **MQ credentials** | Username/password via `mq_username` / `mq_password` sensitive variables; stored in Terraform state (S3, AES256 encrypted); set `REPLACE_WITH_MQ_PASSWORD` in `terraform.tfvars` before first apply |
| **VPC peering (not TGW) for prod-data** | Enforces "prod only" isolation — peering is point-to-point; no routing to hub, dev, or data accounts. Transit Gateway is not used for prod-data |
| **No EKS in prod-data** | Pure managed-DB account; db-writer microservice runs on existing `eks-prod` cluster |
| **prod-data workspace deploys into eks-prod** | Uses aliased `aws.prod` provider + kubernetes provider targeting eks-prod; prod-data workspace owns all integration resources (peering, IAM, K8s objects) |
| **Neptune IAM auth** | `enable_iam_database_authentication = true`; db-writer IAM role gets `neptune-db:*` — no passwords for the graph DB |
| **Aurora password auth** | Aurora PostgreSQL uses username/password; DB password stored as Kubernetes Secret in the `db-writer` namespace on eks-prod |
| **OpenSearch domain policy** | `aws_opensearch_domain_policy` grants `es:ESHttp*` to db-writer IAM role ARN — IAM-based access, no Cognito |
| **prod-data isolation** | prod-data VPC (`10.4.0.0/16`) is peered only with prod; fully isolated from hub, dev, data, and the Transit Gateway |
| **Spark History Server** | Kubernetes Deployment in `emr-jobs` namespace reading event logs from `s3://<landing_zone>/spark-logs/`; runs under `emr-job-runner` SA (Pod Identity for S3 access); ClusterIP service on port 18080 |
| **JupyterHub** | PySpark notebook environment per EMR cluster (`quay.io/jupyter/pyspark-notebook`); Pod Identity reuses EMR job execution role so notebooks access S3 and MSK with the same permissions as Spark jobs; NLB proxy via AWS Load Balancer Controller |
| **AWS Load Balancer Controller** | Deployed on all four clusters via Pod Identity; provisions NLBs (for ArgoCD, Istio gateway, JupyterHub) and ALBs (for app `Ingress` resources with `ingressClassName: alb`) |
| **EBS CSI driver** | `aws-ebs-csi-driver` EKS addon on all clusters (IAM via `AmazonEBSCSIDriverPolicy` on node role); required for JupyterHub persistent notebook PVCs |
| **RAM propagation delay** | 30 s `time_sleep` before cross-account VPC attachments to avoid `TransitGatewayNotFound` errors |
| **Provider auth** | `assume_role { role_arn }` in every AWS provider; `--role-arn` appended to all `aws eks get-token` exec args |
| **State backend** | S3 + DynamoDB in management account; hub reads dev/prod/data via `terraform_remote_state` |
| **ArgoCD chart** | `7.8.26` (ArgoCD 2.13.x) |
| **Karpenter** | Deployed on all four clusters via IRSA; EC2NodeClass + NodePool configured for spot/on-demand |
| **SA token** | Long-lived `kubernetes.io/service-account-token` for `argocd-manager` (encrypted in S3 state) |

## Important Notes

1. **Unique emails**: each `aws_organizations_account` requires a globally unique root email address (now five total: hub, dev, prod, data, prod-data).
2. **Account closure**: `terraform destroy` on `envs/accounts` removes accounts from state but does **not** close them. Close manually if needed.
3. **State bucket access**: the S3 backend uses management-account credentials. If running from CI with member-account roles, add an S3 bucket policy granting the member roles read/write.
4. **`YOUR_REPO_URL`** in appsets and spoke-root manifests must be replaced with your actual GitHub URL after pushing.
5. **Production hardening**: SA tokens are stored in S3 state (AES256 encrypted) — consider AWS Secrets Manager for production workloads. Amazon MQ passwords are also in state; rotate via `mq_password` variable + `terraform apply`.
7. **Amazon MQ password**: set `mq_password` in `envs/prod/terraform.tfvars` and `envs/data/terraform.tfvars` before the first apply. The placeholder `REPLACE_WITH_MQ_PASSWORD` in `terraform.tfvars.example` must be replaced with a string of 12–250 characters.
8. **prod-data credentials**: set `aurora_db_password` and `mq_password` (must match prod) in `envs/prod-data/terraform.tfvars`. Set `db_writer_image` to your container registry image for the db-writer microservice.
9. **db-writer image**: the `REPLACE_WITH_DB_WRITER_IMAGE` placeholder in `envs/prod-data/terraform.tfvars.example` must be replaced with a valid container image reference before applying prod-data.
6. **EMR service-linked role**: `aws_eks_access_entry.emr` references `AWSServiceRoleForAmazonEMRContainers` — this role is created automatically the first time you use EMR on EKS in an account. If the apply fails on a brand-new account, run `aws iam create-service-linked-role --aws-service-name emr-containers.amazonaws.com` first.
