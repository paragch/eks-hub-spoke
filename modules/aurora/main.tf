terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── DB subnet group ────────────────────────────────────────────────────────────

resource "aws_db_subnet_group" "aurora" {
  name        = "${var.cluster_name}-aurora"
  subnet_ids  = var.private_subnet_ids
  description = "Aurora subnet group for ${var.cluster_name}"

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-aurora-subnet-group"
  })
}

# ── Security group ─────────────────────────────────────────────────────────────

resource "aws_security_group" "aurora" {
  name_prefix = "${var.cluster_name}-aurora-"
  vpc_id      = var.vpc_id
  description = "Aurora PostgreSQL security group for ${var.cluster_name}"

  ingress {
    description = "PostgreSQL — Aurora writer + reader endpoints"
    from_port   = 5432
    to_port     = 5432
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
    Name = "${var.cluster_name}-aurora-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ── Aurora PostgreSQL cluster ──────────────────────────────────────────────────

resource "aws_rds_cluster" "aurora" {
  cluster_identifier     = "${var.cluster_name}-aurora"
  engine                 = "aurora-postgresql"
  engine_version         = var.engine_version
  database_name          = var.db_name
  master_username        = var.db_username
  master_password        = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.aurora.name
  vpc_security_group_ids = [aws_security_group.aurora.id]
  storage_encrypted      = true
  skip_final_snapshot    = true

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-aurora"
  })
}

# ── Aurora cluster instances ───────────────────────────────────────────────────
# Instance 0 is the writer; instances 1+ are readers.

resource "aws_rds_cluster_instance" "aurora" {
  count = var.instance_count

  identifier         = "${var.cluster_name}-aurora-${count.index}"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = var.instance_class
  engine             = aws_rds_cluster.aurora.engine
  engine_version     = aws_rds_cluster.aurora.engine_version

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-aurora-${count.index}"
    Role = count.index == 0 ? "writer" : "reader"
  })
}
