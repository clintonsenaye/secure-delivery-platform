terraform {
  # 1.12+ is required because this project relies on native S3 state locking
  # (use_lockfile), which replaced the deprecated DynamoDB lock table.
  required_version = ">= 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # DELIBERATELY NO BACKEND BLOCK.
  # This root module creates the S3 bucket that every other root module uses as its
  # backend. It cannot store its own state in a bucket that does not exist yet, so
  # it uses local state. That state file is gitignored and is never committed.
}
