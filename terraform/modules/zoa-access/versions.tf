terraform {
  required_version = ">= 1.14.3"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.70.0"
      configuration_aliases = [aws.central_deployments, aws.central_deployments_replica]
    }
  }
}
