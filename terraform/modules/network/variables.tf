variable "name_prefix" {
  description = "Prefix applied to the Name tag of every resource, for example secure-delivery-dev."
  type        = string
}

variable "aws_region" {
  description = "Region, needed to build the VPC endpoint service name."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. A /16 gives room for the VPC CNI to assign a real IP to every pod."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) <= 18
    error_message = "vpc_cidr must be valid CIDR of /18 or larger, otherwise the /20 subnet split will not fit."
  }
}

variable "az_count" {
  description = "How many availability zones to spread subnets across. Two is the minimum EKS accepts."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3. EKS requires subnets in at least two AZs."
  }
}

variable "nat_gateway_count" {
  description = <<-EOT
    Number of NAT gateways. This is the biggest cost lever in the module.
    1 = one shared gateway, about $36/month, single point of failure for egress.
    2 = one per AZ, about $72/month, survives an AZ outage and avoids cross AZ
        data transfer charges on egress traffic.
    Must be between 1 and az_count.
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.nat_gateway_count >= 1 && var.nat_gateway_count <= 3
    error_message = "nat_gateway_count must be between 1 and 3, and no greater than az_count."
  }
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch. Useful for security review, billed per GB ingested."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "Retention for the flow log group. Short by default so logs do not accrue cost silently."
  type        = number
  default     = 7
}
