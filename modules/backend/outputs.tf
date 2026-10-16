output "api_id" {
  description = "ID da API HTTP do backend."
  value       = aws_apigatewayv2_api.this.id
}

output "api_url" {
  description = "URL base da API do backend."
  value       = aws_apigatewayv2_api.this.api_endpoint
}

output "authorizer_id" {
  description = "ID do autorizador JWT (Cognito)."
  value       = aws_apigatewayv2_authorizer.cognito.id
}

output "ssm_prefix" {
  description = "Prefixo dos parâmetros do SSM lidos pelo deploy do backend."
  value       = local.ssm_prefix
}

output "log_group_name" {
  description = "Log de acesso da API (vazio quando desligado)."
  value       = var.enable_access_logs ? aws_cloudwatch_log_group.api[0].name : ""
}
