##############################################################################
# These outputs are the handover from Terraform to everything else in chapter 3.
#
# After `make apply ENV=ci`, run `make ci-config` to have the Makefile print the
# GitHub repository variables and the Kyverno policy values in a form you can
# paste, so none of these strings has to be retyped. A typo in the workflow
# identity produces a verification failure that looks exactly like a signing
# failure, which is an unpleasant hour.
##############################################################################

output "aws_region" {
  description = "Region these resources live in."
  value       = var.aws_region
}

output "ecr_repository_url" {
  description = "Push target for the pipeline and pull target for the cluster. Set as the GitHub repository variable ECR_REPOSITORY."
  value       = module.registry.repository_url
}

output "ecr_repository_name" {
  description = "Repository name, for `aws ecr describe-images --repository-name`."
  value       = module.registry.repository_name
}

output "ecr_registry" {
  description = "Registry host, for `docker login`."
  value       = split("/", module.registry.repository_url)[0]
}

output "github_oidc_provider_arn" {
  description = "IAM OIDC provider trusted to issue GitHub Actions identities."
  value       = module.github_oidc.oidc_provider_arn
}

output "gha_push_role_arn" {
  description = "Role the build workflow assumes. Set as the GitHub repository variable AWS_ROLE_ARN."
  value       = module.github_oidc.push_role_arn
}

output "gha_plan_role_arn" {
  description = "Read only role the terraform plan workflow assumes. Set as the GitHub repository variable AWS_PLAN_ROLE_ARN."
  value       = module.github_oidc.plan_role_arn
}

output "allowed_push_subjects" {
  description = "The exact OIDC subject claims permitted to assume the push role. Read this back after apply: it is the trust boundary of the whole pipeline."
  value       = module.github_oidc.allowed_push_subjects
}

output "cosign_certificate_identity" {
  description = <<-EOT
    The Fulcio certificate identity a run of the build workflow signs with.

    This exact string must appear as `subject` in both files under policies/, and
    as --certificate-identity in every cosign verify command. A wildcard here
    would make the policy accept a signature from any GitHub Actions workflow on
    the internet, which is barely a higher bar than accepting anything at all.
  EOT
  value       = module.github_oidc.workflow_identity
}

output "cosign_certificate_oidc_issuer" {
  description = "The Fulcio certificate issuer for GitHub Actions identities. Constant, but emitted so the policy can be checked against it."
  value       = "https://token.actions.githubusercontent.com"
}
