output "sns_topic_arn" {
  description = "ARN do topico SNS de alarmes."
  value       = aws_sns_topic.alarms.arn
}

output "alarm_names" {
  description = "Nomes de todos os alarmes criados."
  value = concat(
    [for a in aws_cloudwatch_metric_alarm.lambda_errors : a.alarm_name],
    [for a in aws_cloudwatch_metric_alarm.lambda_throttles : a.alarm_name],
    [
      aws_cloudwatch_metric_alarm.gold_sem_execucao.alarm_name,
      aws_cloudwatch_metric_alarm.dlq.alarm_name,
      aws_cloudwatch_metric_alarm.rds_cpu.alarm_name,
      aws_cloudwatch_metric_alarm.rds_storage.alarm_name,
      aws_cloudwatch_metric_alarm.rds_conexoes.alarm_name,
      aws_cloudwatch_metric_alarm.api_5xx.alarm_name,
    ],
    aws_cloudwatch_metric_alarm.ec2_status[*].alarm_name,
  )
}

output "dashboard_name" {
  description = "Nome do dashboard do CloudWatch."
  value       = try(aws_cloudwatch_dashboard.this[0].dashboard_name, null)
}
