data "aws_organizations_organization" "current" {}

# ── Hub account ───────────────────────────────────────────────────────────────

resource "aws_organizations_account" "hub" {
  name  = "eks-hub-spoke-hub"
  email = var.hub_account_email

  # AWS automatically creates this role in every new member account.
  # The management account root can assume it to bootstrap the member account.
  role_name = "OrganizationAccountAccessRole"

  # Safety: never auto-close accounts on terraform destroy
  close_on_deletion = false

  tags = merge(var.common_tags, {
    Name        = "eks-hub-spoke-hub"
    Environment = "hub"
  })
}

# ── Dev account ───────────────────────────────────────────────────────────────

resource "aws_organizations_account" "dev" {
  name  = "eks-hub-spoke-dev"
  email = var.dev_account_email

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  tags = merge(var.common_tags, {
    Name        = "eks-hub-spoke-dev"
    Environment = "dev"
  })
}

# ── Prod account ──────────────────────────────────────────────────────────────

resource "aws_organizations_account" "prod" {
  name  = "eks-hub-spoke-prod"
  email = var.prod_account_email

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  tags = merge(var.common_tags, {
    Name        = "eks-hub-spoke-prod"
    Environment = "prod"
  })
}

# ── Data account ──────────────────────────────────────────────────────────────

resource "aws_organizations_account" "data" {
  name  = "eks-hub-spoke-data"
  email = var.data_account_email

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  tags = merge(var.common_tags, {
    Name        = "eks-hub-spoke-data"
    Environment = "data"
  })
}

# ── Prod-Data account ──────────────────────────────────────────────────────────

resource "aws_organizations_account" "prod_data" {
  name  = "eks-hub-spoke-prod-data"
  email = var.prod_data_account_email

  role_name = "OrganizationAccountAccessRole"

  close_on_deletion = false

  tags = merge(var.common_tags, {
    Name        = "eks-hub-spoke-prod-data"
    Environment = "prod-data"
  })
}
