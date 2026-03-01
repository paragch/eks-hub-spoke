# Low-Level Design — eks-hub-spoke

This document describes the internal architecture of the eks-hub-spoke platform: how the AWS accounts relate to each other, how Terraform state and providers flow between workspaces, how the network is wired together, how ArgoCD delivers workloads to the prod spoke cluster, how EMR on EKS and JupyterHub ingest and process data, how MSK Kafka captures Spark output, how Amazon MQ bridges Kafka topics to downstream consumers, how the prod-data account stores processed data in OpenSearch/Aurora/Neptune, and the end-to-end data flow spanning all AWS components.

---

## Table of Contents

1. [AWS Account Hierarchy](#1-aws-account-hierarchy)
2. [Terraform Workspace & State Flow](#2-terraform-workspace--state-flow)
3. [Cross-Account Provider Wiring](#3-cross-account-provider-wiring)
4. [Network Topology](#4-network-topology)
5. [Transit Gateway Routing](#5-transit-gateway-routing)
6. [ArgoCD GitOps Flow](#6-argocd-gitops-flow)
7. [Startup Sequence](#7-startup-sequence)
8. [EMR on EKS — Pod Identity & S3 Landing Zone](#8-emr-on-eks--pod-identity--s3-landing-zone)
9. [Amazon MQ — Kafka-to-Message-Broker Bridge](#9-amazon-mq--kafka-to-message-broker-bridge)
10. [End-to-End Data Flow](#10-end-to-end-data-flow)
11. [Prod-Data — Isolated Analytics Store](#11-prod-data--isolated-analytics-store)

---

## 1. AWS Account Hierarchy

The management account owns the AWS Organizations root. Three member accounts are provisioned by Terraform — two cluster accounts (hub, prod) and one database-only account (prod-data). The `OrganizationAccountAccessRole` is created automatically by Organizations in every new member account and is the single mechanism used for all cross-account access.

```mermaid
graph TD
  MGMT["Management Account<br/>(pre-existing)<br/>runs bootstrap + accounts workspaces"]

  ORG["AWS Organizations"]

  HUB["Hub Account<br/>eks-hub cluster<br/>Transit Gateway<br/>ArgoCD HA"]
  PROD["Prod Account<br/>eks-prod cluster<br/>ArgoCD spoke<br/>EMR on EKS · MSK · Amazon MQ"]
  PRODDATA["Prod-Data Account<br/>No EKS cluster<br/>OpenSearch · Aurora PostgreSQL · Neptune<br/>VPC-peered to prod only"]

  ROLE_HUB["OrganizationAccountAccessRole"]
  ROLE_PROD["OrganizationAccountAccessRole"]
  ROLE_PRODDATA["OrganizationAccountAccessRole"]

  MGMT --> ORG
  ORG -->|aws_organizations_account| HUB
  ORG -->|aws_organizations_account| PROD
  ORG -->|aws_organizations_account| PRODDATA

  HUB --> ROLE_HUB
  PROD --> ROLE_PROD
  PRODDATA --> ROLE_PRODDATA

  MGMT -->|assume_role| ROLE_HUB
  MGMT -->|assume_role| ROLE_PROD
  MGMT -->|assume_role| ROLE_PRODDATA
```

---

## 2. Terraform Workspace & State Flow

All workspaces share a single S3 bucket (in the management account) for remote state. The hub workspace reads prod state to obtain VPC and subnet IDs needed by the Transit Gateway module and to register the prod cluster in ArgoCD.

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

  subgraph prod_acc["Prod Account"]
    WS_PROD["prod workspace<br/>key: prod/terraform.tfstate"]
  end

  subgraph prod_data_acc["Prod-Data Account"]
    WS_PROD_DATA["prod-data workspace<br/>key: prod-data/terraform.tfstate"]
  end

  WS_BOOT -->|creates| S3
  WS_ACCT -->|writes| S3
  WS_PROD -->|writes| S3
  WS_HUB  -->|writes| S3
  WS_PROD_DATA -->|writes| S3

  S3 -->|terraform_remote_state prod| WS_HUB
  S3 -->|terraform_remote_state accounts| WS_HUB
  S3 -->|terraform_remote_state prod| WS_PROD_DATA
```

### Remote state outputs consumed by hub

| Source workspace | Outputs read by hub |
|---|---|
| `prod` | `vpc_id`, `vpc_cidr`, `private_subnet_ids`, `private_route_table_ids`, `cluster_security_group_id`, `cluster_endpoint`, `cluster_certificate_authority_data`, `argocd_manager_token` |
| `accounts` | reference only (account IDs come from `var.*_account_id`) |

---

## 3. Cross-Account Provider Wiring

The hub workspace declares three AWS provider instances. The default (unaliased) provider and `aws.hub` both assume a role in the hub account — the default is used by all existing hub resources (VPC, EKS, IAM, ArgoCD), while `aws.hub` is passed explicitly into the transit-gateway module. `aws.prod` creates resources directly inside the prod account without requiring any Terraform code in that workspace.

```mermaid
graph LR
  subgraph providers["envs/hub/providers.tf"]
    P_DEFAULT["provider aws (default)<br/>assume_role → hub account"]
    P_HUB["provider aws.hub<br/>assume_role → hub account"]
    P_PROD["provider aws.prod<br/>assume_role → prod account"]
  end

  subgraph tgw_module["modules/transit-gateway/main.tf"]
    TGW["aws_ec2_transit_gateway<br/>aws_ram_resource_share<br/>aws_ram_principal_association"]
    ATT_HUB["aws_ec2_transit_gateway<br/>_vpc_attachment.hub"]
    ATT_PROD["aws_ec2_transit_gateway<br/>_vpc_attachment.prod"]
    RT_HUB["aws_route hub→prod"]
    RT_PROD["aws_route prod→hub"]
    SG_PROD["aws_security_group_rule<br/>hub→prod :443"]
  end

  P_HUB  --> TGW
  P_HUB  --> ATT_HUB
  P_HUB  --> RT_HUB
  P_PROD --> ATT_PROD
  P_PROD --> RT_PROD
  P_PROD --> SG_PROD

  P_DEFAULT -->|"VPC, EKS, IAM<br/>ArgoCD, Karpenter<br/>(existing hub resources)"| hub_res["Hub account resources"]
```

---

## 4. Network Topology

The Transit Gateway lives in the hub account and is shared to the prod account via AWS Resource Access Manager (RAM). Each account attaches its private subnets to the TGW. `auto_accept_shared_attachments = enable` removes the need for a manual acceptance step in the prod account. The prod-data account connects to prod via VPC peering only — it is not attached to the Transit Gateway.

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
    RAM_BOX["RAM Resource Share<br/>→ prod account"]
    TGW_BOX --- RAM_BOX
  end

  subgraph prod_acc["Prod Account · 10.2.0.0/16"]
    PROD_PRI["Private Subnets<br/>10.2.10.0/24, 10.2.11.0/24"]
    PROD_EKS["eks-prod (EMR on EKS)"]
    PROD_MSK["MSK Kafka<br/>port 9098 IAM/TLS"]
    PROD_MQ["Amazon MQ (ActiveMQ)<br/>ACTIVE_STANDBY_MULTI_AZ<br/>port 5671 AMQP+SSL"]
    PROD_EKS -->|"Spark writes results"| PROD_MSK
    PROD_MSK -->|"Kafka consumer bridge<br/>(EKS pod)"| PROD_MQ
  end

  subgraph prod_data_acc["Prod-Data Account · 10.4.0.0/16"]
    PDDATA_PRI["Private Subnets<br/>10.4.10.0/24, 10.4.11.0/24"]
    OS["OpenSearch"]
    AURORA["Aurora PostgreSQL"]
    NEPTUNE["Neptune"]
  end

  HUB_PRI  <-->|"VPC attachment (hub account)"| TGW_BOX
  PROD_PRI <-->|"VPC attachment (prod account, via RAM)"| TGW_BOX

  ARGOCD -->|"port 443 via TGW"| PROD_EKS

  PROD_PRI <-->|"VPC peering"| PDDATA_PRI
```

---

## 5. Transit Gateway Routing

Four route entries and one security group rule are created by the hub workspace using aliased providers.

```mermaid
flowchart LR
  subgraph hub_rt["Hub private route tables\n(provider: aws.hub)"]
    HR1["10.2.0.0/16 → TGW"]
  end

  subgraph prod_rt["Prod private route tables\n(provider: aws.prod)"]
    PR1["10.0.0.0/16 → TGW"]
  end

  TGW_C["Transit Gateway"]

  HR1  --> TGW_C
  PR1  --> TGW_C

  subgraph sg_rules["Security group rules"]
    SGP["eks-prod cluster SG<br/>ingress 443 from 10.0.0.0/16<br/>(provider: aws.prod)"]
  end

  TGW_C -->|"ArgoCD → eks-prod :443"| SGP
```

### RAM share propagation

A `time_sleep` of 30 s is inserted between the RAM principal association and the cross-account VPC attachment. RAM is eventually consistent — without this delay the prod account would not yet see the TGW, producing a `TransitGatewayNotFound` error.

```
aws_ram_principal_association.prod
        │
        │  time_sleep 30s
        ▼
aws_ec2_transit_gateway_vpc_attachment.prod (provider: aws.prod)
```

---

## 6. ArgoCD GitOps Flow

Hub ArgoCD is configured in HA mode (2 replicas). It holds a Kubernetes cluster secret for the prod spoke, generated from the `argocd_manager` service account token written to the prod remote state.

```mermaid
sequenceDiagram
  participant GH as GitHub<br/>gitops/
  participant ARGOCD as ArgoCD Hub<br/>(eks-hub)
  participant PROD_API as eks-prod

  GH-->>ARGOCD: poll / webhook (ApplicationSet controllers)

  Note over ARGOCD: infra-apps ApplicationSet
  ARGOCD->>PROD_API: apply cert-manager HelmRelease

  Note over ARGOCD: spoke-apps ApplicationSet
  ARGOCD->>PROD_API: apply gitops/apps/prod/* (podinfo, …)

  Note over ARGOCD: spoke-root Application (app-of-apps)
  ARGOCD->>PROD_API: sync spoke-root/prod
```

### Cluster secret data flow

```mermaid
graph LR
  subgraph prod_ws["prod workspace (S3 state)"]
    TOK_PROD["argocd_manager_token<br/>(sensitive output)"]
    EP_PROD["cluster_endpoint"]
    CA_PROD["cluster_certificate_authority_data"]
  end

  subgraph hub_ws["hub workspace"]
    SEC_PROD["kubernetes_secret<br/>argocd-cluster-eks-prod"]
  end

  TOK_PROD --> SEC_PROD
  EP_PROD  --> SEC_PROD
  CA_PROD  --> SEC_PROD

  SEC_PROD -->|mounted by ArgoCD| ARGOCD["ArgoCD Hub"]
```

---

## 7. Startup Sequence

`startup.sh` orchestrates all workspaces in dependency order.

```mermaid
sequenceDiagram
  participant U  as User
  participant SH as startup.sh
  participant MGMT as Management Account
  participant S3 as S3 State Bucket
  participant HUB as Hub Account
  participant PROD as Prod Account
  participant PRODDATA as Prod-Data Account

  U->>SH: ./scripts/startup.sh

  Note over SH,MGMT: Step 1 — bootstrap
  SH->>MGMT: terraform apply (bootstrap/)
  MGMT-->>S3: create bucket + DynamoDB table
  SH->>SH: sed REPLACE_WITH_STATE_BUCKET → bucket name

  Note over SH,PRODDATA: Step 2 — accounts
  SH->>MGMT: terraform apply (envs/accounts/)
  MGMT-->>HUB: aws_organizations_account (hub)
  MGMT-->>PROD: aws_organizations_account (prod)
  MGMT-->>PRODDATA: aws_organizations_account (prod-data)
  SH->>SH: sed REPLACE_WITH_*_ACCOUNT_ID → account IDs

  Note over SH: Step 3 — wait_iam
  SH->>HUB:      poll sts:AssumeRole (OrganizationAccountAccessRole)
  SH->>PROD:     poll sts:AssumeRole (OrganizationAccountAccessRole)
  SH->>PRODDATA: poll sts:AssumeRole (OrganizationAccountAccessRole)

  Note over SH,PROD: Step 4 — prod
  SH->>PROD: assume role → terraform apply (envs/prod/)
  PROD-->>S3: write prod state

  Note over SH,HUB: Step 5 — hub
  SH->>HUB: assume role → terraform apply (envs/hub/)
  HUB->>S3: read prod remote state
  HUB->>PROD: create TGW attachment + routes + SG rule (aws.prod)
  HUB-->>S3: write hub state

  Note over SH,PRODDATA: Step 6 — prod-data
  SH->>PROD: terraform output cluster_endpoint + cluster_certificate_authority_data
  PROD-->>SH: endpoint + CA data
  SH->>SH: sed cluster endpoint/CA into envs/prod-data/terraform.tfvars
  SH->>PRODDATA: assume role → terraform apply (envs/prod-data/)
  PRODDATA->>S3: read prod remote state (VPC, MQ URL, cluster details)
  PRODDATA->>PRODDATA: create VPC + OpenSearch + Aurora + Neptune
  PRODDATA->>PROD: create VPC peering accepter + prod-side routes (aws.prod)
  PRODDATA->>PROD: create db-writer IAM role + Pod Identity association (aws.prod)
  PRODDATA->>PROD: create K8s namespace/SA/ConfigMap/Secrets/Deployment (kubernetes provider)
  PRODDATA-->>S3: write prod-data state

  Note over SH,U: Step 7 — kubeconfig
  SH->>U: aws eks update-kubeconfig (hub, prod)
  U-->>U: contexts: hub · prod ✓
```

---

## 8. EMR on EKS — Pod Identity & S3 Landing Zone

### Why Pod Identity instead of IRSA

EKS Pod Identity removes the dependency on the cluster's OIDC issuer URL. The IAM role's trust policy names `pods.eks.amazonaws.com` as the trusted service; a single `aws_eks_pod_identity_association` resource then binds the role to a specific namespace + service account pair. The `eks-pod-identity-agent` DaemonSet (deployed as a standard EKS addon on every cluster) intercepts the association and injects temporary credentials into matching pods via a projected token volume — no JWKS endpoint configuration, no OIDC provider ARN, no condition keys.

### Pod Identity credential flow

```mermaid
sequenceDiagram
  participant TF as Terraform<br/>(envs/prod)
  participant IAM as AWS IAM
  participant EKS as EKS Control Plane
  participant AGENT as eks-pod-identity-agent<br/>(DaemonSet)
  participant POD as EMR Job Pod<br/>(SA: emr-job-runner)
  participant S3 as S3 Landing Zone
  participant MSK as MSK Kafka<br/>(port 9098 IAM/TLS)

  TF->>IAM: aws_iam_role (trust: pods.eks.amazonaws.com)
  TF->>EKS: aws_eks_pod_identity_association<br/>(namespace=emr-jobs, sa=emr-job-runner)
  TF->>EKS: kubernetes_service_account emr-job-runner

  Note over POD: Job submitted via aws emr-containers start-job-run
  EKS->>POD: schedule pod with serviceAccountName=emr-job-runner
  AGENT->>IAM: AssumeRole + TagSession (on pod admission)
  IAM-->>AGENT: temporary credentials
  AGENT-->>POD: inject credentials via projected volume
  POD->>S3: s3:GetObject / s3:ListBucket<br/>(read source parquet from landing zone)
  POD->>MSK: kafka-cluster:WriteData<br/>(produce results to topic, SASL_SSL :9098)
  POD->>S3: s3:PutObject<br/>(write Spark event logs to spark-logs/ prefix)
```

### S3 landing zone

The prod account gets a dedicated S3 bucket created by the `emr-on-eks` module alongside the virtual cluster:

| Property | Value |
|---|---|
| Name | `<cluster_name>-landing-zone-<account_id>` |
| Encryption | AES256 (SSE-S3) |
| Versioning | Enabled |
| Public access | Fully blocked (`block_public_acls`, `restrict_public_buckets`) |
| IAM scope | Job execution role has `s3:GetObject/PutObject/DeleteObject` on `arn:aws:s3:::${bucket}/*` and `s3:ListBucket` on `arn:aws:s3:::${bucket}` — no wildcard `*` |

The bucket name embeds the account ID, making it globally unique without a random suffix provider.

### Spark History Server

A `kubernetes_deployment` named `spark-history-server` is deployed in the `emr-jobs` namespace alongside the job pods. It runs the EMR Spark image (`public.ecr.aws/emr-on-eks/spark/emr-7.5.0`) with `SPARK_HISTORY_OPTS` pointing to `s3://<landing_zone>/spark-logs/`. It shares the `emr-job-runner` service account, so Pod Identity grants the same S3 read permissions used by job pods. A `ClusterIP` service exposes it on port 18080 within the cluster.

```
spark-history-server pod (emr-jobs ns)
  ├─ SA: emr-job-runner  →  Pod Identity  →  emr-job-runner IAM role
  ├─ reads:  s3://<landing-zone>/spark-logs/**  (S3 event logs written by Spark jobs)
  └─ serves: ClusterIP :18080  (kubectl port-forward)
```

---

## 9. Amazon MQ — Kafka-to-Message-Broker Bridge

### Architecture

Amazon MQ (ActiveMQ) broker is deployed in the **prod** account, co-located in the same VPC as the MSK cluster. A lightweight Kafka consumer bridge application (a Kubernetes Deployment running in the EKS cluster) reads from MSK topics using IAM/TLS authentication and republishes messages to Amazon MQ queues and topics via AMQP (port 5671).

The hub cluster can consume from Amazon MQ in prod over the private network via Transit Gateway — no internet exposure, no additional IAM policy changes required beyond the TGW routing that already exists.

```mermaid
sequenceDiagram
  participant SPARK  as EMR Spark Job<br/>(emr-job-runner pod)
  participant MSK    as MSK Kafka<br/>(port 9098 IAM/TLS)
  participant BRIDGE as Kafka–MQ Bridge<br/>(EKS Deployment)
  participant MQ     as Amazon MQ<br/>(ActiveMQ, port 5671)
  participant HUB    as Hub consumers<br/>(via Transit Gateway)

  SPARK->>MSK:   produce(topic, record)<br/>IAM auth via Pod Identity
  Note over BRIDGE: Kafka consumer loop
  BRIDGE->>MSK:  poll(topic)<br/>IAM auth via Pod Identity
  MSK-->>BRIDGE: records batch
  BRIDGE->>MQ:   send(queue/topic)<br/>AMQP+SSL username/password
  MQ-->>HUB:     consume(queue/topic)<br/>AMQP port 5671 via TGW
```

### Amazon MQ broker properties

| Property | Value |
|---|---|
| Engine | ActiveMQ `5.18.3` |
| Deployment mode | `ACTIVE_STANDBY_MULTI_AZ` — primary + standby across 2 AZs |
| Instance type | `mq.m5.large` (configurable via `mq_instance_type`) |
| Network placement | Private subnets of the prod VPC |
| Publicly accessible | `false` — reachable only via private IP |
| Client protocol | AMQP+SSL (port 5671) — used by cross-account consumers |
| Java/JMS clients | OpenWire+SSL (port 61617) |
| Web console | Port 8162 (HTTPS) — restricted to local VPC CIDR only |
| Authentication | Username/password (`mq_username` / `mq_password` sensitive variable) |
| Logging | General + audit logs → CloudWatch (`/aws/amazonmq/<cluster>/general`, `.../audit`) |

### Cross-account connectivity

Amazon MQ SG allows AMQP+SSL (5671), OpenWire+SSL (61617), STOMP+SSL (61614), and MQTT+SSL (8883) from `10.0.0.0/8`, covering hub and prod VPC CIDRs via the Transit Gateway. No additional TGW route changes are required — the existing hub↔prod routing handles the traffic.

```
Hub    10.0.0.0/16 ──┐
Prod   10.2.0.0/16 ──┘  Transit Gateway  ──►  Amazon MQ (prod)  10.2.x.x:5671
```

### Client failover URL

For ACTIVE_STANDBY_MULTI_AZ deployments, clients should use the failover URL output by Terraform to automatically reconnect on broker failover:

```
failover:(amqp+ssl://<primary>:5671,amqp+ssl://<standby>:5671)?maxReconnectAttempts=10
```

Retrieve after apply:
```bash
terraform output -chdir=envs/prod mq_amqp_failover_url
```

---

## 10. End-to-End Data Flow

This section traces the complete journey of data through the platform — from a data scientist opening a notebook, through EMR Spark processing, into MSK Kafka, across the Amazon MQ bridge, and finally to consumers and the prod-data analytics store.

### Full pipeline sequence

```mermaid
sequenceDiagram
  participant DS       as Data Scientist<br/>(browser)
  participant JH       as JupyterHub<br/>(eks-prod)
  participant EMRAPI   as EMR Containers API<br/>(aws emr-containers)
  participant EMR      as Spark Driver + Executors<br/>(emr-jobs namespace)
  participant S3       as S3 Landing Zone<br/>(prod account)
  participant MSK      as MSK Kafka<br/>(port 9098 IAM/TLS)
  participant BRIDGE   as Kafka–MQ Bridge<br/>(EKS Deployment, emr-jobs ns)
  participant MQ       as Amazon MQ<br/>(ActiveMQ, port 5671)
  participant HUB      as Hub Account consumer<br/>(via TGW)
  participant SHS      as Spark History Server<br/>(ClusterIP :18080)
  participant DBWRITER as db-writer pod<br/>(eks-prod, db-writer ns)
  participant OS       as OpenSearch<br/>(prod-data, port 443)
  participant AURORA   as Aurora PostgreSQL<br/>(prod-data, port 5432)
  participant NEPTUNE  as Neptune<br/>(prod-data, port 8182)

  DS->>JH: open PySpark notebook<br/>(NLB → jupyterhub namespace)
  Note over JH: Pod Identity injects<br/>emr-job-runner credentials
  JH->>S3: s3:GetObject — read source parquet<br/>(exploratory / data prep)

  DS->>JH: submit EMR job (boto3 start-job-run)
  JH->>EMRAPI: start-job-run (virtual cluster ID,<br/>job execution role ARN, S3 entrypoint)
  EMRAPI->>EMR: schedule Spark driver pod<br/>(SA: emr-job-runner, ns: emr-jobs)
  Note over EMR: Pod Identity → emr-job-runner role<br/>injected by eks-pod-identity-agent

  EMR->>S3: s3:GetObject — read parquet partitions
  EMR->>S3: s3:PutObject — write processed output<br/>(optional, to landing zone)
  EMR->>MSK: kafka-cluster:WriteData<br/>produce(topic="results", SASL_SSL :9098)
  EMR->>S3: s3:PutObject — write Spark event logs<br/>(spark-logs/ prefix)

  Note over BRIDGE: continuous consumer loop<br/>(Pod Identity → emr-job-runner role)
  BRIDGE->>MSK: kafka-cluster:ReadData<br/>poll(topic="results", SASL_SSL :9098)
  MSK-->>BRIDGE: records batch
  BRIDGE->>MQ: send(destination, AMQP+SSL :5671)<br/>username/password auth

  par Consumers via TGW and local
    MQ-->>HUB: deliver(queue/topic)<br/>AMQP+SSL :5671, 10.0.x.x via TGW
  and
    MQ->>MQ: local consumers within prod account
  end

  Note over DBWRITER: db-writer pod (eks-prod, db-writer ns)<br/>Pod Identity → db-writer IAM role
  DBWRITER->>MQ: consume(queue/topic)<br/>AMQP+SSL :5671 (local in prod VPC)
  DBWRITER->>OS: PUT /index/_doc<br/>HTTPS :443 via VPC peering → prod-data
  DBWRITER->>AURORA: INSERT INTO table<br/>PostgreSQL :5432 via VPC peering → prod-data
  DBWRITER->>NEPTUNE: g.addV()<br/>Gremlin WSS :8182 via VPC peering → prod-data

  DS->>SHS: kubectl port-forward :18080
  SHS->>S3: s3:GetObject — read event logs<br/>(spark-logs/ prefix, Pod Identity)
  SHS-->>DS: Spark job DAG, stage timings, executor metrics
```

### Component inventory

| Component | Account | K8s namespace | IAM credential | Outbound protocol |
|---|---|---|---|---|
| JupyterHub single-user pod | prod | `jupyterhub` | Pod Identity → `emr-job-runner` role | S3 (HTTPS), EMR Containers API (HTTPS) |
| Spark driver pod | prod | `emr-jobs` | Pod Identity → `emr-job-runner` role | S3 (HTTPS), MSK SASL_SSL :9098 |
| Spark executor pods | prod | `emr-jobs` | Pod Identity → `emr-job-runner` role | S3 (HTTPS), MSK SASL_SSL :9098 |
| Kafka–MQ Bridge | prod | `emr-jobs` | Pod Identity → `emr-job-runner` role | MSK SASL_SSL :9098 → MQ AMQP+SSL :5671 |
| Spark History Server | prod | `emr-jobs` | Pod Identity → `emr-job-runner` role | S3 (HTTPS read), serves :18080 |
| Amazon MQ broker | prod | — (managed service) | username/password | AMQP+SSL :5671, OpenWire+SSL :61617 |
| Amazon MQ consumers | hub, prod | any | username/password | AMQP+SSL :5671 via Transit Gateway |

### IAM permissions on the shared `emr-job-runner` role

All data-plane components (Spark pods, JupyterHub pods, Kafka bridge, Spark History Server) bind to the same `emr-job-runner` service account. The role's inline policy grants:

| Permission group | Resources |
|---|---|
| `s3:GetObject/PutObject/DeleteObject` | `arn:aws:s3:::<landing-zone>/*` |
| `s3:ListBucket` | `arn:aws:s3:::<landing-zone>` |
| `logs:PutLogEvents/CreateLogGroup/CreateLogStream` | `arn:aws:logs:::log-group:/emr-on-eks/*` |
| `glue:GetDatabase/GetTable` | Spark catalog access |
| `kafka-cluster:Connect/DescribeCluster/WriteData/ReadData/CreateTopic/AlterGroup` | Specific MSK cluster, topic, and group ARNs (no wildcard) |

### Data flow across accounts (ASCII overview)

```
  prod account (10.2.0.0/16)
  ┌─────────────────────────────┐
  │ JupyterHub  ──► S3          │
  │     │                       │
  │     ▼                       │
  │ EMR Spark   ──► MSK :9098   │
  │                  │          │
  │             Bridge pod       │
  │                  │          │
  │                  ▼          │
  │           Amazon MQ :5671   │
  │                  │          │
  │             db-writer pod   │
  └──────────────┬──────────────┘
                 │
                 │  Transit Gateway     VPC Peering
                 ▼                         ▼
  hub 10.0.0.0/16 ◄── AMQP :5671     prod-data 10.4.0.0/16
                                      ┌────────────────────┐
                                      │ OpenSearch :443     │
                                      │ Aurora     :5432    │
                                      │ Neptune    :8182    │
                                      └────────────────────┘
```

---

## 11. Prod-Data — Isolated Analytics Store

The `prod-data` account hosts three managed databases that persist and index the events delivered by Amazon MQ. A lightweight `db-writer` microservice runs on the existing `eks-prod` cluster, consumes from the MQ broker, and writes to all three databases over the VPC peering connection.

### VPC peering topology

```
prod account (10.2.0.0/16)                    prod-data account (10.4.0.0/16)
┌─────────────────────────────┐                ┌──────────────────────────────┐
│  eks-prod                   │                │  Amazon OpenSearch           │
│    └─ db-writer Deployment  │◄──── peering ──│  Aurora PostgreSQL           │
│         reads: Amazon MQ    │                │  Amazon Neptune              │
│         writes: OS/Au/Npt   │                └──────────────────────────────┘
│  Amazon MQ (ActiveMQ)       │
└─────────────────────────────┘

Connectivity: VPC peering only (no Transit Gateway attachment for prod-data).
Isolation: prod-data is not reachable from hub account.
```

### Database stack

| Database | Port | Auth method | Purpose |
|---|---|---|---|
| Amazon OpenSearch | 443 (HTTPS) | IAM (`es:ESHttp*`) via db-writer role | Full-text search and analytics indexing |
| Aurora PostgreSQL | 5432 | Password (Kubernetes Secret in db-writer ns) | Relational store for structured event records |
| Amazon Neptune | 8182 (Gremlin WSS) | IAM (`neptune-db:*`) via db-writer role | Graph database for entity relationship data |

### Provider wiring (prod-data workspace)

```mermaid
graph LR
  subgraph providers["envs/prod-data/providers.tf"]
    P_DEFAULT["provider aws (default)<br/>assume_role → prod-data account<br/>creates: VPC, OpenSearch, Aurora, Neptune<br/>+ peering requester"]
    P_PROD["provider aws.prod<br/>assume_role → prod account<br/>creates: peering accepter, prod-side routes<br/>db-writer IAM role, Pod Identity association"]
    P_K8S["provider kubernetes<br/>→ eks-prod cluster<br/>endpoint + CA from prod remote state<br/>creates: namespace, SA, ConfigMap, Secrets, Deployment"]
  end

  subgraph state["Remote state"]
    RS_PROD["data.terraform_remote_state.prod<br/>reads: cluster_endpoint, cluster_certificate_authority_data,<br/>cluster_name, vpc_id, vpc_cidr,<br/>private_route_table_ids, mq_amqp_failover_url"]
  end

  RS_PROD --> P_K8S
  RS_PROD --> P_PROD
  RS_PROD --> P_DEFAULT
```

### db-writer microservice data flow

```mermaid
sequenceDiagram
  participant MQ       as Amazon MQ<br/>(prod account, port 5671)
  participant DBWRITER as db-writer pod<br/>(eks-prod, db-writer ns)<br/>Pod Identity → db-writer IAM role
  participant OS       as OpenSearch<br/>(prod-data, HTTPS :443)
  participant AURORA   as Aurora PostgreSQL<br/>(prod-data, TCP :5432)
  participant NEPTUNE  as Neptune<br/>(prod-data, Gremlin WSS :8182)

  Note over DBWRITER: continuous consumer loop
  DBWRITER->>MQ: consume(queue/topic)<br/>AMQP+SSL :5671 (local, no TGW needed)
  MQ-->>DBWRITER: message batch

  par Write to all three databases
    DBWRITER->>OS: PUT /index/_doc<br/>IAM SigV4 auth via Pod Identity
  and
    DBWRITER->>AURORA: INSERT INTO events<br/>password from Kubernetes Secret
  and
    DBWRITER->>NEPTUNE: g.addV().property(...)<br/>IAM auth via Pod Identity
  end
```

### Key isolation properties

- prod-data VPC (`10.4.0.0/16`) is peered **only** with prod (`10.2.0.0/16`) — no routes to hub
- No Transit Gateway attachment for prod-data — peering is point-to-point, preventing accidental cross-account access
- The `envs/prod-data` workspace manages **all** integration resources (peering, IAM role, Pod Identity, Kubernetes objects) so `terraform destroy` cleanly removes everything without touching the prod workspace

---

## Checkpoint files

Each orchestration script writes a checkpoint file to the repo root so that a failed run can be resumed without repeating completed steps.

| Script | Checkpoint file | Steps |
|---|---|---|
| `startup.sh` | `.startup-progress` | prereqs → bootstrap → accounts → wait_iam → prod → hub → prod_data → kubeconfig |
| `apply-all.sh` | `.apply-all-progress` | accounts → prod → hub → prod_data |
| `teardown.sh` | `.teardown-progress` | hub → prod_data → prod → accounts |
| `shutdown.sh` | `.shutdown-progress` | hub → prod_data → prod → accounts → bootstrap |

All four checkpoint files are listed in `.gitignore`.
