output "hub_account_id" {
  description = "AWS account ID for the hub member account"
  value       = aws_organizations_account.hub.id
}

output "dev_account_id" {
  description = "AWS account ID for the dev member account"
  value       = aws_organizations_account.dev.id
}

output "prod_account_id" {
  description = "AWS account ID for the prod member account"
  value       = aws_organizations_account.prod.id
}

output "management_account_id" {
  description = "AWS account ID of the management (root) account"
  value       = data.aws_organizations_organization.current.master_account_id
}
