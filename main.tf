provider "aws" {
  region = "us-east-1"
}

terraform {
  # TFLint Fix: Required versions for CLI and Provider
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
  # TFLint Fix: Modern HCL expression
  name_prefix = split("/", data.aws_caller_identity.current.arn)[1]
  account_id  = data.aws_caller_identity.current.account_id
}

# ----------------------------------------------------
# KMS KEY FOR S3 ENCRYPTION (FIX: CKV_AWS_145)
# ----------------------------------------------------

resource "aws_kms_key" "s3_key" {
  description             = "KMS key for S3 bucket encryption"
  deletion_window_in_days = 10

  # Minimal policy to allow root user and S3 service to use the key
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "Enable IAM User Permissions",
        Effect = "Allow",
        Principal = {
          AWS = "arn:aws:iam::${local.account_id}:root"
        },
        Action   = "kms:*",
        Resource = "*"
      },
      {
        Sid    = "Allow S3 to use the key for encryption",
        Effect = "Allow",
        Principal = {
          Service = "s3.amazonaws.com"
        },
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"],
        Resource = "*"
      }
    ]
  })
}

# ----------------------------------------------------
# S3 LOG BUCKET (FIX: CKV_AWS_18, CKV_AWS_21, CKV2_AWS_61, CKV_AWS_145)
# ----------------------------------------------------

resource "aws_s3_bucket" "log_bucket" {
  bucket = "${local.name_prefix}-s3-access-logs-${local.account_id}"
  acl    = "log-delivery-write"

  # FIX: CKV_AWS_145 - Use KMS encryption
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.s3_key.arn
      }
    }
  }

  # FIX: CKV_AWS_21 - Ensure versioning is enabled
  versioning {
    enabled = true
  }

  # FIX: CKV2_AWS_61 - Add lifecycle rule for log retention
  lifecycle_rule {
    id      = "log-cleanup"
    enabled = true

    # Delete logs after 90 days
    expiration {
      days = 90
    }
  }
}

resource "aws_s3_bucket_public_access_block" "log_bucket_pab" {
  bucket                  = aws_s3_bucket.log_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ----------------------------------------------------
# MAIN S3 BUCKET (FIX: CKV_AWS_145, CKV_AWS_18, CKV2_AWS_6, CKV_AWS_21, CKV2_AWS_61)
# ----------------------------------------------------

resource "aws_s3_bucket" "s3_tf" {
  bucket = "${local.name_prefix}-s3-tf-bkt-${local.account_id}"
  acl    = "private"

  # FIX: CKV_AWS_145 - Switch to KMS encryption
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.s3_key.arn
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

    noncurrent_version_expiration {
      days = 90
    }
  }

  tags = {
    Name = "${local.name_prefix}-s3-tf-bkt"
  }
}

resource "aws_s3_bucket_public_access_block" "s3_tf_pab" {
  bucket                  = aws_s3_bucket.s3_tf.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# FIX: CKV_AWS_18 - Access logging configuration
resource "aws_s3_bucket_logging" "s3_tf_logging" {
  bucket        = aws_s3_bucket.s3_tf.id
  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "log/"
}