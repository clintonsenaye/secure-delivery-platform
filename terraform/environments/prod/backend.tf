terraform {
  # Same partial backend pattern as dev, different key. Both environments share
  # one bucket and are separated by object key prefix, not by bucket.
  backend "s3" {
    key          = "env/prod/terraform.tfstate"
    use_lockfile = true
    encrypt      = true
  }
}
