variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as a prefix for its IAM roles."
  type        = string
}

variable "cluster_version" {
  description = <<-EOT
    Kubernetes minor version for the control plane. Check what is currently
    supported before first apply:
      aws eks describe-cluster-versions --region eu-west-2
    Running an unsupported version moves the cluster onto extended support, which
    costs six times the standard control plane rate.
  EOT
  type        = string
  default     = "1.35"
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for the control plane ENIs and the node group."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two availability zones."
  }
}

variable "public_access_cidrs" {
  description = <<-EOT
    CIDR blocks permitted to reach the public Kubernetes API endpoint.

    REQUIRED, with no default, on purpose. An open API endpoint (0.0.0.0/0) would
    contradict the premise of this project, so supplying your own address is a
    conscious act rather than an accident of a forgotten default.

    Find yours with:  curl -s https://checkip.amazonaws.com
    Then set:         public_access_cidrs = ["203.0.113.10/32"]

    Note this is your home or office egress IP and it usually changes. If the
    plan shows a diff here, that is why.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.public_access_cidrs) > 0
    error_message = "public_access_cidrs must not be empty. Supply at least one CIDR."
  }

  validation {
    condition     = !contains(var.public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 is refused. Exposing the Kubernetes API to the whole internet defeats the purpose of this platform. Use your own /32, or set endpoint_public_access to false and reach the API through a bastion or VPN."
  }
}

variable "enabled_cluster_log_types" {
  description = "Control plane log streams to publish to CloudWatch. audit is the one that records who called the API."
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

variable "log_retention_days" {
  description = "Retention for the control plane log group. Short in dev so logs do not accrue cost silently."
  type        = number
  default     = 7
}

variable "kms_key_arn" {
  description = "Customer managed KMS key ARN for envelope encrypting Kubernetes Secrets. Null disables it. A key costs about $1/month."
  type        = string
  default     = null
}

variable "bootstrap_creator_admin" {
  description = "Grant cluster admin to whoever runs terraform apply. Keeps you from locking yourself out on first apply."
  type        = bool
  default     = true
}

variable "cluster_admin_principal_arns" {
  description = "Additional IAM role or user ARNs granted cluster admin via EKS access entries. Must be the real IAM ARN, not an assumed-role STS ARN."
  type        = list(string)
  default     = []
}

##############################################################################
# Node group sizing. Every one of these moves the bill.
##############################################################################

variable "node_instance_types" {
  description = "Instance types for the managed node group. Listing several improves spot availability."
  type        = list(string)
  default     = ["t3.small"]
}

variable "node_capacity_type" {
  description = "SPOT or ON_DEMAND. SPOT is roughly 65 to 70 per cent cheaper and can be reclaimed with two minutes' notice."
  type        = string
  default     = "SPOT"

  validation {
    condition     = contains(["SPOT", "ON_DEMAND"], var.node_capacity_type)
    error_message = "node_capacity_type must be SPOT or ON_DEMAND."
  }
}

variable "node_ami_type" {
  description = "EKS AMI family. AL2023 is current; AL2 is end of life."
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "node_disk_size" {
  description = "EBS root volume size in GB per node. Container images are what fill this up."
  type        = number
  default     = 20
}

variable "node_min_size" {
  description = "Minimum nodes in the group."
  type        = number
  default     = 1
}

variable "node_desired_size" {
  description = "Starting node count. Ignored on subsequent applies so an autoscaler can own it."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Ceiling on node count. This is the cap on how large the bill can get."
  type        = number
  default     = 3
}

variable "node_labels" {
  description = "Kubernetes labels applied to every node in the group."
  type        = map(string)
  default     = {}
}

variable "enable_ssm_access" {
  description = "Attach AmazonSSMManagedInstanceCore so nodes are reachable via Session Manager with no SSH port or key pair."
  type        = bool
  default     = true
}
