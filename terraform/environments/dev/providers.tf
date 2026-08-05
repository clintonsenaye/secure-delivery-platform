provider "aws" {
  region = var.aws_region

  # default_tags applies these to every taggable resource this provider creates,
  # with no need for a tags block on each resource.
  #
  # Why bother:
  #  - Cost allocation. Activate these as cost allocation tags in Billing and AWS
  #    Cost Explorer can then answer "what did dev cost last month" and "what did
  #    this project cost" directly. Without tags, an account is one undifferentiated
  #    bill and you are left guessing from resource names.
  #  - Ownership. When something odd is running at 2am, Owner tells you who to ask.
  #  - Drift detection. ManagedBy = terraform marks what is owned by code. Anything
  #    in the account WITHOUT that tag was created by hand and is a candidate for
  #    deletion or import.
  #  - Automation. Cleanup jobs can safely target Environment = dev and leave
  #    everything else alone.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      Owner       = var.owner
      ManagedBy   = "terraform"
    }
  }
}

provider "tls" {}
