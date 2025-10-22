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
# KMS KEY (FIX: CKV_AWS_7 - Key Rotation)
# ----------------------------------------------------

resource "aws_kms_key" "s3_key" {
  description             = "KMS key for S3 bucket encryption"
  deletion_window_in_days = 10

  # FIX: CKV_AWS_7 - Enable key rotation for customer created CMK
  enable_key_rotation = true

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
# SQS QUEUE FOR EVENT NOTIFICATIONS (FIX: CKV2_AWS_62, CKV_AWS_27)
# ----------------------------------------------------

# FIX: CKV_AWS_27 - Ensure SQS queue is encrypted with KMS
resource "aws_sqs_queue" "s3_notifications" {
  name = "${local.name_prefix}-s3-notifications"

  # Configuration to enable SSE-KMS using the key defined above
  kms_master_key_id       = aws_kms_key.s3_key.arn
  sqs_managed_sse_enabled = false
}

# SQS Queue Policy to allow S3 to send messages
resource "aws_sqs_queue_policy" "s3_notification_policy" {
  queue_url = aws_sqs_queue.s3_notifications.id

  policy = jsonencode({
    Version = "2012-10-17",
    Id      = "SQSQueuePolicy",
    Statement = [
      {
        Sid    = "AllowS3Notifications",
        Effect = "Allow",
        Principal = {
          Service = "s3.amazonaws.com"
        },
        Action   = "sqs:SendMessage",
        Resource = aws_sqs_queue.s3_notifications.arn,
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = [aws_s3_bucket.log_bucket.arn, aws_s3_bucket.s3_tf.arn]
          }
        }
      }
    ]
  })
}

# ----------------------------------------------------
# S3 LOG BUCKET (CKV_AWS_145, CKV_AWS_21, CKV2_AWS_61)
# ----------------------------------------------------

resource "aws_s3_bucket" "log_bucket" {
  bucket = "${local.name_prefix}-s3-access-logs-${local.account_id}"
  acl    = "log-delivery-write"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.s3_key.arn
      }
    }
  }

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "log-cleanup"
    enabled = true

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
# MAIN S3 BUCKET 
# ----------------------------------------------------

resource "aws_s3_bucket" "s3_tf" {
  bucket = "${local.name_prefix}-s3-tf-bkt-${local.account_id}"
  acl    = "private"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.s3_key.arn
      }
    }
  }

  versioning {
    enabled = true
  }

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

resource "aws_s3_bucket_logging" "s3_tf_logging" {
  bucket        = aws_s3_bucket.s3_tf.id
  target_bucket = aws_s3_bucket.log_bucket.id
  target_prefix = "log/"
}

# CKV2_AWS_62 - Event notification configuration for both buckets
resource "aws_s3_bucket_notification" "bucket_notifications" {
  bucket = aws_s3_bucket.s3_tf.id

  queue {
    id        = "main-s3-events"
    queue_arn = aws_sqs_queue.s3_notifications.arn
    events    = ["s3:ObjectCreated:*"]
  }
}

resource "aws_s3_bucket_notification" "log_bucket_notifications" {
  bucket = aws_s3_bucket.log_bucket.id

  queue {
    id        = "log-s3-events"
    queue_arn = aws_sqs_queue.s3_notifications.arn
    events    = ["s3:ObjectCreated:*"]
  }
  depends_on = [aws_sqs_queue_policy.s3_notification_policy]
}

# NOTE: CKV_AWS_144 (Cross-region replication) is a business/DR requirement 
# that remains. It is the last major check.