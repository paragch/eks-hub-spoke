output "transit_gateway_id" {
  description = "Transit Gateway ID"
  value       = aws_ec2_transit_gateway.main.id
}

output "transit_gateway_arn" {
  description = "Transit Gateway ARN"
  value       = aws_ec2_transit_gateway.main.arn
}

output "hub_attachment_id" {
  description = "TGW VPC attachment ID for the hub VPC"
  value       = aws_ec2_transit_gateway_vpc_attachment.hub.id
}

output "prod_attachment_id" {
  description = "TGW VPC attachment ID for the prod VPC"
  value       = aws_ec2_transit_gateway_vpc_attachment.prod.id
}
