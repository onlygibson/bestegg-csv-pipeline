# Run this ONCE, by hand, from your laptop.
#
# It creates the things the main pipeline depends on before Terraform can run:
#   1. An S3 bucket for Terraform state (the cheap replacement for Terraform Cloud)
#   2. GitHub OIDC, so GitHub Actions gets short-lived AWS credentials (no stored keys)
#   3. Two roles:
#        - plan role:  read-only, usable only by pull requests
#        - apply role: can change things, usable only by the protected "production" environment
#
# State for this folder stays local on purpose. Terraform can't keep its state
# in a bucket it hasn't created yet.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "github_repo" {
  description = "Your GitHub repo as owner/name, for example gibsonibeh/bestegg-csv-pipeline"
  type        = string
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# 1. Terraform state bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = "tfstate-${local.account_id}-${var.region}"
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled" # lets you recover an older state file if one gets damaged
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# 2. GitHub OIDC: GitHub Actions proves who it is, AWS hands back
#    credentials that expire in about an hour.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # AWS no longer checks this value for GitHub, but older provider versions require it.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "trust_pull_requests" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:pull_request"]
    }
  }
}

data "aws_iam_policy_document" "trust_production" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only jobs running in the protected "production" environment can use this
    # role, and that environment needs a human to approve every run.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:production"]
    }
  }
}

# ---------------------------------------------------------------------------
# 3a. Plan role: read-only, for pull requests
# ---------------------------------------------------------------------------

resource "aws_iam_role" "plan" {
  name                 = "github-terraform-plan"
  assume_role_policy   = data.aws_iam_policy_document.trust_pull_requests.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Plan takes a lock while it runs, so it needs to write the lock file.
data "aws_iam_policy_document" "plan_state_lock" {
  statement {
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*.tflock"]
  }
}

resource "aws_iam_role_policy" "plan_state_lock" {
  name   = "state-lock"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_state_lock.json
}

# ---------------------------------------------------------------------------
# 3b. Apply role: makes changes, only after approval
# ---------------------------------------------------------------------------

resource "aws_iam_role" "apply" {
  name                 = "github-terraform-apply"
  assume_role_policy   = data.aws_iam_policy_document.trust_production.json
  max_session_duration = 3600
}

# Shortcut for a personal project. In a real company you would replace this
# with a policy that only covers the services the pipeline uses.
resource "aws_iam_role_policy_attachment" "apply_admin" {
  role       = aws_iam_role.apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---------------------------------------------------------------------------

output "state_bucket" {
  value = aws_s3_bucket.state.bucket
}

output "plan_role_arn" {
  value = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  value = aws_iam_role.apply.arn
}
