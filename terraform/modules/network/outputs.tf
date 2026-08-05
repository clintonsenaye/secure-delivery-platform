output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC, for writing security group rules downstream."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, one per AZ. Load balancers only."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, one per AZ. This is where the EKS node group runs."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "AZ names actually used, resolved from the region at plan time."
  value       = local.azs
}

output "nat_gateway_public_ips" {
  description = "Public IPs all egress traffic leaves from. Useful if a third party needs to allowlist this environment."
  value       = aws_eip.nat[*].public_ip
}
