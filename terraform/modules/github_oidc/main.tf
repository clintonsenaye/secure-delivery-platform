##############################################################################
# GitHub OIDC module.
#
# This is chapter 1's keystone argument, pointed at GitHub instead of at the
# cluster.
#
# Chapter 1 registered the EKS cluster's OpenID Connect discovery document as an
# IAM identity provider, which let a Kubernetes ServiceAccount exchange a short
# lived projected token for temporary AWS credentials, and so removed the need
# for an access key inside the cluster.
#
# This module does exactly the same thing for GitHub Actions. GitHub publishes an
# OIDC discovery document; registering it tells AWS "trust tokens signed by
# GitHub". An IAM role can then carry a trust policy naming one repository and
# one branch, and a workflow run on that branch receives temporary credentials
# automatically.
#
# What it replaces: an IAM user, a permanent access key, and that key pasted into
# GitHub Actions secrets. That secret is long lived, does not rotate on its own,
# is readable by anyone who can edit a workflow file, and is the single most
# common way cloud credentials leak out of CI. This module deletes the row from
# the credential inventory rather than protecting it better.
#
# THE ONE LINE THAT MATTERS is the `sub` condition in the trust policy below.
# Everything else here is ordinary IAM.
##############################################################################

data "aws_partition" "current" {}

locals {
  # The issuer, written once. Both the provider URL and the condition keys are
  # derived from it, so they cannot drift apart.
  oidc_issuer_host = "token.actions.githubusercontent.com"
  oidc_issuer_url  = "https://token.actions.githubusercontent.com"

  # Whether we created the provider or looked up one that already existed, this
  # is the ARN the trust policies reference.
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn

  # The repository, split once so the owner and the name can be paired with
  # their immutable IDs below.
  github_owner = split("/", var.github_repository)[0]
  github_name  = split("/", var.github_repository)[1]

  # THE SUBJECT CLAIM PREFIX, IN GITHUB'S IMMUTABLE IDENTIFIER FORM.
  #
  # Built rather than hand written, so it appears in exactly one place in this
  # module and both roles cannot drift apart.
  #
  # The shape, since GitHub changed it on 15 July 2026:
  #
  #   repo:OWNER@OWNER-ID/NAME@REPO-ID
  #
  # producing, for this project:
  #
  #   repo:clintonsenaye@57267374/secure-delivery-platform@1323617369
  #
  # The @ separator is not decoration. It was chosen because @ cannot appear in
  # a GitHub username or repository name, so the delimiter can never be confused
  # with part of a name no matter what anyone calls their repository.
  #
  # The OLD shape, which this module used until the trust policy started
  # refusing every request, was simply:
  #
  #   repo:clintonsenaye/secure-delivery-platform
  #
  # StringEquals does not match one against the other. See section 29 of
  # docs/architecture.md for the diagnosis and for why the IDs are the stronger
  # thing to match on rather than merely the newer thing.
  repo_claim = "repo:${local.github_owner}@${var.github_owner_id}/${local.github_name}@${var.github_repository_id}"

  # The two roles need differently shaped claims after that common prefix.
  #
  # A push to a branch produces:  <prefix>:ref:refs/heads/main
  # A pull request run produces:  <prefix>:pull_request
  #
  # Note that the immutable ID change altered the PREFIX only. The suffix that
  # distinguishes a branch push from a pull request run is unchanged, which is
  # why the separation between the push role and the plan role still holds
  # exactly as it did before.
  push_subjects = [for r in var.push_allowed_refs : "${local.repo_claim}:ref:${r}"]
  plan_subjects = [for s in var.plan_allowed_subjects : "${local.repo_claim}:${s}"]

  # The certificate identity Fulcio will put in the signing certificate's subject
  # alternative name for a run of the build workflow. Exported as an output so
  # the Kyverno policy and the demonstration commands can be checked against the
  # infrastructure rather than against someone's memory.
  #
  # DELIBERATELY STILL THE NAME FORM, with no IDs in it.
  #
  # This is a DIFFERENT CLAIM from the one above, and conflating the two is the
  # obvious way to turn one broken thing into two. AWS validates `sub`. Fulcio
  # builds the certificate's subject alternative name from `job_workflow_ref`,
  # which is a URL and has always been a URL. The 15 July 2026 change was to
  # `sub` only, so the Kyverno policies in policies/ were never affected by the
  # failure that broke role assumption, and rewriting them to chase it would have
  # broken image verification for no reason.
  #
  # That is reasoning rather than observation: this project has not yet produced
  # a real signature to read a certificate out of. Confirm it from the first one.
  # The build workflow's own verification step fails loudly if it is wrong, which
  # is exactly why that step exists.
  workflow_identity_prefix = "https://github.com/${var.github_repository}/.github/workflows"
}

