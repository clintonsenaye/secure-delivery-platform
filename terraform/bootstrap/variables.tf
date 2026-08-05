variable "aws_region" {
  description = "AWS region the state bucket lives in. All environments read state from this one region."
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Short project slug. Used as a name prefix and as the Project cost allocation tag."
  type        = string
  default     = "secure-delivery"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project_name))
    error_message = "project_name must be 3 to 32 characters of lowercase letters, digits or hyphens."
  }
}

variable "owner" {
  description = "Person or team accountable for this infrastructure. Applied as the Owner cost allocation tag."
  type        = string
}
