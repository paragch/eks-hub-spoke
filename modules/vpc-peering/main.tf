# VPC Peering Module
# Assumes same AWS account and region (auto_accept = true)

resource "aws_vpc_peering_connection" "this" {
  vpc_id      = var.requester_vpc_id
  peer_vpc_id = var.accepter_vpc_id
  auto_accept = true

  tags = merge(var.common_tags, {
    Name = var.peering_name
    Side = "requester"
  })
}

# Routes on requester side (hub → spoke)
resource "aws_route" "requester_to_accepter" {
  count = length(var.requester_route_table_ids)

  route_table_id            = var.requester_route_table_ids[count.index]
  destination_cidr_block    = var.accepter_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

# Routes on accepter side (spoke → hub)
resource "aws_route" "accepter_to_requester" {
  count = length(var.accepter_route_table_ids)

  route_table_id            = var.accepter_route_table_ids[count.index]
  destination_cidr_block    = var.requester_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
}

# Allow hub ArgoCD to reach spoke API server (port 443)
resource "aws_security_group_rule" "allow_hub_to_spoke_api" {
  description       = "Allow hub VPC to reach spoke cluster API (ArgoCD)"
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = [var.requester_vpc_cidr]
  security_group_id = var.accepter_cluster_sg_id
}
