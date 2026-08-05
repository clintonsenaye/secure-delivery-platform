output "state_bucket_name" {
  description = "Name of the S3 state bucket. Copy this into each environment's backend.hcl."
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the S3 state bucket, for writing least privilege IAM policies later."
  value       = aws_s3_bucket.state.arn
}

output "backend_hcl" {
  description = "Ready made backend config. Write this to terraform/environments/<env>/backend.hcl."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    region       = "${var.aws_region}"
    encrypt      = true
    use_lockfile = true
  EOT
}
