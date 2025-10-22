terraform {
  # FIX 1: Adds required version constraint for Terraform CLI
  required_version = ">= 1.0.0" 

  backend "s3" {
    bucket = "sctp-ce11-tfstate"
    key    = "ninadc.tfstate" #Change this
    region = "us-east-1"
  }
  
  # FIX 2: Adds required version constraint for the 'aws' provider
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0" # Use a stable, current version
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  # FIX 3: Change to standard HCL expression for split() function argument (addresses TFLint warning: terraform_deprecated_interpolation)
  # The expression does not need to be wrapped in quotes or ${} because it's a function argument.
  name_prefix = split("/", data.aws_caller_identity.current.arn)[1] 
  
  # if your name contains any invalid characters like “.”, hardcode this name_prefix value = <YOUR NAME>
  account_id  = data.aws_caller_identity.current.account_id
}

resource "aws_s3_bucket" "s3_tf" {
  # NOTE: This is string interpolation, which is NOT deprecated. You only remove ${} 
  # when the entire value is a single expression (e.g., bucket = var.name).
  bucket = "${local.name_prefix}-s3-tf-bkt-${local.account_id}" 
}