output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for GitHub Actions. Every role's trust policy references this."
  value       = local.oidc_provider_arn
}

output "push_role_arn" {
  description = "Role the build workflow assumes. Set this as the repository variable AWS_ROLE_ARN."
  value       = aws_iam_role.push.arn
}

output "plan_role_arn" {
  description = "Read only role the terraform plan workflow assumes. Set this as the repository variable AWS_PLAN_ROLE_ARN."
  value       = var.create_plan_role ? aws_iam_role.plan[0].arn : null
}

output "allowed_push_subjects" {
  description = <<-EOT
    The exact `sub` claims permitted to assume the push role.

    Read this back after apply and compare it, character for character, against
    the `sub` value CloudTrail records on a failed AssumeRoleWithWebIdentity.
    That comparison is the whole diagnosis: the two strings either match or they
    do not, and StringEquals has no opinion about how nearly they match.
  EOT
  value       = local.push_subjects
}

output "allowed_plan_subjects" {
  description = "The exact `sub` claims permitted to assume the read only plan role. Emitted for the same reason as the push subjects: so a mismatch can be diffed rather than guessed at."
  value       = var.create_plan_role ? local.plan_subjects : []
}

output "repository_claim" {
  description = <<-EOT
    The immutable identifier form of this repository, without any ref suffix:

      repo:OWNER@OWNER-ID/NAME@REPO-ID

    Both roles' subject conditions are built from this one string, so if it is
    wrong, everything is wrong in the same direction. Compare it against what
    GitHub actually sends:

      gh api repos/OWNER/NAME --jq '"repo:\(.owner.login)@\(.owner.id)/\(.name)@\(.id)"'
  EOT
  value       = local.repo_claim
}

output "workflow_identity" {
  description = <<-EOT
    The certificate identity Fulcio issues to a run of the build workflow on the
    first allowed ref.

    This exact string must appear as `subject` in policies/require-signed-images.yaml
    and as --certificate-identity in every cosign verify command. It is emitted
    here so it can be checked against the infrastructure rather than retyped, and
    a mismatch between this and the policy is the most likely cause of a
    verification failure that looks like a signing failure.
  EOT
  value       = "${local.workflow_identity_prefix}/build-sign-attest.yml@${var.push_allowed_refs[0]}"
}
