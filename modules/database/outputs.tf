output "instance_id" {
  description = "Identificador da instância RDS."
  value       = aws_db_instance.this.id
}

output "instance_arn" {
  description = "ARN da instância RDS."
  value       = aws_db_instance.this.arn
}

output "address" {
  description = "Hostname do RDS."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Porta do RDS."
  value       = aws_db_instance.this.port
}

output "endpoint" {
  description = "Endpoint host:porta do RDS."
  value       = aws_db_instance.this.endpoint
}

output "db_name" {
  description = "Nome do banco."
  value       = aws_db_instance.this.db_name
}

output "username" {
  description = "Usuário master."
  value       = aws_db_instance.this.username
}

output "password" {
  description = "Senha master gerada."
  value       = random_password.db.result
  sensitive   = true
}

output "connection_uri" {
  description = "URI de conexão PostgreSQL completa."
  value       = aws_ssm_parameter.db_uri.value
  sensitive   = true
}

output "ssm_password_parameter" {
  description = "Caminho no SSM Parameter Store com a senha."
  value       = aws_ssm_parameter.db_password.name
}

output "ssm_uri_parameter" {
  description = "Caminho no SSM Parameter Store com a URI de conexão."
  value       = aws_ssm_parameter.db_uri.name
}
