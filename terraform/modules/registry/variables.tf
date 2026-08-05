variable "repository_name" {
  description = "ECR repository name, for example secure-delivery-dev/app."
  type        = string
}

variable "image_tag_mutability" {
  description = "IMMUTABLE stops a tag ever being repointed at different bytes. Do not set this to MUTABLE without a very good reason."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["IMMUTABLE", "MUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be IMMUTABLE or MUTABLE."
  }
}

variable "scan_on_push" {
  description = "Run a free basic CVE scan on every pushed image."
  type        = bool
  default     = true
}

variable "encryption_type" {
  description = "AES256 (free) or KMS (customer managed key, about $1/month plus per request charges)."
  type        = string
  default     = "AES256"

  validation {
    condition     = contains(["AES256", "KMS"], var.encryption_type)
    error_message = "encryption_type must be AES256 or KMS."
  }
}

variable "kms_key_arn" {
  description = "KMS key ARN. Only used when encryption_type is KMS."
  type        = string
  default     = null
}

variable "untagged_expiry_days" {
  description = "Delete untagged images this many days after push. Untagged images are the debris of superseded pushes."
  type        = number
  default     = 14
}

variable "max_tagged_images" {
  description = "Cap on retained tagged images. Evaluated after the untagged rule because it has a higher rule priority."
  type        = number
  default     = 30
}

variable "force_delete" {
  description = "Allow terraform destroy to remove a repository that still contains images. Dev only."
  type        = bool
  default     = false
}

variable "pull_principal_arns" {
  description = "IAM principals granted pull only access via a repository policy. Empty means no repository policy is created."
  type        = list(string)
  default     = []
}
