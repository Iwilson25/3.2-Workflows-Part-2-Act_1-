provider "aws" {
  region = "us-east-1"
}

terraform {
  required_version = ">= 1.0.0"

  backend "s3" {
    bucket = "sctp-ce11-tfstate"
    key    = "ninadc.tfstate"
    region = "us-east-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = split("/", data.aws_caller_identity.current.arn)[1]
  account_id  = data.aws_caller_identity.current.account_id
}

# ----------------------------------------------------
# S3 BUCKET ACCESS LOGS AND PUBLIC ACCESS BLOCK RESOURCES
# ----------------------------------------------------

# RESOURCE 1: Dedicated bucket to store access logs 
resource "aws_s3_bucket" "log_bucket" {
  bucket = "${local.name_prefix}-s3-access-logs-${local.account_id}"
  acl    = "log-delivery-write"
}

# FIX 1: New resource for Public Access Block for log_bucket
resource "aws_s3_bucket_public_access_block" "log_bucket_pab" {
  bucket                  = aws_s3_bucket.log_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# FIX 2: Renamed resource for Access logging configuration
resource "aws_s3_bucket_logging" "s3_tf_logging" {
  bucket        = aws_s3_bucket.s3_tf.id
  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "log/"
}

# ----------------------------------------------------
# MAIN S3 BUCKET RESOURCE
# ----------------------------------------------------

resource "aws_s3_bucket" "s3_tf" {
  bucket = "${local.name_prefix}-s3-tf-bkt-${local.account_id}"
  acl    = "private"

  # FIX: CKV_AWS_145 - Ensure encryption is set (using SSE-S3)
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }

  # FIX: CKV_AWS_21 - Ensure versioning is enabled
  versioning {
    enabled = true
  }

  # FIX: CKV2_AWS_61 - Ensure lifecycle configuration
  lifecycle_rule {
    id      = "main-cleanup"
    enabled = true

    expiration {
      days = 365
    }

    # FIX 4: Corrected argument name from 'noncurrent_days' to 'days'
    noncurrent_version_expiration {
      days = 90
    }
  }

  tags = {
    Name = "${local.name_prefix}-s3-tf-bkt"
  }
}

# FIX 3: New resource for Public Access Block for s3_tf
resource "aws_s3_bucket_public_access_block" "s3_tf_pab" {
  bucket                  = aws_s3_bucket.s3_tf.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}