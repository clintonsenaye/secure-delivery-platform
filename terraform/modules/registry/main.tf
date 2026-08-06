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

  # Chapter 3 addition, and it looks like a retreat until you read why it is not.
  #
  # Cosign stores signatures and attestations as tags in this same repository,
  # named after the digest they describe: sha256-<digest>.sig and
  # sha256-<digest>.att. Attaching a second attestation updates an existing tag,
  # which a fully IMMUTABLE repository refuses, so signing fails.
  #
  # The narrow exclusion below keeps every application tag immutable and makes
  # only the sha256-* namespace writable. Those tags are already content
  # addressed by construction, so writing one can only change the metadata
  # attached to one specific digest. It cannot make a signature apply to
  # different bytes, which is the whole reason immutability is here.
  #
  # Empty by default, so chapter 1's dev environment is unchanged.
  dynamic "image_tag_mutability_exclusion_filter" {
    for_each = var.image_tag_mutability_exclusion_filters

    content {
      filter      = image_tag_mutability_exclusion_filter.value
      filter_type = "WILDCARD"
    }
  }

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
# ECR bills per GB per month, and image layers accumulate fast.
#
# RULE PRIORITY IS THE FIRST THING TO UNDERSTAND HERE. Rules are evaluated in
# ascending rulePriority order and the FIRST rule that matches an image wins; an
# image is never acted on by more than one rule. So the narrow rules must have
# lower numbers than the broad one. Reverse them and the broad rule matches
# everything first and the narrow rules never fire at all. This is a classic ECR
# mistake and it fails silently: the policy looks configured and quietly does
# something else.
#
# ECR additionally requires that the rule with tagStatus "any" carries the
# HIGHEST rulePriority, which is the same constraint stated from the other end.
#
# THE SECOND THING TO UNDERSTAND is why signature tags get their own rule. A
# single "keep the last N tagged images" rule counts cosign's sha256-*.sig and
# sha256-*.att artefacts as images, so it expires the signatures of your oldest
# still-running images long before it expires the images themselves. See
# var.signature_tag_prefixes for what that failure looks like weeks later.
##############################################################################

locals {
  # Built as a list so the optional rules can be dropped cleanly, then numbered
  # at the end. Numbering in one place means a rule cannot be inserted with a
  # priority that silently shadows another.
  lifecycle_rules_ordered = concat(
    [
      {
        description = "Expire untagged images after ${var.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
      },
    ],

    length(var.signature_tag_prefixes) == 0 ? [] : [
      {
        description = "Keep the most recent ${var.max_signature_artefacts} cosign signature and attestation artefacts"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = var.signature_tag_prefixes
          countType     = "imageCountMoreThan"
          countNumber   = var.max_signature_artefacts
        }
      },
    ],

    length(var.app_tag_prefixes) == 0 ? [] : [
      {
        description = "Keep the most recent ${var.max_tagged_images} application images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = var.app_tag_prefixes
          countType     = "imageCountMoreThan"
          countNumber   = var.max_tagged_images
        }
      },
    ],

    # The catch-all, and it must be last. It exists so a hand pushed tag that
    # matches none of the prefixes above cannot accumulate forever, which is
    # exactly what the bypass demonstration in docs/demonstrations.md produces.
    [
      {
        description = "Catch-all cap on anything not matched above"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_tagged_images + var.max_signature_artefacts
        }
      },
    ],
  )
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      for i, r in local.lifecycle_rules_ordered : {
        rulePriority = i + 1
        description  = r.description
        selection    = r.selection
        action       = { type = "expire" }
      }
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
