variable "name_prefix" {
  description = "Prefix for every resource name this module creates, for example secure-delivery-ci."
  type        = string
}

variable "github_repository" {
  description = <<-EOT
    The repository allowed to assume these roles, as owner/name.

    This value is the single most important input in the module. It is
    interpolated into the trust policy's `sub` condition, and a trust policy
    without a correctly scoped `sub` condition can be assumed by any GitHub
    Actions workflow in any repository on GitHub.

    Since July 2026 the name alone is no longer the whole claim. It is paired
    with the immutable numeric IDs below. See github_repository_id.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be in the form owner/name, for example clintonsenaye/secure-delivery-platform."
  }
}

##############################################################################
# Immutable identifiers.
#
# These two variables are why the trust policy works at all. Read
# docs/architecture.md section 29 before changing either of them.
##############################################################################

variable "github_owner_id" {
  description = <<-EOT
    The immutable numeric ID of the GitHub user or organisation that owns the
    repository. NOT the username.

    Get it with:
      gh api repos/OWNER/NAME --jq .owner.id

    A string rather than a number on purpose. This is an identifier, not a
    quantity: nothing is ever added to it or compared for size, and treating it
    as a number invites Terraform to render it in a form that does not match the
    claim byte for byte.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be the numeric owner ID, digits only. Get it with: gh api repos/OWNER/NAME --jq .owner.id"
  }
}

variable "github_repository_id" {
  description = <<-EOT
    The immutable numeric ID of the repository itself. NOT the repository name.

    Get it with:
      gh api repos/OWNER/NAME --jq .id

    WHY THIS EXISTS AT ALL.

    GitHub's OIDC subject claim used to be built from mutable names:

      repo:clintonsenaye/secure-delivery-platform:ref:refs/heads/main

    Names can be renamed, transferred, deleted and recreated. Since 15 July 2026
    GitHub embeds the permanent numeric IDs alongside the names, using @ as the
    separator because @ cannot appear in a GitHub username or repository name:

      repo:clintonsenaye@57267374/secure-delivery-platform@1323617369:ref:refs/heads/main

    A trust policy written against the old shape does not match the new one, and
    because the condition is StringEquals it fails closed: AssumeRoleWithWebIdentity
    is refused and the pipeline cannot reach AWS at all.

    The full argument, the attack this prevents, and how it was diagnosed are in
    docs/architecture.md section 29.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "github_repository_id must be the numeric repository ID, digits only. Get it with: gh api repos/OWNER/NAME --jq .id"
  }
}

variable "push_allowed_refs" {
  description = <<-EOT
    Git refs whose workflow runs may assume the ECR push role.

    Kept to refs/heads/main deliberately. A pull request run receives the subject
    claim ending in `:pull_request` rather than a ref claim, so it cannot match
    this list and cannot obtain AWS credentials at all. That is enforced by
    the shape of the claim rather than by an `if` in the workflow file, which is
    the stronger place to enforce it.

    Adding refs/tags/* here would require StringLike rather than StringEquals in
    the trust policy. Reaching for StringLike in a trust policy is a moment to
    slow down, so it is deliberately not done.
  EOT
  type        = list(string)
  default     = ["refs/heads/main"]

  validation {
    condition     = length(var.push_allowed_refs) > 0
    error_message = "push_allowed_refs must contain at least one ref, otherwise no workflow can ever push."
  }

  validation {
    condition     = alltrue([for r in var.push_allowed_refs : !strcontains(r, "*")])
    error_message = "Wildcards are not permitted. Every entry must be an exact ref, because the trust policy uses StringEquals."
  }
}

variable "ecr_repository_arns" {
  description = "ECR repository ARNs the push role may write to. Scoped to specific repositories, never the whole registry."
  type        = list(string)

  validation {
    condition     = length(var.ecr_repository_arns) > 0
    error_message = "ecr_repository_arns must not be empty. A push role with nothing to push to is a mistake, not a configuration."
  }
}

##############################################################################
# The read only plan role. Optional.
##############################################################################

variable "create_plan_role" {
  description = "Create a second, read only role for `terraform plan` on pull requests. Separate from the push role so a plan can never push an image."
  type        = bool
  default     = true
}

variable "plan_allowed_subjects" {
  description = <<-EOT
    Full subject claims permitted to assume the read only plan role.

    Written as complete claim suffixes rather than refs, because a pull request
    run's claim has a different shape: it ends in `:pull_request`, with no ref
    component at all. The immutable identifier prefix
    `repo:OWNER@OWNER-ID/NAME@REPO-ID` is prepended in main.tf, so it is written
    once and both roles share it.

    The defaults are pull requests and pushes to main, which is exactly when a
    plan is useful.
  EOT
  type        = list(string)
  default     = ["pull_request", "ref:refs/heads/main"]
}

variable "state_bucket_arn" {
  description = "ARN of the Terraform state bucket. The plan role is granted read only access to it. Required when create_plan_role is true."
  type        = string
  default     = null
}

variable "state_key_prefixes" {
  description = "Object key prefixes within the state bucket the plan role may read. Empty means the whole bucket."
  type        = list(string)
  default     = ["env/"]
}

variable "max_session_duration" {
  description = "Maximum lifetime of an assumed session, in seconds. One hour is the AWS default and is far longer than any job here needs."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 900 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 900 and 43200 seconds."
  }
}

##############################################################################
# The OIDC provider itself
##############################################################################

variable "create_oidc_provider" {
  description = <<-EOT
    Create the IAM OIDC provider for token.actions.githubusercontent.com.

    An AWS account may hold exactly ONE OIDC provider per issuer URL. If another
    project in this account has already registered GitHub, `terraform apply`
    fails with EntityAlreadyExists. Set this to false in that case and the module
    looks the existing provider up instead.
  EOT
  type        = bool
  default     = true
}

variable "oidc_thumbprints" {
  description = <<-EOT
    Certificate thumbprints for the OIDC provider.

    Vestigial for this issuer. Since 2023 IAM validates token.actions.
    githubusercontent.com against a trusted root certificate authority and
    ignores the thumbprint list entirely, which is why the value that a hundred
    tutorials tell you to paste has changed twice without breaking anyone. Left
    as a variable because the API still accepts the field, and defaulted to empty
    because supplying a stale SHA1 fingerprint would imply it matters.
  EOT
  type        = list(string)
  default     = []
}
