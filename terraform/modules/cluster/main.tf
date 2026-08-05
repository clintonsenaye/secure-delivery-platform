##############################################################################
# Cluster module.
#
# An EKS control plane, one managed node group in private subnets, the core
# addons, and the IAM OIDC provider that makes IAM Roles for Service Accounts
# (IRSA) possible.
#
# The OIDC provider is the keystone of this whole project. It is what lets a
# Kubernetes ServiceAccount exchange its projected token for temporary AWS
# credentials, which is why nothing in later chapters needs an access key.
##############################################################################

data "aws_partition" "current" {}

locals {
  # Built from the partition rather than hardcoded "aws", so the module still
  # works in GovCloud or China partitions.
  policy_arn_prefix = "arn:${data.aws_partition.current.partition}:iam::aws:policy"
}

##############################################################################
# Control plane IAM
##############################################################################

# The identity EKS itself assumes to manage network interfaces, security groups
# and load balancers inside your account on your behalf.
resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json
}

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

# The single AWS managed policy the EKS control plane requires. Attaching the
# AWS managed policy rather than hand rolling one is correct here: AWS updates it
# when the service gains new capabilities.
resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "${local.policy_arn_prefix}/AmazonEKSClusterPolicy"
}

##############################################################################
# Control plane logging
##############################################################################

# Created explicitly and BEFORE the cluster. If EKS creates this log group
# itself, it is unmanaged, has infinite retention and quietly accrues cost
# forever. Owning it in Terraform means retention is enforced in code.
resource "aws_cloudwatch_log_group" "cluster" {
  #checkov:skip=CKV_AWS_158:KMS encrypting this log group needs a chargeable customer managed key. CloudWatch already encrypts at rest with an AWS owned key.
  #checkov:skip=CKV_AWS_338:One year of retention is a compliance requirement this project does not have, and audit logs are the highest volume stream EKS produces. Retention is a variable (7 days dev, 30 prod). The production answer is to ship these to S3 or a SIEM with lifecycle tiering, not to pay CloudWatch rates for twelve months.
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days
}

##############################################################################
# The cluster
##############################################################################

resource "aws_eks_cluster" "this" {
  #checkov:skip=CKV_AWS_39:The public endpoint stays enabled so kubectl works from a laptop without a bastion. It is locked to var.public_access_cidrs, which is a required variable with no default. See docs/architecture.md.
  #checkov:skip=CKV_AWS_38:Checkov cannot resolve var.public_access_cidrs at scan time and assumes the worst case. The variable has a validation rule that hard rejects 0.0.0.0/0, so an open endpoint is impossible to configure in this repository. See modules/cluster/variables.tf.
  #checkov:skip=CKV_AWS_37:api, audit and authenticator are enabled. controllerManager and scheduler are operational debugging streams rather than security ones, and they are the noisiest. enabled_cluster_log_types is a variable, so a compliance regime that requires all five is a value change.
  #checkov:skip=CKV_AWS_58:Envelope encryption of Secrets is supported via var.kms_key_arn but is off by default, because a customer managed key costs about $1/month and this project has no Secrets worth protecting yet. Chapter 3 turns it on. The dynamic encryption_config block below is the implementation.
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    # Control plane elastic network interfaces are placed in the PRIVATE subnets.
    # This is what gives nodes a private path to the API server.
    subnet_ids = var.private_subnet_ids

    # On, so in cluster traffic to the API server never leaves the VPC.
    endpoint_private_access = true

    # On, but locked down. This is the honest trade-off for a laptop driven
    # portfolio project. The production answer is either endpoint_public_access
    # = false with a bastion or VPN into the VPC, or a tightly held allowlist.
    endpoint_public_access = true
    public_access_cidrs    = var.public_access_cidrs
  }

  access_config {
    # "API" is the modern replacement for hand editing the aws-auth ConfigMap.
    # Cluster access is now declared as real AWS resources (access entries), so it
    # is reviewable, auditable and manageable in Terraform.
    authentication_mode = "API"

    # Grants cluster admin to whichever principal ran terraform apply. Left on so
    # you cannot lock yourself out on first apply. Set to false and populate
    # var.cluster_admin_principal_arns once a stable admin role exists.
    bootstrap_cluster_creator_admin_permissions = var.bootstrap_creator_admin
  }

  # Audit is the one that matters for this project's theme: it records every API
  # call made against the cluster, including who made it. api and authenticator
  # cover control plane behaviour and IAM to Kubernetes identity mapping.
  enabled_cluster_log_types = var.enabled_cluster_log_types

  # Envelope encryption of Kubernetes Secrets with a customer managed KMS key.
  # Off by default because the key costs about $1/month; on, it means a stolen
  # etcd snapshot is not enough to read Secrets.
  dynamic "encryption_config" {
    for_each = var.kms_key_arn == null ? [] : [1]

    content {
      provider {
        key_arn = var.kms_key_arn
      }
      resources = ["secrets"]
    }
  }

  tags = {
    Name = var.cluster_name
  }

  # Without these, Terraform may create the cluster before its IAM permissions
  # exist, and may delete the log group before the cluster stops writing to it.
  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

