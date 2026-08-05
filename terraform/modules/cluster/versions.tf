terraform {
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    # Used once, to read the EKS OIDC issuer certificate so its SHA1 thumbprint
    # can be registered with IAM.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
