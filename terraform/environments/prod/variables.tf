variable "aws_region" {
  description = "Region for this environment."
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Project slug. Becomes the Project cost allocation tag."
  type        = string
  default     = "secure-delivery"
}

variable "environment" {
  description = "Environment name. Becomes the Environment cost allocation tag."
  type        = string
  default     = "prod"
}

variable "owner" {
  description = "Person or team accountable for this environment."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR for prod. Deliberately non overlapping with dev so the two could be peered later."
  type        = string
  default     = "10.1.0.0/16"
}

variable "nat_gateway_count" {
  description = "NAT gateways. Set to 2 for one per AZ if this were ever actually applied."
  type        = number
  default     = 1
}

variable "cluster_version" {
  description = "Kubernetes version. Prod would normally trail dev by one minor version."
  type        = string
  default     = "1.34"
}

variable "public_access_cidrs" {
  description = "CIDRs permitted to reach the Kubernetes API. Required, no default, even here."
  type        = list(string)
}
