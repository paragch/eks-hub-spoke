terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.0"
      configuration_aliases = [aws.hub, aws.prod]
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

# ── Transit Gateway (hub account) ─────────────────────────────────────────────

resource "aws_ec2_transit_gateway" "main" {
  provider = aws.hub

  description                     = "Hub-spoke transit gateway"
  auto_accept_shared_attachments  = "enable"
  default_route_table_association = "enable"
  default_route_table_propagation = "enable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"

  tags = merge(var.common_tags, {
    Name = "hub-spoke-tgw"
  })
}

# ── RAM resource share (hub account) ──────────────────────────────────────────
# Shares the TGW with the prod account via AWS Resource Access Manager.

resource "aws_ram_resource_share" "tgw" {
  provider = aws.hub

  name                      = "hub-spoke-tgw-share"
  allow_external_principals = false

  tags = merge(var.common_tags, {
    Name = "hub-spoke-tgw-share"
  })
}

resource "aws_ram_resource_association" "tgw" {
  provider = aws.hub

  resource_share_arn = aws_ram_resource_share.tgw.arn
  resource_arn       = aws_ec2_transit_gateway.main.arn
}

resource "aws_ram_principal_association" "prod" {
  provider = aws.hub

  resource_share_arn = aws_ram_resource_share.tgw.arn
  principal          = var.prod_account_id
}

# RAM share propagation is eventually consistent.
# Wait 30 s before creating cross-account attachments to avoid
# TransitGatewayNotFound errors in the spoke accounts.
resource "time_sleep" "wait_for_ram_share" {
  create_duration = "30s"

  depends_on = [
    aws_ram_resource_association.tgw,
    aws_ram_principal_association.prod,
  ]
}

# ── VPC attachments ───────────────────────────────────────────────────────────

resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  provider = aws.hub

  transit_gateway_id                              = aws_ec2_transit_gateway.main.id
  vpc_id                                          = var.hub_vpc_id
  subnet_ids                                      = var.hub_private_subnet_ids
  transit_gateway_default_route_table_association = true
  transit_gateway_default_route_table_propagation = true

  tags = merge(var.common_tags, {
    Name = "hub-tgw-attachment"
  })
}

resource "aws_ec2_transit_gateway_vpc_attachment" "prod" {
  provider = aws.prod

  transit_gateway_id                              = aws_ec2_transit_gateway.main.id
  vpc_id                                          = var.prod_vpc_id
  subnet_ids                                      = var.prod_private_subnet_ids
  transit_gateway_default_route_table_association = true
  transit_gateway_default_route_table_propagation = true

  tags = merge(var.common_tags, {
    Name = "prod-tgw-attachment"
  })

  depends_on = [time_sleep.wait_for_ram_share]
}

# ── Routes ────────────────────────────────────────────────────────────────────

# Hub → Prod
resource "aws_route" "hub_to_prod" {
  provider = aws.hub
  count    = length(var.hub_private_route_table_ids)

  route_table_id         = var.hub_private_route_table_ids[count.index]
  destination_cidr_block = var.prod_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

# Prod → Hub
resource "aws_route" "prod_to_hub" {
  provider = aws.prod
  count    = length(var.prod_private_route_table_ids)

  route_table_id         = var.prod_private_route_table_ids[count.index]
  destination_cidr_block = var.hub_vpc_cidr
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.prod]
}

# ── Security group rules ──────────────────────────────────────────────────────
# Allow ArgoCD on the hub to reach the prod cluster API server (port 443).

resource "aws_security_group_rule" "allow_hub_to_prod_api" {
  provider = aws.prod

  description       = "Allow hub VPC to reach prod cluster API server (ArgoCD)"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.hub_vpc_cidr]
  security_group_id = var.prod_cluster_sg_id
}
