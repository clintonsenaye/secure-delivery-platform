variable "aws_region" {
  description = "Region for this environment."
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Project slug. Becomes the Project cost allocation tag and part of every resource name."
  type        = string
  default     = "secure-delivery"
}

variable "environment" {
  description = "Environment name. Becomes the Environment cost allocation tag."
  type        = string
  default     = "dev"
}

variable "owner" {
  description = "Person or team accountable for this environment. Becomes the Owner cost allocation tag."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR for dev. Kept distinct from prod so the two could be peered later without renumbering."
  type        = string
  default     = "10.0.0.0/16"
}

variable "nat_gateway_count" {
  description = "NAT gateways. 1 is the cheap default, 2 gives one per AZ. See docs/architecture.md."
  type        = number
  default     = 1
}

variable "cluster_version" {
  description = "Kubernetes version. Verify against `aws eks describe-cluster-versions` before first apply."
  type        = string
  default     = "1.35"
}

variable "public_access_cidrs" {
  description = <<-EOT
    Your public IP, as a /32, permitted to reach the Kubernetes API.
    No default on purpose. Get it with: curl -s https://checkip.amazonaws.com
  EOT
  type        = list(string)
}
