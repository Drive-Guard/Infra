output "api_id" {
  description = "ID da REST API."
  value       = aws_api_gateway_rest_api.this.id
}

output "api_name" {
  description = "Nome da REST API."
  value       = aws_api_gateway_rest_api.this.name
}

output "invoke_url" {
  description = "URL base do stage."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "eventos_endpoint" {
  description = "Endpoint de ingestão de eventos."
  value       = "${aws_api_gateway_stage.this.invoke_url}/eventos"
}

output "health_endpoint" {
  description = "Endpoint de health check (sem API Key)."
  value       = "${aws_api_gateway_stage.this.invoke_url}/health"
}

output "api_key_id" {
  description = "ID da API Key dos dispositivos."
  value       = aws_api_gateway_api_key.edge.id
}

output "api_key_value" {
  description = "Valor da API Key dos dispositivos."
  value       = aws_api_gateway_api_key.edge.value
  sensitive   = true
}

output "lambda_function_name" {
  description = "Nome da Lambda de ingestão."
  value       = aws_lambda_function.ingest.function_name
}

output "lambda_function_arn" {
  description = "ARN da Lambda de ingestão."
  value       = aws_lambda_function.ingest.arn
}

output "log_group_name" {
  description = "Log group da Lambda de ingestão."
  value       = aws_cloudwatch_log_group.ingest.name
}
