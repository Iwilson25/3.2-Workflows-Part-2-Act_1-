provider "aws" {
  region = "us-east-1"
}

terraform {
  backend "s3" {
    bucket = "sctp-ce11-tfstate"
    key    = "ninadc.tfstate"  #Change this
    region = "us-east-1"
  }
}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${split("/", "${data.aws_caller_identity.current.arn}")[1]}" #if your name contains any invalid characters like “.”, hardcode this name_prefix value = <YOUR NAME>
  account_id  = "${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "s3_tf" {
  bucket = "${local.name_prefix}-s3-tf-bkt-${local.account_id}"
}

