##############################################################################
# ci environment. Chapter 3.
#
# THE SHORT VERSION: this is the entire AWS footprint of chapter 3, and it costs
# roughly one penny a month.
#
# WHY IT IS A SEPARATE ROOT MODULE
#
# Chapter 3 needs three real AWS things: an identity provider so GitHub can prove
# who it is, a role for it to assume, and a registry to push to. It does not need
# a cluster. Everything the cluster contributes (admission control, the policy
# engine, the rejection you can watch happen) is proven on the free local kind
# cluster.
#
# Bolting these onto terraform/environments/dev would have tied running the
# pipeline to applying an EKS control plane and a NAT gateway, which is about
# $0.18/hour and roughly $130/month if left up. Splitting them means dev stays
# destroyed and the supply chain stays up.
#
# There is a second, less obvious reason. The dev registry is destroyed whenever
# dev is destroyed, taking every signed image and every signature with it. A
# registry whose lifecycle is bound to an ephemeral cluster is the wrong shape
# for a registry. This one is meant to be applied once and left alone.
#
# WHAT IT COSTS
#
#   IAM OIDC provider                free
#   IAM roles and policies           free
#   ECR storage                      $0.10/GB/month, and the images are ~12 MB
#   GitHub Actions on a public repo  free
#   Sigstore public good instance    free
#
# Call it one penny a month. Compare with docs/architecture.md section 15.
#
# WHAT IS DELIBERATELY NOT HERE
#
# No VPC, no NAT gateway, no EKS. Chapter 3 does not need them. The two things it
# genuinely cannot prove without a real cluster are IRSA supplying Kyverno's
# registry credentials, and the node role pulling from ECR without an image pull
# secret. Both are written up as known limits rather than claimed.
##############################################################################

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

##############################################################################
# The registry the pipeline pushes signed images to.
##############################################################################

module "registry" {
  source = "../../modules/registry"

  repository_name = "${local.name_prefix}/app"

  # Chapter 1's claim, kept, with one narrow and deliberate exception.
  #
  # Application tags stay immutable, so a verified signature keeps meaning what
  # it meant. The exception exists because cosign stores its signatures and
  # attestations as tags derived from the digest they describe, and attaching a
  # second attestation updates one of those tags. Without the exclusion, signing
  # simply fails on the second attestation.
  #
  # The exclusion is safe for a specific reason rather than as a convenience: a
  # sha256-* tag is already content addressed, so writing one can only change
  # metadata about one exact digest. It cannot repoint a name at different bytes,
  # which is the attack immutability exists to prevent.
  #
  # See modules/registry/variables.tf for the long form, and docs/architecture.md
  # section 26.
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"
  image_tag_mutability_exclusion_filters = [
    "sha256-*", # cosign .sig and .att artefacts
  ]

  scan_on_push = true

  # Retention, with signatures counted separately from images.
  #
  # A single combined cap silently expires the signatures of your oldest still
  # running images, and the failure only shows up weeks later when a pod is
  # rescheduled and Kyverno reports "no matching signatures" for an image that
  # was signed perfectly well. See modules/registry/variables.tf.
  app_tag_prefixes        = ["sha-"]
  max_tagged_images       = var.max_tagged_images
  signature_tag_prefixes  = ["sha256-"]
  max_signature_artefacts = var.max_tagged_images * 3
  untagged_expiry_days    = 14

  # FALSE, unlike dev.
  #
  # This repository holds the signed images that running pods reference by
  # digest. `terraform destroy` should refuse while it still contains images,
  # because destroying it does not just lose artefacts, it makes every running
  # pod unverifiable and unschedulable. Emptying it has to be a deliberate,
  # separate act.
  force_delete = false
}

##############################################################################
# The identity GitHub Actions assumes. No access key exists anywhere.
##############################################################################

module "github_oidc" {
  source = "../../modules/github_oidc"

  name_prefix          = local.name_prefix
  github_repository    = var.github_repository
  create_oidc_provider = var.create_github_oidc_provider

  # The immutable numeric IDs GitHub embeds in the OIDC subject claim.
  #
  # These are not cosmetic. Since 15 July 2026 GitHub sends
  #
  #   repo:OWNER@OWNER-ID/NAME@REPO-ID:ref:refs/heads/main
  #
  # and a trust policy built from names alone does not match it, so
  # AssumeRoleWithWebIdentity is refused and the pipeline cannot reach AWS.
  #
  # They are also the stronger thing to match on, not merely the newer thing:
  # a name can be released and taken by somebody else, and an ID cannot. See
  # docs/architecture.md section 29.
  github_owner_id      = var.github_owner_id
  github_repository_id = var.github_repository_id

  # Push is scoped to main. A pull request run receives a differently shaped
  # subject claim and cannot assume this role at all, which is why the scanning
  # job and the build job are separate jobs rather than one job with an `if`.
  push_allowed_refs = var.github_push_refs

  # Scoped to this one repository ARN. The role cannot push anywhere else in the
  # registry, and has no permission outside ECR at all.
  ecr_repository_arns = [module.registry.repository_arn]

  # The second, read only role used by the terraform plan workflow on pull
  # requests. Separate from the push role on purpose: a pull request from a fork
  # can assume the plan role, and must never be able to publish an image.
  create_plan_role   = var.create_plan_role
  state_bucket_arn   = var.state_bucket_arn
  state_key_prefixes = ["env/"]
}
