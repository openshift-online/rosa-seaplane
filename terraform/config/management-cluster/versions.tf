terraform {
  required_version = ">= 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70.0"
    }
    external = {
      source  = "hashicorp/external"
      version = ">= 2.3"
    }
  }
}

