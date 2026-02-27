output "peering_connection_id" {
  description = "VPC peering connection ID"
  value       = aws_vpc_peering_connection.this.id
}
