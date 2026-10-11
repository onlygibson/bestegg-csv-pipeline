terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }

  # The bucket name is passed in at init time:
  #   terraform init -backend-config="bucket=<state bucket from bootstrap>"
  # use_lockfile locks state with a small file in S3 (Terraform 1.10+),
  # so there's no DynamoDB lock table to pay for.
  backend "s3" {
    key          = "csv-pipeline/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "csv-pipeline"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
