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
  description = "The exact `sub` claims permitted to assume the push role. Worth reading back after apply, because this is the boundary the whole pipeline rests on."
  value       = local.push_subjects
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
