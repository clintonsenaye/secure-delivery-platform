##############################################################################
# prod environment. PLAN ONLY.
#
# ============================ READ THIS FIRST ==============================
# This environment is never applied. It exists to be planned.
#
# `make apply ENV=prod` and `make destroy ENV=prod` both refuse to run. That is
# enforced in the Makefile, not left to discipline.
#
# Why keep it at all if it is never applied:
#
#  1. `terraform plan` still type checks the whole configuration, resolves every
#     module input and output, and catches genuine errors. A plan against a real
#     AWS account will surface a bad AMI type, an invalid instance family or a
#     malformed policy document long before an apply would.
#
#  2. It proves the modules are actually reusable. If dev and prod differ only in
#     values, the abstraction holds. If prod needed different code, it would not.
#
#  3. It is the honest way to demonstrate production sizing without paying about
#     $185/month to keep an idle cluster alive.
#
# In chapter 3 a CI check runs `terraform plan` against this environment on every
# pull request, so a change that would break prod fails review even though prod
# is never built. That is the real value: prod becomes a continuously verified
# specification rather than dead code.
# ===========================================================================
#
# Note the differences from dev are values only, never structure:
#   - a separate VPC CIDR, so the two could be peered later without renumbering
#   - on demand rather than spot, because reclaimed nodes are not acceptable
#   - larger instances, more of them, larger disks
#   - longer log retention
#   - VPC flow logs on
#   - ECR force_delete off, so nothing can casually destroy released images
##############################################################################

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region
  vpc_cidr    = var.vpc_cidr
  az_count    = 2

  # Still 1 by default, and still a deliberate decision rather than an oversight.
  # A production system carrying real traffic should set this to 2: it removes the
  # single point of failure for egress and avoids cross AZ data transfer charges,
  # at about $36/month more. Because this environment is plan only, the honest
  # default is the cheap one, with the lever exposed and documented.
  nat_gateway_count = var.nat_gateway_count

  # On in prod. Flow logs are the record of what actually talked to what, and in
  # a real production environment that record is worth its ingestion cost.
  enable_flow_logs        = true
  flow_log_retention_days = 30
}

module "cluster" {
  source = "../../modules/cluster"

  cluster_name       = local.name_prefix
  cluster_version    = var.cluster_version
  private_subnet_ids = module.network.private_subnet_ids

  # Even in a plan only environment this must be supplied explicitly. There is no
  # configuration in this repository where an open Kubernetes API is possible.
  public_access_cidrs = var.public_access_cidrs

  log_retention_days = 30

  # Production sizing: on demand, so nodes are not reclaimed mid request.
  node_instance_types = ["t3.medium"]
  node_capacity_type  = "ON_DEMAND"
  node_disk_size      = 30
  node_min_size       = 2
  node_desired_size   = 2
  node_max_size       = 4

  node_labels = {
    environment = var.environment
  }

  enable_ssm_access = true
}

module "registry" {
  source = "../../modules/registry"

  repository_name      = "${local.name_prefix}/app"
  image_tag_mutability = "IMMUTABLE"
  scan_on_push         = true
  untagged_expiry_days = 14

  # Keep more history in prod. Released images are evidence, and rolling back to a
  # six month old tag should still be possible.
  max_tagged_images = 100

  # OFF in prod. A terraform destroy must not be able to silently delete released
  # images; removing them has to be a conscious, separate act.
  force_delete = false
}
