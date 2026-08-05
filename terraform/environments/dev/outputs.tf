output "aws_region" {
  description = "Region this environment is deployed to. Used by `make kubeconfig`."
  value       = var.aws_region
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.cluster.cluster_endpoint
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider ARN. Chapter 2 and 3 IRSA roles trust this."
  value       = module.cluster.oidc_provider_arn
}

output "ecr_repository_url" {
  description = "Push and pull target for application images."
  value       = module.registry.repository_url
}

output "nat_gateway_public_ips" {
  description = "Addresses all outbound traffic from this environment appears to come from."
  value       = module.network.nat_gateway_public_ips
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.cluster.cluster_name}"
}
