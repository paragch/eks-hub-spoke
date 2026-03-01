output "hub_account_id" {
  description = "AWS account ID for the hub member account"
  value       = aws_organizations_account.hub.id
}

output "prod_account_id" {
  description = "AWS account ID for the prod member account"
  value       = aws_organizations_account.prod.id
}

output "prod_data_account_id" {
  description = "AWS account ID for the prod-data member account"
  value       = aws_organizations_account.prod_data.id
}

output "management_account_id" {
  description = "AWS account ID of the management (root) account"
  value       = data.aws_organizations_organization.current.master_account_id
}
