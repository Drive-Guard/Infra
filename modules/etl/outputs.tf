output "etl_silver_function_name" {
  description = "Nome da Lambda ETL Silver."
  value       = aws_lambda_function.etl_silver.function_name
}

output "etl_silver_function_arn" {
  description = "ARN da Lambda ETL Silver."
  value       = aws_lambda_function.etl_silver.arn
}

output "etl_gold_function_name" {
  description = "Nome da Lambda ETL Gold."
  value       = aws_lambda_function.etl_gold.function_name
}

output "etl_gold_function_arn" {
  description = "ARN da Lambda ETL Gold."
  value       = aws_lambda_function.etl_gold.arn
}

output "db_migrate_function_name" {
  description = "Nome da Lambda de migração."
  value       = aws_lambda_function.db_migrate.function_name
}

output "dlq_url" {
  description = "URL da fila DLQ do ETL."
  value       = aws_sqs_queue.dlq.url
}

output "dlq_arn" {
  description = "ARN da fila DLQ do ETL."
  value       = aws_sqs_queue.dlq.arn
}

output "dlq_name" {
  description = "Nome da fila DLQ do ETL (dimensao das metricas do CloudWatch)."
  value       = aws_sqs_queue.dlq.name
}

output "gold_schedule_rule" {
  description = "Nome da regra do EventBridge que agenda o refresh Gold."
  value       = aws_cloudwatch_event_rule.etl_gold.name
}

output "log_group_names" {
  description = "Log groups das Lambdas de ETL."
  value = [
    aws_cloudwatch_log_group.etl_silver.name,
    aws_cloudwatch_log_group.etl_gold.name,
    aws_cloudwatch_log_group.db_migrate.name,
  ]
}

output "migration_result" {
  description = "Resposta da invocação da Lambda de migração."
  value       = var.run_migrations ? try(aws_lambda_invocation.migrate[0].result, null) : null
}
