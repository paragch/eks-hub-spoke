terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── CloudWatch log group ───────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "index_slow" {
  name              = "/aws/opensearch/${var.cluster_name}/index-slow"
  retention_in_days = 7

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-opensearch-index-slow-logs"
  })
}

# ── Security group ─────────────────────────────────────────────────────────────
# HTTPS (443) is the only entry point for OpenSearch — both the REST API and
# the Dashboards UI use the same port when accessed via the VPC endpoint.

resource "aws_security_group" "opensearch" {
  name_prefix = "${var.cluster_name}-opensearch-"
  vpc_id      = var.vpc_id
  description = "OpenSearch domain security group for ${var.cluster_name}"

  ingress {
    description = "HTTPS — OpenSearch REST API + Dashboards (VPC endpoint)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-opensearch-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ── OpenSearch domain ──────────────────────────────────────────────────────────
# VPC-only endpoint (no public access). Encryption at rest + in-transit.
# AZ awareness enabled when instance_count >= 2 (uses first 2 subnets).
# Fine-grained access control with the db-writer IAM role as master role.

resource "aws_opensearch_domain" "main" {
  domain_name    = var.cluster_name
  engine_version = "OpenSearch_${var.opensearch_version}"

  cluster_config {
    instance_type          = var.instance_type
    instance_count         = var.instance_count
    zone_awareness_enabled = var.instance_count >= 2

    dynamic "zone_awareness_config" {
      for_each = var.instance_count >= 2 ? [1] : []
      content {
        availability_zone_count = 2
      }
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.volume_size
  }

  vpc_options {
    subnet_ids         = var.instance_count >= 2 ? slice(var.private_subnet_ids, 0, 2) : [var.private_subnet_ids[0]]
    security_group_ids = [aws_security_group.opensearch.id]
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = true
    anonymous_auth_enabled         = false
    internal_user_database_enabled = false

    master_user_options {
      master_user_arn = var.db_writer_role_arn
    }
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.index_slow.arn
    log_type                 = "INDEX_SLOW_LOGS"
  }

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-opensearch"
  })

  depends_on = [aws_cloudwatch_log_group.index_slow]
}

# ── Domain access policy ───────────────────────────────────────────────────────
# Grants the db-writer IAM role full HTTP access (ESHttp*) to the domain.
# Fine-grained access control (above) handles per-index/per-alias permissions.

resource "aws_opensearch_domain_policy" "main" {
  domain_name = aws_opensearch_domain.main.domain_name

  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = var.db_writer_role_arn }
        Action    = "es:ESHttp*"
        Resource  = "${aws_opensearch_domain.main.arn}/*"
      }
    ]
  })
}
