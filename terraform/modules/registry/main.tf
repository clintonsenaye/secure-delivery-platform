##############################################################################
# Registry module.
#
# A small module where nearly every argument is a security control rather than a
# convenience setting. This is the shelf that signed images will sit on, so the
# guarantees it makes are the guarantees the rest of the platform inherits.
##############################################################################

resource "aws_ecr_repository" "this" {
  #checkov:skip=CKV_AWS_136:AES256 (SSE-S3 equivalent) is used rather than KMS, deliberately. KMS adds about $1/month plus per request charges and buys key rotation and cross account grants, neither of which this single account project needs. encryption_type is a variable, so switching is a value change.
  name = var.repository_name

  # THE important setting in this module.
  #
  # IMMUTABLE means a tag can never be repointed. Once myapp:v1.2.3 exists, no
  # push can replace it. On a platform whose entire premise is proving where an
  # image came from, mutable tags would undermine everything: you could verify a
  # signature on Monday and be running different bytes on Tuesday under the same
  # tag, with nothing in the audit trail to show it.
  #
  # The cost is that CI can no longer push :latest repeatedly. That is the point.
  # Later chapters tag by commit SHA instead.
  image_tag_mutability = var.image_tag_mutability

  image_scanning_configuration {
    # Free basic CVE scanning on every push, using the Clair based AWS scanner.
    # Enhanced scanning via Amazon Inspector is better (it scans OS and language
    # packages continuously, not just at push time) but it is billed per image,
    # so basic is the proportionate choice here.
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    # AES256 is SSE-S3 equivalent and free. KMS would allow key rotation and
    # cross account grants, at about $1/month plus per request charges.
    encryption_type = var.encryption_type
    kms_key         = var.encryption_type == "KMS" ? var.kms_key_arn : null
  }

  # Refuses to delete a repository that still contains images. Turn on only in
  # dev, where tearing the environment down repeatedly is the normal workflow.
  force_delete = var.force_delete

  tags = {
    Name = var.repository_name
  }
}

##############################################################################
# Lifecycle policy
#
# ECR bills per GB per month, and image layers accumulate fast. Two rules.
#
# RULE PRIORITY IS THE THING TO UNDERSTAND HERE. Rules are evaluated in
# ascending rulePriority order and the FIRST rule that matches an image wins.
# So the narrow rule (untagged) must have a lower number than the broad one
# (keep last N tagged). Reverse them and the broad rule matches everything
# first, and the untagged rule never fires at all.
##############################################################################

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep only the most recent ${var.max_tagged_images} tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_tagged_images
        }
        action = {
          type = "expire"
        }
      },
    ]
  })
}

##############################################################################
# Repository policy (optional)
#
# Off by default. Turned on in a later chapter when a separate account or a CI
# principal needs pull access. Note this grants pull only, never push: pushes
# should come from one place, through the pipeline, so provenance is meaningful.
##############################################################################

data "aws_iam_policy_document" "pull" {
  count = length(var.pull_principal_arns) > 0 ? 1 : 0

  statement {
    sid    = "AllowPull"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = var.pull_principal_arns
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }
}

resource "aws_ecr_repository_policy" "this" {
  count = length(var.pull_principal_arns) > 0 ? 1 : 0

  repository = aws_ecr_repository.this.name
  policy     = data.aws_iam_policy_document.pull[0].json
}