##############################################################################
# IRSA: the IAM OIDC provider
#
# EKS publishes an OpenID Connect discovery document for every cluster.
# Registering it as an IAM identity provider tells AWS "trust tokens signed by
# this cluster". After that, an IAM role can have a trust policy naming a
# specific Kubernetes namespace and ServiceAccount, and any pod using that
# ServiceAccount receives short lived AWS credentials automatically.
#
# No access key is ever created, stored or rotated. That is the whole point.
##############################################################################

# Reads the TLS certificate presented by the OIDC issuer endpoint so its
# fingerprint can be pinned below.
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer

  # sts.amazonaws.com is the audience the EKS pod identity webhook puts in the
  # projected ServiceAccount token. It must match or the exchange is rejected.
  client_id_list = ["sts.amazonaws.com"]

  # Pins the certificate chain of the issuer endpoint.
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = {
    Name = "${var.cluster_name}-oidc"
  }
}

##############################################################################
# Node group IAM
##############################################################################

# The identity every worker EC2 instance assumes. Everything a node is allowed to
# do in AWS flows from the three policies attached below.
resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Lets the kubelet register the node with the cluster and describe EC2 resources.
resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "${local.policy_arn_prefix}/AmazonEKSWorkerNodePolicy"
}

# Lets the VPC CNI attach network interfaces and hand out VPC IP addresses to
# pods. Without it, pods never get an IP.
resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "${local.policy_arn_prefix}/AmazonEKS_CNI_Policy"
}

# Lets nodes pull images from ECR with no credentials at all. This is why the
# Deployments in later chapters have no imagePullSecrets.
resource "aws_iam_role_policy_attachment" "node_ecr" {
  role       = aws_iam_role.node.name
  policy_arn = "${local.policy_arn_prefix}/AmazonEC2ContainerRegistryReadOnly"
}

# Allows Systems Manager Session Manager onto nodes for debugging, with no SSH
# port, no key pair and no bastion. Off by default; when on, every session is
# logged in CloudTrail, which is a far better audit story than SSH.
resource "aws_iam_role_policy_attachment" "node_ssm" {
  count = var.enable_ssm_access ? 1 : 0

  role       = aws_iam_role.node.name
  policy_arn = "${local.policy_arn_prefix}/AmazonSSMManagedInstanceCore"
}

##############################################################################
# Managed node group
##############################################################################

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-ng"
  node_role_arn   = aws_iam_role.node.arn

  # Private subnets only. Nodes have no public IP and are not routable from the
  # internet.
  subnet_ids = var.private_subnet_ids

  instance_types = var.node_instance_types

  # SPOT is roughly 65 to 70 per cent cheaper than ON_DEMAND. Instances can be
  # reclaimed with two minutes' notice, which is an acceptable trade in dev and a
  # realistic engineering choice rather than a shortcut.
  capacity_type = var.node_capacity_type

  # AL2023 is the current EKS AMI family. Amazon Linux 2 is end of life and is
  # not supported on recent Kubernetes versions.
  ami_type = var.node_ami_type

  disk_size = var.node_disk_size

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    # During a rolling node replacement, take at most this many nodes down at
    # once. Set to 1 so a small cluster is never fully drained mid upgrade.
    max_unavailable = 1
  }

  labels = var.node_labels

  tags = {
    Name = "${var.cluster_name}-ng"
  }

  lifecycle {
    # The cluster autoscaler or Karpenter will own desired_size later. Ignoring it
    # here stops Terraform fighting the autoscaler on every plan.
    ignore_changes = [scaling_config[0].desired_size]
  }

  # IAM permissions must exist before instances try to register, otherwise the
  # node group creation times out after about fifteen minutes.
  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr,
  ]
}

##############################################################################
# Core addons
#
# EKS installs these automatically if you do nothing, but then their versions are
# invisible and unmanaged. Declaring them as addons puts the version in code and
# makes upgrades a reviewable diff.
##############################################################################

# Assigns real VPC IP addresses to pods. Installed first because nothing else
# gets networking until it is running.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"

  # OVERWRITE means the addon takes ownership of any pre-existing self managed
  # install, which is what you want when adopting the EKS defaults.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  # addon_version intentionally unset: AWS selects the default version compatible
  # with var.cluster_version. Pin it once you have an upgrade process.
}

# Keeps kube-proxy in step with the control plane version.
resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"
}

# In cluster DNS. It runs as pods, so unlike the two above it cannot start until
# there is a node to schedule it on. Hence the explicit dependency.
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.this]
}

##############################################################################
# Cluster access entries
#
# Extra IAM principals granted admin on the cluster, declared as real AWS
# resources rather than as rows in a ConfigMap.
##############################################################################

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