##############################################################################
# The identity provider
##############################################################################

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url = local.oidc_issuer_url

  # The audience. GitHub mints the token with this value when the workflow asks
  # for one scoped to STS. Checking it means a token minted for some other
  # audience, for example a third party service that also accepts GitHub OIDC,
  # cannot be replayed here.
  client_id_list = ["sts.amazonaws.com"]

  # null rather than [] when unset. The argument is optional AND computed, so an
  # explicit empty list fights the value AWS fills in and produces a permanent
  # diff. See the variable's description for why the value does not matter: IAM
  # validates this issuer against a trusted root CA and ignores the list.
  thumbprint_list = length(var.oidc_thumbprints) > 0 ? var.oidc_thumbprints : null

  tags = {
    Name = "${var.name_prefix}-github-actions"
  }
}

# Used only when create_oidc_provider is false, because an AWS account may hold
# exactly one OIDC provider per issuer URL and another project may have got here
# first.
data "aws_iam_openid_connect_provider" "existing" {
  count = var.create_oidc_provider ? 0 : 1

  url = local.oidc_issuer_url
}

##############################################################################
# Role 1: the build role. Pushes images to ECR. Nothing else.
##############################################################################

data "aws_iam_policy_document" "push_assume" {
  statement {
    sid    = "GitHubActionsPushRole"
    effect = "Allow"

    # AssumeRoleWithWebIdentity, not AssumeRole. The caller presents a token
    # signed by a trusted issuer rather than an existing AWS identity, which is
    # what removes the need for a stored AWS credential to bootstrap from.
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    # THE AUDIENCE CHECK.
    #
    # Without this, a GitHub token minted for a different audience could be
    # presented here. StringEquals, so exactly one value is accepted.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # THE SUBJECT CHECK. THE LINE THIS WHOLE MODULE EXISTS FOR.
    #
    # `sub` identifies which workflow run is asking. Scoped here to this
    # repository, by immutable ID, AND this branch.
    #
    # The failure modes, in order of how bad they are:
    #
    #   omitted entirely     ANY GitHub Actions workflow in ANY repository on
    #                        GitHub can assume this role. This is not a subtle
    #                        misconfiguration, it is a public role.
    #   StringLike "repo:*"  the same thing with extra steps.
    #   StringLike "repo:owner@*"
    #                        does not help. The IDs are only worth having if
    #                        they are matched exactly; a wildcard over them
    #                        throws away the entire property they provide.
    #   StringLike "repo:owner/*"
    #                        any repository owned by you, including one created
    #                        five minutes ago by an attacker who compromised a
    #                        single collaborator account.
    #   StringEquals, names but no IDs
    #                        the old shape. Survives a rename of your repository
    #                        and, much worse, ALSO matches a completely different
    #                        repository that later takes the same name. See
    #                        docs/architecture.md section 29.
    #   StringEquals, repo only, no ref
    #                        any branch, including one pushed by someone with
    #                        write access but no review rights.
    #
    # StringEquals against a fixed list of full claims carrying immutable IDs is
    # the strongest form available. The cost is that adding a branch or a tag
    # trigger is a Terraform change, which is the correct amount of friction for
    # widening a trust boundary, and that renaming the repository is also a
    # Terraform change, which is discussed in section 29.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = local.push_subjects
    }
  }
}

resource "aws_iam_role" "push" {
  name        = "${var.name_prefix}-gha-ecr-push"
  description = "Assumed by GitHub Actions on ${var.github_repository} to push signed images to ECR. No stored access key exists."

  assume_role_policy   = data.aws_iam_policy_document.push_assume.json
  max_session_duration = var.max_session_duration

  tags = {
    Name = "${var.name_prefix}-gha-ecr-push"
  }
}

