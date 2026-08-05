provider "aws" {
  region = var.aws_region

  # Every resource created by this provider is tagged automatically, with no need
  # to remember a tags block on each resource. See docs/architecture.md for why
  # cost allocation tags are worth the effort.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = "shared"
      Owner       = var.owner
      ManagedBy   = "terraform"
    }
  }
}
