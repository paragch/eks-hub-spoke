# Low-Level Design — eks-hub-spoke

This document describes the internal architecture of the eks-hub-spoke platform: how the AWS accounts relate to each other, how Terraform state and providers flow between workspaces, how the network is wired together, and how ArgoCD delivers workloads to the spoke clusters.

---

## Table of Contents

1. [AWS Account Hierarchy](#1-aws-account-hierarchy)
2. [Terraform Workspace & State Flow](#2-terraform-workspace--state-flow)
3. [Cross-Account Provider Wiring](#3-cross-account-provider-wiring)
4. [Network Topology](#4-network-topology)
5. [Transit Gateway Routing](#5-transit-gateway-routing)
6. [ArgoCD GitOps Flow](#6-argocd-gitops-flow)
7. [Startup Sequence](#7-startup-sequence)

---

## 1. AWS Account Hierarchy

The management account owns the AWS Organizations root. Three member accounts are provisioned by Terraform — one per cluster. The `OrganizationAccountAccessRole` is created automatically by Organizations in every new member account and is the single mechanism used for all cross-account access.

```mermaid
graph TD
  MGMT["Management Account<br/>(pre-existing)<br/>runs bootstrap + accounts workspaces"]

  ORG["AWS Organizations"]

  HUB["Hub Account<br/>eks-hub cluster<br/>Transit Gateway<br/>ArgoCD HA"]
  DEV["Dev Account<br/>eks-dev cluster<br/>ArgoCD spoke"]
  PROD["Prod Account<br/>eks-prod cluster<br/>ArgoCD spoke"]

  ROLE_HUB["OrganizationAccountAccessRole"]
  ROLE_DEV["OrganizationAccountAccessRole"]
  ROLE_PROD["OrganizationAccountAccessRole"]

  MGMT --> ORG
  ORG -->|aws_organizations_account| HUB
  ORG -->|aws_organizations_account| DEV
  ORG -->|aws_organizations_account| PROD

  HUB --> ROLE_HUB
  DEV --> ROLE_DEV
  PROD --> ROLE_PROD

  MGMT -->|assume_role| ROLE_HUB
  MGMT -->|assume_role| ROLE_DEV
  MGMT -->|assume_role| ROLE_PROD
```

---

## 2. Terraform Workspace & State Flow

All workspaces share a single S3 bucket (in the management account) for remote state. The hub workspace reads dev and prod state to obtain VPC and subnet IDs needed by the Transit Gateway module.

```mermaid
graph TD
  S3[("S3 State Bucket<br/>+ DynamoDB Lock<br/>(management account)")]

  subgraph mgmt["Management Account — Terraform executor"]
    WS_BOOT["bootstrap workspace<br/>creates S3 + DynamoDB"]
    WS_ACCT["accounts workspace<br/>creates member accounts<br/>key: accounts/terraform.tfstate"]
  end

  subgraph hub_acc["Hub Account"]
    WS_HUB["hub workspace<br/>key: hub/terraform.tfstate"]
  end

  subgraph dev_acc["Dev Account"]
    WS_DEV["dev workspace<br/>key: dev/terraform.tfstate"]
  end

  subgraph prod_acc["Prod Account"]
    WS_PROD["prod workspace<br/>key: prod/terraform.tfstate"]
  end

  WS_BOOT -->|creates| S3
  WS_ACCT -->|writes| S3
  WS_DEV  -->|writes| S3
  WS_PROD -->|writes| S3
  WS_HUB  -->|writes| S3

  S3 -->|terraform_remote_state dev| WS_HUB
  S3 -->|terraform_remote_state prod| WS_HUB
  S3 -->|terraform_remote_state accounts| WS_HUB
```

### Remote state outputs consumed by hub

| Source workspace | Outputs read by hub |
|---|---|
| `dev` | `vpc_id`, `vpc_cidr`, `private_subnet_ids`, `private_route_table_ids`, `cluster_security_group_id`, `cluster_endpoint`, `cluster_certificate_authority_data`, `argocd_manager_token` |
| `prod` | same set as dev |
| `accounts` | reference only (account IDs come from `var.*_account_id`) |

---

## 3. Cross-Account Provider Wiring

The hub workspace declares four AWS provider instances. The default (unaliased) provider and `aws.hub` both assume a role in the hub account — the default is used by all existing hub resources (VPC, EKS, IAM, ArgoCD), while `aws.hub` is passed explicitly into the transit-gateway module. `aws.dev` and `aws.prod` create resources directly inside the spoke accounts without requiring any Terraform code in those workspaces.

```mermaid
graph LR
  subgraph providers["envs/hub/providers.tf"]
    P_DEFAULT["provider aws (default)<br/>assume_role → hub account"]
    P_HUB["provider aws.hub<br/>assume_role → hub account"]
    P_DEV["provider aws.dev<br/>assume_role → dev account"]
    P_PROD["provider aws.prod<br/>assume_role → prod account"]
  end

  subgraph tgw_module["modules/transit-gateway/main.tf"]
    TGW["aws_ec2_transit_gateway<br/>aws_ram_resource_share<br/>aws_ram_principal_association"]
    ATT_HUB["aws_ec2_transit_gateway<br/>_vpc_attachment.hub"]
    ATT_DEV["aws_ec2_transit_gateway<br/>_vpc_attachment.dev"]
    ATT_PROD["aws_ec2_transit_gateway<br/>_vpc_attachment.prod"]
    RT_HUB["aws_route hub→dev<br/>aws_route hub→prod"]
    RT_DEV["aws_route dev→hub"]
    RT_PROD["aws_route prod→hub"]
    SG_DEV["aws_security_group_rule<br/>hub→dev :443"]
    SG_PROD["aws_security_group_rule<br/>hub→prod :443"]
  end

  P_HUB  --> TGW
  P_HUB  --> ATT_HUB
  P_HUB  --> RT_HUB
  P_DEV  --> ATT_DEV
  P_DEV  --> RT_DEV
  P_DEV  --> SG_DEV
  P_PROD --> ATT_PROD
  P_PROD --> RT_PROD
  P_PROD --> SG_PROD

  P_DEFAULT -->|"VPC, EKS, IAM<br/>ArgoCD, Karpenter<br/>(existing hub resources)"| hub_res["Hub account resources"]
```

---

## 4. Network Topology

The Transit Gateway lives in the hub account and is shared to the spoke accounts via AWS Resource Access Manager (RAM). Each account attaches its private subnets to the TGW. `auto_accept_shared_attachments = enable` removes the need for a manual acceptance step in the spoke accounts.

```mermaid
graph TB
  subgraph mgmt_acc["Management Account"]
    S3_BOX["S3 State Bucket"]
  end

  subgraph hub_acc["Hub Account · 10.0.0.0/16"]
    HUB_PRI["Private Subnets<br/>10.0.10.0/24, 10.0.11.0/24"]
    HUB_EKS["eks-hub"]
    ARGOCD["ArgoCD HA"]
    TGW_BOX["Transit Gateway<br/>auto_accept_shared_attachments = enable"]
    RAM_BOX["RAM Resource Share<br/>→ dev account<br/>→ prod account"]
    TGW_BOX --- RAM_BOX
  end

  subgraph dev_acc["Dev Account · 10.1.0.0/16"]
    DEV_PRI["Private Subnets<br/>10.1.10.0/24, 10.1.11.0/24"]
    DEV_EKS["eks-dev"]
  end

  subgraph prod_acc["Prod Account · 10.2.0.0/16"]
    PROD_PRI["Private Subnets<br/>10.2.10.0/24, 10.2.11.0/24"]
    PROD_EKS["eks-prod"]
  end

  HUB_PRI  <-->|"VPC attachment (hub account)"| TGW_BOX
  DEV_PRI  <-->|"VPC attachment (dev account, via RAM)"| TGW_BOX
  PROD_PRI <-->|"VPC attachment (prod account, via RAM)"| TGW_BOX

  ARGOCD -->|"port 443 via TGW"| DEV_EKS
  ARGOCD -->|"port 443 via TGW"| PROD_EKS
```

---

## 5. Transit Gateway Routing

Six route entries and two security group rules are created by the hub workspace using aliased providers.

```mermaid
flowchart LR
  subgraph hub_rt["Hub private route tables\n(provider: aws.hub)"]
    HR1["10.1.0.0/16 → TGW"]
    HR2["10.2.0.0/16 → TGW"]
  end

  subgraph dev_rt["Dev private route tables\n(provider: aws.dev)"]
    DR1["10.0.0.0/16 → TGW"]
  end

  subgraph prod_rt["Prod private route tables\n(provider: aws.prod)"]
    PR1["10.0.0.0/16 → TGW"]
  end

  TGW_C["Transit Gateway"]

  HR1 --> TGW_C
  HR2 --> TGW_C
  DR1 --> TGW_C
  PR1 --> TGW_C

  subgraph sg_rules["Security group rules"]
    SGD["eks-dev cluster SG\ningress 443 from 10.0.0.0/16\n(provider: aws.dev)"]
    SGP["eks-prod cluster SG\ningress 443 from 10.0.0.0/16\n(provider: aws.prod)"]
  end

  TGW_C -->|"ArgoCD → dev API server"| SGD
  TGW_C -->|"ArgoCD → prod API server"| SGP
```

### RAM share propagation

A `time_sleep` of 30 s is inserted between the RAM principal associations and the cross-account VPC attachments. RAM is eventually consistent — without this delay the spoke accounts would not yet see the TGW, producing a `TransitGatewayNotFound` error.

```
aws_ram_principal_association.dev
aws_ram_principal_association.prod
        │
        │  time_sleep 30s
        ▼
aws_ec2_transit_gateway_vpc_attachment.dev  (provider: aws.dev)
aws_ec2_transit_gateway_vpc_attachment.prod (provider: aws.prod)
```

---

## 6. ArgoCD GitOps Flow

Hub ArgoCD is configured in HA mode (2 replicas). It holds Kubernetes cluster secrets for each spoke, generated from the `argocd_manager` service account token written to the dev and prod remote state.

```mermaid
sequenceDiagram
  participant GH as GitHub<br/>gitops/
  participant ARGOCD as ArgoCD Hub<br/>(eks-hub)
  participant DEV_API as eks-dev<br/>API server
  participant PROD_API as eks-prod<br/>API server

  GH-->>ARGOCD: poll / webhook (ApplicationSet controllers)

  Note over ARGOCD: infra-apps ApplicationSet
  ARGOCD->>DEV_API:  apply cert-manager HelmRelease
  ARGOCD->>PROD_API: apply cert-manager HelmRelease

  Note over ARGOCD: spoke-apps ApplicationSet
  ARGOCD->>DEV_API:  apply gitops/apps/dev/* (podinfo, …)
  ARGOCD->>PROD_API: apply gitops/apps/prod/* (podinfo, …)

  Note over ARGOCD: spoke-root Application (app-of-apps)
  ARGOCD->>DEV_API:  sync spoke-root/dev
  ARGOCD->>PROD_API: sync spoke-root/prod
```

### Cluster secret data flow

```mermaid
graph LR
  subgraph dev_ws["dev workspace (S3 state)"]
    TOK_DEV["argocd_manager_token<br/>(sensitive output)"]
    EP_DEV["cluster_endpoint"]
    CA_DEV["cluster_certificate_authority_data"]
  end

  subgraph prod_ws["prod workspace (S3 state)"]
    TOK_PROD["argocd_manager_token<br/>(sensitive output)"]
    EP_PROD["cluster_endpoint"]
    CA_PROD["cluster_certificate_authority_data"]
  end

  subgraph hub_ws["hub workspace"]
    SEC_DEV["kubernetes_secret<br/>argocd-cluster-eks-dev"]
    SEC_PROD["kubernetes_secret<br/>argocd-cluster-eks-prod"]
  end

  TOK_DEV  --> SEC_DEV
  EP_DEV   --> SEC_DEV
  CA_DEV   --> SEC_DEV
  TOK_PROD --> SEC_PROD
  EP_PROD  --> SEC_PROD
  CA_PROD  --> SEC_PROD

  SEC_DEV  -->|mounted by ArgoCD| ARGOCD["ArgoCD Hub"]
  SEC_PROD -->|mounted by ArgoCD| ARGOCD
```

---

## 7. Startup Sequence

`startup.sh` orchestrates all workspaces in dependency order. Dev and prod are applied in parallel since neither depends on the other.

```mermaid
sequenceDiagram
  participant U  as User
  participant SH as startup.sh
  participant MGMT as Management Account
  participant S3 as S3 State Bucket
  participant HUB as Hub Account
  participant DEV as Dev Account
  participant PROD as Prod Account

  U->>SH: ./scripts/startup.sh

  Note over SH,MGMT: Step 1 — bootstrap
  SH->>MGMT: terraform apply (bootstrap/)
  MGMT-->>S3: create bucket + DynamoDB table
  SH->>SH: sed REPLACE_WITH_STATE_BUCKET → bucket name

  Note over SH,MGMT: Step 2 — accounts
  SH->>MGMT: terraform apply (envs/accounts/)
  MGMT-->>HUB: aws_organizations_account (hub)
  MGMT-->>DEV: aws_organizations_account (dev)
  MGMT-->>PROD: aws_organizations_account (prod)
  SH->>SH: sed REPLACE_WITH_*_ACCOUNT_ID → account IDs

  Note over SH: Step 3 — wait_iam
  SH->>HUB:  poll sts:AssumeRole (OrganizationAccountAccessRole)
  SH->>DEV:  poll sts:AssumeRole (OrganizationAccountAccessRole)
  SH->>PROD: poll sts:AssumeRole (OrganizationAccountAccessRole)

  Note over SH,PROD: Step 4 — spokes (parallel)
  par
    SH->>DEV: assume role → terraform apply (envs/dev/)
    DEV-->>S3: write dev state
  and
    SH->>PROD: assume role → terraform apply (envs/prod/)
    PROD-->>S3: write prod state
  end

  Note over SH,HUB: Step 5 — hub
  SH->>HUB: assume role → terraform apply (envs/hub/)
  HUB->>S3: read dev + prod remote state
  HUB->>DEV:  create TGW attachment + routes + SG rule (aws.dev)
  HUB->>PROD: create TGW attachment + routes + SG rule (aws.prod)
  HUB-->>S3: write hub state

  Note over SH,U: Step 6 — kubeconfig
  SH->>U: aws eks update-kubeconfig (hub, dev, prod)
  U-->>U: contexts: hub · dev · prod ✓
```

---

## Checkpoint files

Each orchestration script writes a checkpoint file to the repo root so that a failed run can be resumed without repeating completed steps.

| Script | Checkpoint file | Steps |
|---|---|---|
| `startup.sh` | `.startup-progress` | prereqs → bootstrap → accounts → wait_iam → spokes → hub → kubeconfig |
| `apply-all.sh` | `.apply-all-progress` | accounts → spokes → hub |
| `teardown.sh` | `.teardown-progress` | hub → spokes → accounts |
| `shutdown.sh` | `.shutdown-progress` | hub → spokes → accounts → bootstrap |

All four checkpoint files are listed in `.gitignore`.
