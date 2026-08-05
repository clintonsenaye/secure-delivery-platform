##############################################################################
# dev environment.
#
# This is a thin root module. It contains no resources of its own, only three
# module calls and the values that make dev cheap. prod is the same file with
# different numbers, which is the point: identical shape, different sizing.
#
# Cost when running: roughly $0.18/hour, about $4.30/day. See README.md.
# Run `make destroy ENV=dev` when you are finished for the day.
##############################################################################

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# The VPC, subnets, routing and egress.
module "network" {
  source = "../../modules/network"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region
  vpc_cidr    = var.vpc_cidr
  az_count    = 2

  # One shared NAT gateway. A deliberate cost decision, saving about $36/month
  # against one per AZ. The trade is that a single AZ failure removes egress for
  # the whole environment. For a dev environment that is the right call. Change
  # this value to 2 to get one per AZ; no other change is needed.
  nat_gateway_count = var.nat_gateway_count

  # Off in dev. CloudWatch bills per GB ingested and a chatty cluster produces a
  # lot of flow log records.
  enable_flow_logs = false
}

# The EKS control plane, node group and the OIDC provider that IRSA depends on.
module "cluster" {
  source = "../../modules/cluster"

  cluster_name       = local.name_prefix
  cluster_version    = var.cluster_version
  private_subnet_ids = module.network.private_subnet_ids

  # Required, no default. Supply your own address in terraform.tfvars.
  public_access_cidrs = var.public_access_cidrs

  log_retention_days = 7

  # Cheap dev sizing: two small spot instances.
  node_instance_types = ["t3.small", "t3a.small"] # two types improves spot availability
  node_capacity_type  = "SPOT"
  node_disk_size      = 20
  node_min_size       = 1
  node_desired_size   = 2
  node_max_size       = 3

  node_labels = {
    environment = var.environment
  }

  enable_ssm_access = true
}

# The ECR repository that signed images will live in from chapter 3 onwards.
module "registry" {
  source = "../../modules/registry"

  repository_name = "${local.name_prefix}/app"

  # Tags cannot be repointed. See the module for why this matters so much here.
  image_tag_mutability = "IMMUTABLE"
  scan_on_push         = true
  untagged_expiry_days = 14
  max_tagged_images    = 30

  # Dev only. Lets `terraform destroy` remove the repository even when it still
  # holds images, so tearing the environment down does not need a manual step.
  force_delete = true
}
