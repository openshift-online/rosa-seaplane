terraform {
  required_version = ">= 1.14.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.70.0"
    }
    pagerduty = {
      source  = "PagerDuty/pagerduty"
      version = ">= 3.0"
    }
  }
}