data "aws_iam_policy_document" "push" {
  # ecr:GetAuthorizationToken CANNOT be scoped to a repository, and an
  # interviewer will notice the wildcard in a project about least privilege.
  #
  # It is a registry level action: it returns a short lived docker login token
  # for the account's registry, and the API has no repository ARN to attach it
  # to. The token it returns does not itself grant anything. What that token can
  # actually do is still governed by the identity policy below and by any
  # repository policy, so the wildcard grants the ability to authenticate, not
  # the ability to push.
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Everything that actually moves bytes is scoped to named repository ARNs.
  #
  # The read actions are here as well as the write ones because cosign and the
  # provenance attestation both read the manifest back after the push, and
  # because the workflow verifies its own signature before it commits anything.
  statement {
    sid    = "EcrPushAndRead"
    effect = "Allow"

    actions = [
      # Push
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      # Read back, for cosign, syft and the self verification step
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:ListImages",
      "ecr:DescribeRepositories",
      # Referrers, used when signature metadata is stored as an OCI referrer
      # rather than as a .sig tag
      "ecr:GetRegistryPolicy",
    ]

    resources = var.ecr_repository_arns
  }
}

# No checkov suppression here, and that is worth a sentence.
#
# The first draft carried two, arguing that the wildcard on
# ecr:GetAuthorizationToken was unavoidable. Removing them changed nothing:
# Checkov does not flag it, because AWS genuinely offers no way to scope that
# action and the scanner knows it. A suppression that suppresses nothing is
# noise pretending to be diligence, and this repository's position is that a
# suppression should be an argument rather than a habit. See
# docs/architecture.md section 11.
resource "aws_iam_policy" "push" {
  name        = "${var.name_prefix}-gha-ecr-push"
  description = "Push and read access to named ECR repositories. Deliberately grants nothing else: no EKS, no S3, no IAM."
  policy      = data.aws_iam_policy_document.push.json
}

resource "aws_iam_role_policy_attachment" "push" {
  role       = aws_iam_role.push.name
  policy_arn = aws_iam_policy.push.arn
}

##############################################################################
# Role 2: the plan role. Reads. Cannot write anything, anywhere.
#
# Two roles rather than one, because the two jobs have genuinely different
# needs and genuinely different trust boundaries. The plan role is assumable
# from a pull request, which means it is assumable from a branch that has not
# been reviewed yet. Giving that role push access to the registry would let an
# unreviewed pull request publish an image.
#
# Separating them is what makes "a pull request can look but not touch" true by
# construction.
##############################################################################

data "aws_iam_policy_document" "plan_assume" {
  count = var.create_plan_role ? 1 : 0

  statement {
    sid     = "GitHubActionsPlanRole"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to this repository by immutable ID, and to pull request runs plus
    # pushes to main.
    #
    # Note the pull request claim has no ref component: a run triggered by a pull
    # request always gets `<repo-claim>:pull_request` regardless of which branch
    # the pull request came from. That includes pull requests opened from forks
    # by people with no write access at all, which is precisely why this role is
    # read only and why it is a different role from the push one.
    #
    # This role was broken by the 15 July 2026 subject claim change in exactly
    # the same way the push role was, and is fixed by the same shared
    # local.repo_claim. Fixing one and not the other would have produced a
    # pipeline that could build and push but whose pull request checks silently
    # stopped planning, which is the more dangerous half to leave broken because
    # a missing check looks like a passing one.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = local.plan_subjects
    }
  }
}

resource "aws_iam_role" "plan" {
  count = var.create_plan_role ? 1 : 0

  name        = "${var.name_prefix}-gha-terraform-plan"
  description = "Assumed by GitHub Actions on ${var.github_repository} to run `terraform plan` on pull requests. Read only."

  assume_role_policy   = data.aws_iam_policy_document.plan_assume[0].json
  max_session_duration = var.max_session_duration

  tags = {
    Name = "${var.name_prefix}-gha-terraform-plan"
  }
}

