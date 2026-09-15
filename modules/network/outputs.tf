output "vpc_id" {
  description = "ID da VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR da VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs das subnets públicas."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas."
  value       = aws_subnet.private[*].id
}

output "database_subnet_ids" {
  description = "Subnets usadas pelo subnet group do RDS."
  value       = var.db_publicly_accessible ? aws_subnet.public[*].id : aws_subnet.private[*].id
}

output "lambda_security_group_id" {
  description = "Security Group das Lambdas de ETL."
  value       = aws_security_group.lambda.id
}

output "dashboard_security_group_id" {
  description = "Security Group da EC2 do dashboard."
  value       = aws_security_group.dashboard.id
}

output "database_security_group_id" {
  description = "Security Group do RDS."
  value       = aws_security_group.database.id
}

output "nat_gateway_ids" {
  description = "IDs dos NAT Gateways, se habilitados."
  value       = aws_nat_gateway.this[*].id
}

output "s3_vpc_endpoint_id" {
  description = "ID do VPC Endpoint gateway do S3."
  value       = aws_vpc_endpoint.s3.id
}
