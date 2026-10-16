output "function_name" {
  description = "Nome da Lambda do simulador."
  value       = aws_lambda_function.simulador.function_name
}

output "log_group_name" {
  description = "Log group do simulador."
  value       = aws_cloudwatch_log_group.simulador.name
}
