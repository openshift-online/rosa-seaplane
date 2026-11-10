terraform {
  required_version = ">= 1.14.3"
  backend "s3" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type        = string
  description = "The regional authorization storage location."
}

variable "table_names" {
  type = object({
    policies = string
    global   = string
    regional = string
  })
  description = "Explicit isolated table names, independent of any RC or MC ID."
}

# Retained tables outlive RC replacement; AWS deletion protection blocks destroy.
module "authz_tables" {
  source           = "../../modules/authz-tables"
  table_names      = var.table_names
  enable_retention = true
}
