terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── 1. CloudWatch log groups ───────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "mq_general" {
  name              = "/aws/amazonmq/${var.cluster_name}/general"
  retention_in_days = 7

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-mq-general-logs"
  })
}

resource "aws_cloudwatch_log_group" "mq_audit" {
  name              = "/aws/amazonmq/${var.cluster_name}/audit"
  retention_in_days = 30 # Audit logs kept longer for compliance

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-mq-audit-logs"
  })
}

# ── 2. Security group ─────────────────────────────────────────────────────────
# Message ports (5671, 61617, 61614) are open to all four VPC CIDRs via the
# Transit Gateway (summarised as 10.0.0.0/8). The web console port (8162) is
# restricted to the local VPC only — no cross-account console access needed.

resource "aws_security_group" "mq" {
  name_prefix = "${var.cluster_name}-mq-"
  vpc_id      = var.vpc_id
  description = "Amazon MQ broker security group for ${var.cluster_name}"

  ingress {
    description = "AMQP+SSL — primary protocol for all cross-account clients (hub, dev, prod, data)"
    from_port   = 5671
    to_port     = 5671
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "OpenWire+SSL — native Java/JMS client protocol"
    from_port   = 61617
    to_port     = 61617
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "STOMP+SSL — lightweight text-based protocol"
    from_port   = 61614
    to_port     = 61614
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "MQTT+SSL — IoT / lightweight publish-subscribe"
    from_port   = 8883
    to_port     = 8883
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  ingress {
    description = "ActiveMQ web console — restricted to local VPC only"
    from_port   = 8162
    to_port     = 8162
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-mq-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ── 3. Amazon MQ broker (ActiveMQ) ────────────────────────────────────────────
# ACTIVE_STANDBY_MULTI_AZ deploys a primary and a standby broker in separate
# AZs. Clients use a failover URL that automatically reconnects to the standby
# if the primary becomes unavailable.
#
# Data flow: MSK Kafka topics → Kafka consumer bridge (EKS pod) → Amazon MQ
# The bridge reads from MSK using IAM auth and writes to Amazon MQ queues/topics
# via AMQP (port 5671). All four VPCs can then consume from Amazon MQ over the
# Transit Gateway without any additional cross-account IAM configuration.

resource "aws_mq_broker" "main" {
  broker_name                = "${var.cluster_name}-mq"
  engine_type                = var.engine_type
  engine_version             = var.engine_version
  host_instance_type         = var.instance_type
  deployment_mode            = var.deployment_mode
  publicly_accessible        = false
  auto_minor_version_upgrade = true

  # ACTIVE_STANDBY_MULTI_AZ requires exactly 2 subnets (one per AZ);
  # SINGLE_INSTANCE requires exactly 1.
  subnet_ids = var.deployment_mode == "ACTIVE_STANDBY_MULTI_AZ" ? slice(var.private_subnet_ids, 0, 2) : [var.private_subnet_ids[0]]

  security_groups = [aws_security_group.mq.id]

  user {
    username       = var.mq_username
    password       = var.mq_password
    console_access = true
  }

  logs {
    general = true
    audit   = true
  }

  maintenance_window_start_time {
    day_of_week = "SUNDAY"
    time_of_day = "03:00"
    time_zone   = "UTC"
  }

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-mq"
  })

  depends_on = [
    aws_cloudwatch_log_group.mq_general,
    aws_cloudwatch_log_group.mq_audit,
  ]
}
