provider "aws" {
  region = var.aws_region

  # Same four cost allocation tags as dev and prod. Environment is "ci" here, so
  # Cost Explorer can separate the long lived supply chain resources from the
  # short lived cluster environments. That distinction is the point of this root
  # module: everything in it is meant to stay up, and everything in dev is meant
  # to be destroyed the same session.
  #
  # See docs/architecture.md section 5 for why default_tags rather than per
  # resource tags.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "terraform"
    }
  }
}
