terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ── 1. CloudWatch log group for broker logs ───────────────────────────────────

resource "aws_cloudwatch_log_group" "msk_broker" {
  name              = "/aws/msk/${var.cluster_name}/broker"
  retention_in_days = 7

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-msk-broker-logs"
  })
}

# ── 2. Security group ─────────────────────────────────────────────────────────
# Port 9098 = MSK IAM/TLS (SASL_SSL). Allows EKS pods (within VPC CIDR) to
# connect to Kafka brokers using AWS IAM authentication.

resource "aws_security_group" "msk" {
  name_prefix = "${var.cluster_name}-msk-"
  vpc_id      = var.vpc_id
  description = "MSK broker security group for ${var.cluster_name}"

  ingress {
    description = "Kafka IAM/TLS from VPC"
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description = "MSK inter-broker communication"
    from_port   = 9096
    to_port     = 9096
    protocol    = "tcp"
    self        = true
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-msk-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ── 3. MSK cluster ────────────────────────────────────────────────────────────
# IAM authentication (SASL/IAM over TLS, port 9098) is the modern AWS-native
# auth method for MSK — no username/password or certificates needed.
# number_of_broker_nodes must equal len(client_subnets) (one broker per AZ).

resource "aws_msk_cluster" "main" {
  cluster_name           = "${var.cluster_name}-msk"
  kafka_version          = var.kafka_version
  number_of_broker_nodes = var.number_of_broker_nodes

  broker_node_group_info {
    instance_type  = var.broker_instance_type
    client_subnets = slice(var.private_subnet_ids, 0, var.number_of_broker_nodes)
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.broker_volume_size
      }
    }
  }

  encryption_info {
    encryption_in_transit {
      # TLS only — disables plaintext, required for IAM auth
      client_broker = "TLS"
      in_cluster    = true
    }
  }

  client_authentication {
    sasl {
      iam = true
    }
  }

  enhanced_monitoring = "PER_TOPIC_PER_PARTITION"

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk_broker.name
      }
    }
  }

  tags = merge(var.common_tags, {
    Name = "${var.cluster_name}-msk"
  })

  depends_on = [aws_cloudwatch_log_group.msk_broker]
}
