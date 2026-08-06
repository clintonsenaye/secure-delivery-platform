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
  EOT
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be in the form owner/name, for example clintonsenaye/secure-delivery-platform."
  }
}

variable "push_allowed_refs" {
  description = <<-EOT
    Git refs whose workflow runs may assume the ECR push role.

    Kept to refs/heads/main deliberately. A pull request run receives the subject
    claim `repo:owner/name:pull_request` rather than a ref claim, so it cannot
    match this list and cannot obtain AWS credentials at all. That is enforced by
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

    Written as complete claims rather than refs because a pull request run's
    claim has a different shape: `repo:owner/name:pull_request`, with no ref
    component at all. Interpolated with the repository name in main.tf.

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
