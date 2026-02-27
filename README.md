# EKS Hub-and-Spoke Infrastructure

Three EKS clusters in a hub-and-spoke topology managed by Terraform + ArgoCD GitOps.

| Cluster | Name | VPC CIDR | ArgoCD Mode | Node Type |
|---|---|---|---|---|
| Hub | `eks-hub` | `10.0.0.0/16` | HA (2 replicas, LoadBalancer) | t3.medium |
| Dev spoke | `eks-dev` | `10.1.0.0/16` | Single replica, ClusterIP | t3.medium |
| Prod spoke | `eks-prod` | `10.2.0.0/16` | Single replica, ClusterIP | t3.large |

## Architecture

```
Hub ArgoCD
├── registers eks-dev + eks-prod via cluster secrets
├── infra-apps ApplicationSet  → deploys cert-manager to each spoke
└── spoke-apps ApplicationSet  → deploys gitops/apps/{env}/* to matching spoke
```

VPCs are connected via same-account/region VPC peering (auto-accept). Hub → spoke 443 ingress is permitted via security group rules.

## Prerequisites

- Terraform >= 1.6
- AWS CLI + credentials configured
- `kubectl` and `helm` (for local interaction post-deploy)

## Quick Start

### 1. Bootstrap state backend

```bash
./scripts/bootstrap.sh us-east-1
```

Update the bucket name in all three `backend.tf` files and `envs/hub/terraform.tfvars`:

```bash
BUCKET=<output-from-bootstrap>
find envs -name '*.tf' -o -name '*.tfvars' | \
  xargs sed -i '' "s/REPLACE_WITH_STATE_BUCKET/$BUCKET/g"
```

### 2. Apply in order (dev → prod → hub)

```bash
./scripts/apply-all.sh
```

Hub's `terraform_remote_state` requires dev and prod state to exist first.

### 3. Get kubeconfigs

```bash
./scripts/get-kubeconfigs.sh
# Creates contexts: hub, dev, prod
```

### 4. Push gitops/ to GitHub and wire up AppSets

```bash
git remote add origin https://github.com/YOUR_ORG/eks-hub-spoke.git
git push -u origin main

# Replace YOUR_REPO_URL placeholder
REPO=https://github.com/YOUR_ORG/eks-hub-spoke.git
find gitops -name '*.yaml' | xargs sed -i '' "s|YOUR_REPO_URL|$REPO|g"
git add -A && git commit -m "wire up repo URLs" && git push
```

### 5. Access ArgoCD UI (hub)

```bash
kubectl --context hub port-forward svc/argocd-server -n argocd 8080:80
# Open http://localhost:8080
# Default admin password:
kubectl --context hub get secret argocd-initial-admin-secret \
  -n argocd -o jsonpath='{.data.password}' | base64 -d
```

### 6. Teardown

```bash
./scripts/teardown.sh   # hub → dev → prod
cd bootstrap && terraform destroy  # removes S3 + DynamoDB
```

## Directory Structure

```
eks-hub-spoke/
├── bootstrap/           # One-time: S3 bucket + DynamoDB lock table
├── modules/
│   ├── vpc/             # VPC, subnets, IGW, NAT, route tables
│   ├── eks-cluster/     # EKS cluster, node group, addons, KMS
│   ├── iam/             # Cluster/node roles + OIDC provider (two-phase)
│   ├── argocd/          # helm_release for argo-cd 7.8.26; mode=hub|spoke
│   └── vpc-peering/     # VPC peering + routes + SG rules
├── envs/
│   ├── hub/             # Hub cluster + ArgoCD Hub + VPC peering + cluster secrets
│   ├── dev/             # Dev spoke + ArgoCD Spoke + argocd-manager SA
│   └── prod/            # Prod spoke (mirror of dev)
├── gitops/
│   ├── hub/projects/    # AppProject definitions
│   ├── hub/appsets/     # ApplicationSet definitions
│   ├── infra/           # cert-manager helm values per env
│   ├── apps/            # Per-env app manifests (podinfo example)
│   └── spoke-root/      # Root Application per spoke (app-of-apps)
└── scripts/             # bootstrap, apply-all, get-kubeconfigs, teardown
```

## Key Design Decisions

- **Apply order**: dev → prod → hub (hub reads spoke remote state)
- **State backend**: S3 + DynamoDB, hub reads dev/prod via `terraform_remote_state`
- **SA token**: Long-lived `kubernetes.io/service-account-token` for `argocd-manager` (stored encrypted in S3 state)
- **VPC peering**: Same account/region, `auto_accept=true`
- **ArgoCD chart**: `7.8.26` (ArgoCD 2.13.x)
- **Cluster secrets**: Created after 60s `time_sleep` post-ArgoCD Helm release

## Important Notes

1. `YOUR_REPO_URL` in appsets and spoke-root manifests must be replaced with your actual GitHub URL after pushing
2. VPC peering `auto_accept=true` requires same AWS account + region; cross-account needs a separate accepter resource
3. SA tokens are stored in S3 state (AES256 encrypted) — use AWS Secrets Manager for production
4. Add `aws-ebs-csi-driver` addon + `AmazonEBSCSIDriverPolicy` if workloads require PVCs
