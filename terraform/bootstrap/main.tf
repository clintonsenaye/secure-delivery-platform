##############################################################################
# Bootstrap: the remote state backend.
#
# Run this ONCE per AWS account, before any environment. It creates the single
# S3 bucket that dev and prod store their Terraform state in.
#
# There is no DynamoDB lock table. As of Terraform 1.11 the S3 backend's
# dynamodb_table argument is deprecated in favour of use_lockfile = true, which
# performs locking with an S3 conditional write (a zero byte .tflock object next
# to the state file). One less resource, one less IAM policy, one less thing to
# pay for, and no risk of the lock table drifting out of sync with the bucket.
##############################################################################

data "aws_caller_identity" "current" {}

locals {
  # Bucket names are globally unique across all of AWS, so the account ID and
  # region are appended to keep this reproducible without manual invention.
  bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
}

# The single filing cabinet for all Terraform state in this project. Environments
# are separated by object key prefix (env/dev/, env/prod/), not by bucket.
resource "aws_s3_bucket" "state" {
  #checkov:skip=CKV_AWS_18:Server access logging needs a second bucket and bills per request. Out of scope for a portfolio project; CloudTrail data events would be the production answer.
  #checkov:skip=CKV_AWS_144:Cross-region replication doubles storage cost and is disproportionate for a single-account portfolio project. Versioning already covers accidental deletion.
  #checkov:skip=CKV2_AWS_62:S3 event notifications are not needed; nothing consumes state change events yet.
  #checkov:skip=CKV2_AWS_61:Lifecycle configuration is defined below in a separate resource, which Checkov does not always associate.
  #checkov:skip=CKV_AWS_145:SSE-S3 (AES256) is used rather than SSE-KMS, deliberately. KMS would add per request charges on every state read and write and buys key rotation plus cross account access, neither of which a single account portfolio project needs. The bucket policy below already denies any non TLS request.
  bucket = local.bucket_name

  # Terraform state is the source of truth for the whole platform. Deleting this
  # bucket by accident would be unrecoverable, so destruction is blocked in code.
  lifecycle {
    prevent_destroy = true
  }
}

# Keeps every previous version of every state file. This is the single most
# important safety net in Terraform: a corrupted or truncated state can be rolled
# back to the last good version instead of being rebuilt by hand.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Encrypts state at rest. State contains resource IDs, ARNs and occasionally
# generated values, so it is treated as sensitive. SSE-S3 (AES256) is used rather
# than SSE-KMS because it is free and this project has no key rotation or
# cross-account state access requirement.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  #checkov:skip=CKV2_AWS_67:Customer managed KMS key rotation is not applicable; this bucket uses SSE-S3 by deliberate cost decision, documented in docs/architecture.md.
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    # Reduces per-request KMS calls. Harmless with AES256 and correct if this is
    # ever migrated to SSE-KMS.
    bucket_key_enabled = true
  }
}

# Makes it impossible to accidentally expose state to the public internet, even if
# a future bucket policy or ACL tries to. Four separate switches, all on.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Rejects any PutObject that is not sent over TLS. Without this, an unencrypted
# HTTP write of state would be accepted by S3.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state.json

  # A public access block must exist before a bucket policy is applied, otherwise
  # the policy can briefly be evaluated without those guardrails in place.
  depends_on = [aws_s3_bucket_public_access_block.state]
}

data "aws_iam_policy_document" "state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# Expires old state versions after 90 days so the bucket does not grow without
# bound. Versioning without expiry is a slow storage leak: every apply writes a
# new version and nothing ever removes the old ones.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-noncurrent-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # Cleans up multipart uploads that failed midway. These are invisible in the
    # console but are still billed.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