data "aws_iam_policy_document" "plan" {
  #checkov:skip=CKV_AWS_356:Describe and List actions across EC2, EKS, ECR, IAM, KMS, CloudWatch Logs and autoscaling cannot be scoped to resource ARNs. AWS models them as account level reads and rejects a policy that tries. Every action in this document is read only, none can retrieve a secret value, and the only genuinely scopable resources here (the state bucket) ARE scoped, in the two statements below.
  count = var.create_plan_role ? 1 : 0

  # Read only across the services this project's Terraform touches.
  #
  # The AWS managed ReadOnlyAccess policy is the usual shortcut here and it is
  # rejected on purpose: it grants read on every service in the account,
  # including s3:GetObject on every bucket. A plan role that can read every
  # object in the account is a data exfiltration path wearing the costume of a
  # linting job.
  #
  # This is the explicit list instead. It is longer, and it is bounded by the
  # services that actually appear in terraform/.
  statement {
    sid    = "DescribeInfrastructure"
    effect = "Allow"

    # NOTE THE ABSENCE OF ec2:Get*.
    #
    # It was there in the first draft and Checkov caught it: `ec2:Get*` expands
    # to include `ec2:GetPasswordData`, which returns the encrypted
    # administrator password of a Windows instance. That is a credentials
    # exposure path, granted to a role that anyone opening a pull request can
    # assume, in a policy whose entire purpose is to be read only.
    #
    # It was not needed. Terraform reads EC2 state through Describe calls. The
    # finding is recorded here rather than suppressed, because "the scanner
    # found a real problem in our own least privilege policy" is a more useful
    # thing to be able to say than a clean first draft.
    actions = [
      "autoscaling:Describe*",
      "ec2:Describe*",
      "ecr:Describe*",
      "ecr:List*",
      "ecr:GetLifecyclePolicy",
      "ecr:GetRepositoryPolicy",
      "eks:Describe*",
      "eks:List*",
      "elasticloadbalancing:Describe*",
      "kms:Describe*",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:List*",
      "logs:Describe*",
      "logs:ListTagsForResource",
      "tag:GetResources",
    ]

    resources = ["*"]
  }

  # IAM read is unavoidable: the cluster module reads back the roles, policies
  # and the OIDC provider it manages, and a plan that cannot refresh those
  # produces a diff full of phantom changes.
  #
  # This is read only and cannot retrieve a secret. It does disclose the
  # account's IAM layout to anyone who can open a pull request, which is a real
  # if small trade and is recorded here rather than left implicit.
  statement {
    sid    = "ReadIamForRefresh"
    effect = "Allow"

    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetOpenIDConnectProvider",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListPolicyVersions",
      "iam:ListOpenIDConnectProviders",
      "iam:ListInstanceProfilesForRole",
    ]

    resources = ["*"]
  }

  # Read the state file. Note there is no PutObject and no DeleteObject.
  #
  # That is why the plan workflow runs `terraform plan -lock=false`. Acquiring
  # the S3 native lock means WRITING a .tflock object, and a genuinely read only
  # role cannot do that. Running without the lock is safe here because a plan
  # does not mutate state; the risk it forgoes is reading a state file that is
  # being written at that exact moment, which produces a confusing plan rather
  # than a corrupted one.
  dynamic "statement" {
    for_each = var.state_bucket_arn == null ? [] : [1]

    content {
      sid       = "ReadTerraformState"
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:GetObjectVersion"]
      resources = [for p in var.state_key_prefixes : "${var.state_bucket_arn}/${p}*"]
    }
  }

  dynamic "statement" {
    for_each = var.state_bucket_arn == null ? [] : [1]

    content {
      sid       = "ListTerraformStateBucket"
      effect    = "Allow"
      actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
      resources = [var.state_bucket_arn]
    }
  }
}

resource "aws_iam_policy" "plan" {
  #checkov:skip=CKV_AWS_355:Describe, List and Get actions cannot be scoped to resource ARNs for most of these services; AWS models them as account level reads. Every action in this policy is read only and none can retrieve a secret value.
  count = var.create_plan_role ? 1 : 0

  name        = "${var.name_prefix}-gha-terraform-plan"
  description = "Read only access sufficient for `terraform plan`. No write action of any kind, including no ability to acquire the state lock."
  policy      = data.aws_iam_policy_document.plan[0].json
}

resource "aws_iam_role_policy_attachment" "plan" {
  count = var.create_plan_role ? 1 : 0

  role       = aws_iam_role.plan[0].name
  policy_arn = aws_iam_policy.plan[0].arn
}
