##############################################################################
# Network module.
#
# Builds the private network the cluster runs inside. The shape is deliberately
# boring and standard: public subnets that hold only the NAT gateway and future
# load balancers, private subnets that hold every worker node, and one way
# outbound egress via NAT so no node is ever directly reachable from the
# internet.
##############################################################################

# Discovers usable availability zones for the current region rather than
# hardcoding names, because AZ names are per account and eu-west-2a in one
# account is not the same physical zone as eu-west-2a in another.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /16 split into /20s. Public subnets take the first az_count blocks, private
  # subnets take the next az_count. With the default 10.0.0.0/16 and 2 AZs:
  #   public  10.0.0.0/20,  10.0.16.0/20
  #   private 10.0.32.0/20, 10.0.48.0/20
  # Each /20 gives 4091 usable addresses, which matters because the AWS VPC CNI
  # assigns a real VPC IP to every single pod. Undersized subnets are the most
  # common cause of "pods stuck in ContainerCreating" on EKS.
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + var.az_count)]
}

# The network boundary for the whole environment. DNS hostnames and DNS support
# are both mandatory for EKS: the kubelet resolves the API server endpoint and
# the VPC CNI resolves EC2 metadata through VPC provided DNS.
resource "aws_vpc" "this" {
  #checkov:skip=CKV2_AWS_11:VPC flow logs are optional and controlled by var.enable_flow_logs. They are off in dev because CloudWatch ingestion is billed per GB and this is a portfolio project.
  #checkov:skip=CKV2_AWS_12:The default security group is explicitly locked down below by aws_default_security_group.
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# AWS creates a default security group in every VPC that allows all traffic
# between its own members. It cannot be deleted, so it is claimed and emptied
# instead. Anything that accidentally lands in it then has no connectivity.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  # No ingress and no egress rules declared means both are removed.

  tags = {
    Name = "${var.name_prefix}-default-do-not-use"
  }
}

# The VPC's front door to the public internet. Only the public route table
# references it, so only public subnets can reach or be reached through it.
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

##############################################################################
# Subnets
##############################################################################

# Public subnets. These hold the NAT gateway and, from a later chapter, any
# internet facing load balancer. No workload pods run here.
resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  # Off deliberately. Nothing in this subnet should get a public IP just for
  # existing. The NAT gateway gets an explicitly allocated Elastic IP instead,
  # and load balancers manage their own addressing.
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"

    # The AWS Load Balancer Controller discovers where to place an internet
    # facing load balancer by looking for this tag. Without it, a Service of
    # type LoadBalancer hangs in <pending> with no useful event message.
    "kubernetes.io/role/elb" = "1"
  }
}

# Private subnets. Every worker node and therefore every pod lives here. There is
# no route from the internet gateway to these subnets, so inbound connections
# from the public internet are impossible by routing, not by firewall rule.
resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${var.name_prefix}-private-${local.azs[count.index]}"
    Tier = "private"

    # Same discovery mechanism as above, for internal load balancers.
    "kubernetes.io/role/internal-elb" = "1"
  }
}

##############################################################################
# Egress: Elastic IPs and NAT gateways
#
# nat_gateway_count is the single largest cost lever in this module.
#   1 = one shared NAT gateway. Cheapest. If its AZ fails, both AZs lose egress.
#   2 = one per AZ. Textbook HA, doubles the hourly cost, removes cross AZ
#       data transfer charges for egress traffic.
# This is a deliberate cost decision, not a limitation. See docs/architecture.md.
##############################################################################

# A stable public IP for each NAT gateway. Allocated separately so it survives
# NAT gateway replacement, which matters if anything downstream ever allowlists it.
resource "aws_eip" "nat" {
  count = var.nat_gateway_count

  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-nat-eip-${count.index + 1}"
  }

  # The EIP is useless until the IGW exists, and destroying them in the wrong
  # order leaves a dangling association.
  depends_on = [aws_internet_gateway.this]
}

# One way outbound egress for private subnets. Nodes use it to pull container
# images, reach the EKS API and call AWS service endpoints. Traffic can only be
# initiated from inside; the internet cannot open a connection back through it.
resource "aws_nat_gateway" "this" {
  count = var.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.name_prefix}-nat-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.this]
}

##############################################################################
# Routing
##############################################################################

# One shared route table for all public subnets. Its default route points at the
# internet gateway, which is what makes these subnets "public".
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One private route table PER AZ, even when there is only one NAT gateway. This
# costs nothing and means moving to one NAT per AZ later is purely a variable
# change rather than a routing refactor.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-private-rt-${local.azs[count.index]}"
  }
}

# Default route for private subnets, pointing at a NAT gateway. The min() means
# that when nat_gateway_count is 1 every AZ shares NAT index 0, and when it is 2
# each AZ uses its own local NAT.
resource "aws_route" "private_nat" {
  count = var.az_count

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[min(count.index, var.nat_gateway_count - 1)].id
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

##############################################################################
# VPC endpoints (optional)
#
# The S3 and ECR endpoints pay for themselves the moment image pulls get busy:
# without them every image layer pulled from ECR is billed as NAT data
# processing at roughly $0.045/GB. The gateway endpoint for S3 is free; the
# interface endpoints for ECR are $0.01/hour each per AZ, so they are off by
# default and worth enabling once real workloads exist.
##############################################################################

# Free. Routes S3 traffic (which includes ECR image layer downloads) straight out
# of the VPC instead of through the NAT gateway. There is no reason not to have
# this on.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "${var.name_prefix}-s3-endpoint"
  }
}

##############################################################################
# Flow logs (optional)
#
# Records accepted and rejected connections at the VPC level. Genuinely useful
# for a security themed project, but CloudWatch Logs bills per GB ingested and a
# busy cluster generates a lot, so this is opt in.
##############################################################################

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  #checkov:skip=CKV_AWS_158:KMS encryption of log groups adds a chargeable key. CloudWatch encrypts at rest with an AWS owned key by default, which is proportionate here.
  #checkov:skip=CKV_AWS_338:Flow logs are the highest volume stream in the VPC and CloudWatch bills per GB ingested. Retention is a variable. The production answer is to deliver flow logs to S3 with lifecycle tiering rather than hold twelve months at CloudWatch rates.
  name              = "/aws/vpc/${var.name_prefix}/flow-logs"
  retention_in_days = var.flow_log_retention_days
}

# Identity CloudWatch assumes to write flow log records on the VPC's behalf.
resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.name_prefix}-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json
}

data "aws_iam_policy_document" "flow_logs_assume" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

# Scoped to this one log group rather than a wildcard, so the role cannot write
# into any other log group in the account.
data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "${var.name_prefix}-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn         = aws_iam_role.flow_logs[0].arn

  tags = {
    Name = "${var.name_prefix}-flow-logs"
  }
}
