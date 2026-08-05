output "cluster_name" {
  description = "EKS cluster name."
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.cluster.cluster_endpoint
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN."
  value       = module.cluster.oidc_provider_arn
}

output "ecr_repository_url" {
  description = "Push and pull target for application images."
  value       = module.registry.repository_url
}
