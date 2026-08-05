output "repository_url" {
  description = "Repository URL used in an image reference, for example 123456789012.dkr.ecr.eu-west-2.amazonaws.com/secure-delivery-dev/app."
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "Repository ARN, for scoping IAM policies to this one repository."
  value       = aws_ecr_repository.this.arn
}

output "repository_name" {
  description = "Repository name."
  value       = aws_ecr_repository.this.name
}

output "registry_id" {
  description = "AWS account ID that owns the registry."
  value       = aws_ecr_repository.this.registry_id
}
