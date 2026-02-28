terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── Neptune subnet group ───────────────────────────────────────────────────────

resource "aws_neptune_subnet_group" "neptune" {
  name        = "${var.cluster_name}-neptune"
  subnet_ids  = var.private_subnet_ids
  description = "Neptune subnet group for ${var.cluster_name}"

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-neptune-subnet-group"
  })
}

# ── Security group ─────────────────────────────────────────────────────────────
# Port 8182 is used by all Neptune protocols: Gremlin, openCypher (Bolt), SPARQL.

resource "aws_security_group" "neptune" {
  name_prefix = "${var.cluster_name}-neptune-"
  vpc_id      = var.vpc_id
  description = "Neptune cluster security group for ${var.cluster_name}"

  ingress {
    description = "Neptune HTTPS — Gremlin / openCypher (Bolt) / SPARQL"
    from_port   = 8182
    to_port     = 8182
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
    Name = "${var.cluster_name}-neptune-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ── Neptune cluster ────────────────────────────────────────────────────────────
# IAM database authentication enabled — the db-writer IAM role uses
# neptune-db:* actions (no passwords required for graph DB access).

resource "aws_neptune_cluster" "neptune" {
  cluster_identifier                   = "${var.cluster_name}-neptune"
  engine_version                       = var.engine_version
  neptune_subnet_group_name            = aws_neptune_subnet_group.neptune.name
  vpc_security_group_ids               = [aws_security_group.neptune.id]
  enable_cloudwatch_logs_exports       = ["audit"]
  storage_encrypted                    = true
  skip_final_snapshot                  = true
  iam_database_authentication_enabled  = true
  apply_immediately                    = true

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-neptune"
  })
}

# ── Neptune cluster instances ──────────────────────────────────────────────────

resource "aws_neptune_cluster_instance" "neptune" {
  count = var.instance_count

  identifier         = "${var.cluster_name}-neptune-${count.index}"
  cluster_identifier = aws_neptune_cluster.neptune.id
  instance_class     = var.instance_class
  engine             = "neptune"

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-neptune-${count.index}"
  })
}
