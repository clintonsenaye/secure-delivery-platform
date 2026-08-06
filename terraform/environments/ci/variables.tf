variable "aws_region" {
  description = "Region for the supply chain resources. Should match the region the clusters run in, so image pulls do not cross a region boundary."
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Project slug. Becomes the Project cost allocation tag and part of every resource name."
  type        = string
  default     = "secure-delivery"
}

variable "environment" {
  description = "Environment name. Becomes the Environment cost allocation tag. 'ci' rather than 'shared', because everything here exists to serve the pipeline."
  type        = string
  default     = "ci"
}

variable "owner" {
  description = "Person or team accountable for this environment. Becomes the Owner cost allocation tag."
  type        = string
}

variable "github_repository" {
  description = <<-EOT
    The repository permitted to assume the IAM roles, as owner/name.

    This is the trust boundary of the entire pipeline. Getting it wrong in the
    permissive direction, or widening it to a wildcard, means workflows outside
    this repository can obtain credentials in this AWS account.
  EOT
  type        = string
  default     = "clintonsenaye/secure-delivery-platform"
}

variable "github_push_refs" {
  description = "Git refs whose workflow runs may assume the ECR push role. Exact refs only; the trust policy uses StringEquals."
  type        = list(string)
  default     = ["refs/heads/main"]
}

variable "state_bucket_arn" {
  description = <<-EOT
    ARN of the Terraform state bucket created by `make bootstrap`, so the read
    only plan role can read state on pull requests.

    Get it with:
      cd terraform/bootstrap && terraform output -raw state_bucket_arn

    Leave null to skip the state read permission, in which case the plan workflow
    can only run `terraform validate` rather than a real plan.
  EOT
  type        = string
  default     = null
}

variable "create_plan_role" {
  description = "Create the read only role used by .github/workflows/terraform-plan.yml."
  type        = bool
  default     = true
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Create the IAM OIDC provider for GitHub Actions.

    An AWS account may hold exactly ONE provider per issuer URL. Set to false if
    another project in this account already registered GitHub, and the module
    looks the existing one up instead of failing with EntityAlreadyExists.
  EOT
  type        = bool
  default     = true
}

variable "max_tagged_images" {
  description = "Application images retained in ECR. Small, because every build produces one and this project is not a real product."
  type        = number
  default     = 30
}
