output "vpc_id" {
  description = "VPC identifier"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet identifiers"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet identifiers"
  value       = aws_subnet.private[*].id
}