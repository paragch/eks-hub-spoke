# IAM Module — two-phase: base roles (Phase 1), OIDC provider (Phase 2)

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# ── Phase 1: Cluster + Node roles ─────────────────────────────────────────────

resource "aws_iam_role" "cluster_role" {
  count = var.create_base_roles ? 1 : 0
  name  = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-cluster-role"
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  count      = var.create_base_roles ? 1 : 0
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster_role[0].name
}

resource "aws_iam_role_policy_attachment" "cluster_vpc_resource_controller" {
  count      = var.create_base_roles ? 1 : 0
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster_role[0].name
}

resource "aws_iam_role" "node_role" {
  count = var.create_base_roles ? 1 : 0
  name  = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-node-role"
  })
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  count      = var.create_base_roles ? 1 : 0
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_role[0].name
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  count      = var.create_base_roles ? 1 : 0
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_role[0].name
}

resource "aws_iam_role_policy_attachment" "node_registry_policy" {
  count      = var.create_base_roles ? 1 : 0
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_role[0].name
}

resource "aws_iam_role_policy_attachment" "node_ssm_policy" {
  count      = var.create_base_roles ? 1 : 0
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.node_role[0].name
}

# ── Phase 2: OIDC provider ───────────────────────────────────────────────────

data "tls_certificate" "cluster_oidc" {
  count = var.create_oidc_provider ? 1 : 0
  url   = var.cluster_oidc_issuer_url
}

resource "aws_iam_openid_connect_provider" "cluster_oidc" {
  count = var.create_oidc_provider ? 1 : 0

  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster_oidc[0].certificates[0].sha1_fingerprint]
  url             = var.cluster_oidc_issuer_url

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-oidc-provider"
  })
}
