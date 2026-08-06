variable "repository_name" {
  description = "ECR repository name, for example secure-delivery-dev/app."
  type        = string
}

variable "image_tag_mutability" {
  description = <<-EOT
    IMMUTABLE stops a tag ever being repointed at different bytes. Do not set
    this to MUTABLE without a very good reason.

    IMMUTABLE_WITH_EXCLUSION keeps immutability for everything except tags
    matching image_tag_mutability_exclusion_filters. Chapter 3 needs it, because
    cosign stores signatures and attestations AS TAGS. See that variable.
  EOT
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["IMMUTABLE", "MUTABLE", "IMMUTABLE_WITH_EXCLUSION", "MUTABLE_WITH_EXCLUSION"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be IMMUTABLE, MUTABLE, IMMUTABLE_WITH_EXCLUSION or MUTABLE_WITH_EXCLUSION."
  }

  validation {
    condition     = var.image_tag_mutability != "IMMUTABLE_WITH_EXCLUSION" || length(var.image_tag_mutability_exclusion_filters) > 0
    error_message = "IMMUTABLE_WITH_EXCLUSION with no exclusion filters is just IMMUTABLE written the long way. Set image_tag_mutability_exclusion_filters, or use IMMUTABLE."
  }
}

variable "image_tag_mutability_exclusion_filters" {
  description = <<-EOT
    Wildcard patterns exempted from the mutability setting. ECR permits at most
    five.

    WHY THIS EXISTS, because it looks like a hole in chapter 1's central claim.

    Cosign does not store a signature as a separate kind of object. It pushes it
    to the SAME repository under a derived tag: an image with digest
    sha256:abc... gets its signature at the tag `sha256-abc....sig` and its
    attestations at `sha256-abc....att`. Attaching a second attestation, for
    example the SBOM after the provenance, means UPDATING that existing tag. On a
    fully IMMUTABLE repository that push is refused and signing fails.

    The tempting fix is to make the repository MUTABLE, which throws away the one
    guarantee chapter 1 said was load bearing. This is the narrow fix instead:
    application tags stay immutable, and only the `sha256-*` namespace is
    writable.

    That is safe for a specific reason rather than as a convenience. A cosign
    metadata tag is DERIVED FROM the digest of the thing it describes, so it is
    already content addressed. Overwriting `sha256-abc....sig` can only ever
    change the signature attached to that one digest, and it cannot make a
    signature apply to different bytes, which is the attack immutable tags exist
    to prevent. An attacker who can write to this namespace can add or replace a
    signature; they cannot make Kyverno accept it, because the policy pins the
    signing identity.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.image_tag_mutability_exclusion_filters) <= 5
    error_message = "ECR permits at most five exclusion filters."
  }
}

variable "scan_on_push" {
  description = "Run a free basic CVE scan on every pushed image."
  type        = bool
  default     = true
}

variable "encryption_type" {
  description = "AES256 (free) or KMS (customer managed key, about $1/month plus per request charges)."
  type        = string
  default     = "AES256"

  validation {
    condition     = contains(["AES256", "KMS"], var.encryption_type)
    error_message = "encryption_type must be AES256 or KMS."
  }
}

variable "kms_key_arn" {
  description = "KMS key ARN. Only used when encryption_type is KMS."
  type        = string
  default     = null
}

variable "untagged_expiry_days" {
  description = "Delete untagged images this many days after push. Untagged images are the debris of superseded pushes."
  type        = number
  default     = 14
}

variable "max_tagged_images" {
  description = "Cap on retained application images, matched by app_tag_prefixes. Evaluated after the untagged rule because it has a higher rule priority."
  type        = number
  default     = 30
}

variable "app_tag_prefixes" {
  description = <<-EOT
    Tag prefixes that identify application images, so the retention cap counts
    only those. The pipeline tags by commit as `sha-<short sha>`.

    Empty means "no prefix rule", and the catch-all rule handles everything.
  EOT
  type        = list(string)
  default     = ["sha-"]
}

variable "signature_tag_prefixes" {
  description = <<-EOT
    Tag prefixes holding cosign signature and attestation metadata.

    THIS EXISTS TO STOP THE LIFECYCLE POLICY DELETING YOUR SIGNATURES.

    A single "keep the last N tagged images" rule counts `sha256-....sig` and
    `sha256-....att` as images. Since every application image produces two or
    three of them, a cap of 30 is reached after roughly ten builds, and ECR then
    starts expiring the OLDEST tagged artefacts. Those are the signatures of the
    images you deployed first, which are the images most likely to still be
    running.

    The failure is quiet and delayed: nothing breaks at expiry time, because the
    pods are already admitted. It surfaces weeks later when a node is replaced or
    a pod is rescheduled, the image is re-admitted, and Kyverno reports "no
    matching signatures" for an image that was signed correctly and verified fine
    at deployment. Working out why costs an afternoon.

    Separating the two prefixes into their own rules means signature retention is
    governed independently of image retention.
  EOT
  type        = list(string)
  default     = ["sha256-"]
}

variable "max_signature_artefacts" {
  description = <<-EOT
    Cap on retained cosign metadata artefacts.

    Should comfortably exceed max_tagged_images multiplied by the number of
    metadata tags each image accumulates. This pipeline produces two per image, a
    .sig and a .att, so three times the image cap leaves headroom.
  EOT
  type        = number
  default     = 90
}

variable "force_delete" {
  description = "Allow terraform destroy to remove a repository that still contains images. Dev only."
  type        = bool
  default     = false
}

variable "pull_principal_arns" {
  description = "IAM principals granted pull only access via a repository policy. Empty means no repository policy is created."
  type        = list(string)
  default     = []
}
