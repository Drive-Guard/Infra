output "user_pool_id" {
  description = "ID do user pool do Cognito."
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  description = "ARN do user pool."
  value       = aws_cognito_user_pool.this.arn
}

output "user_pool_endpoint" {
  description = "Endpoint do user pool (sem https://)."
  value       = aws_cognito_user_pool.this.endpoint
}

output "client_id" {
  description = "ID do app client da dashboard."
  value       = aws_cognito_user_pool_client.dashboard.id
}

output "issuer" {
  description = "Issuer dos tokens, usado pelo autorizador JWT da API."
  value       = "https://${aws_cognito_user_pool.this.endpoint}"
}

output "usuarios_demo" {
  description = "Login e senha dos usuários de demonstração."
  sensitive   = true
  value = {
    for k, u in aws_cognito_user.demo : k => {
      email = u.username
      senha = random_password.demo[k].result
      papel = var.usuarios_demo[k].papel
    }
  }
}
