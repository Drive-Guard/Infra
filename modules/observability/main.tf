###############################################################################
# Módulo: observability
#
# SNS + alarmes do CloudWatch nos pontos onde a solução realmente quebra:
#   - Lambda de ingestão falhando  => o veículo perde telemetria
#   - ETL Silver falhando          => a Bronze acumula sem virar Silver
#   - ETL Gold falhando            => o dashboard congela nos números antigos
#   - DLQ com mensagem             => há lote perdido esperando reprocesso
#   - RDS sem CPU/storage/memória  => o gargalo do db.t3.micro
#   - EC2 com status check falhando=> dashboard fora do ar
#
# Mais um dashboard do CloudWatch que junta a cadeia inteira numa tela só.
###############################################################################

resource "aws_sns_topic" "alarms" {
  name = "${var.name_prefix}-alarmes"

  tags = {
    Name = "${var.name_prefix}-alarmes"
  }
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  acoes = [aws_sns_topic.alarms.arn]

  lambdas = {
    ingest = var.ingest_function_name
    silver = var.etl_silver_function_name
    gold   = var.etl_gold_function_name
  }
}

# ----------------------------------------------------------------------------
# Lambdas
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = local.lambdas

  alarm_name          = "${var.name_prefix}-${each.key}-erros"
  alarm_description   = "Lambda ${each.value} registrou erros na janela de 5 minutos"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = each.key == "ingest" ? 5 : 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value
  }

  alarm_actions = local.acoes
  ok_actions    = local.acoes

  tags = {
    Name = "${var.name_prefix}-${each.key}-erros"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = local.lambdas

  alarm_name          = "${var.name_prefix}-${each.key}-throttles"
  alarm_description   = "Lambda ${each.value} sendo throttled - concorrencia reservada insuficiente"
  namespace           = "AWS/Lambda"
  metric_name         = "Throttles"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value
  }

  alarm_actions = local.acoes

  tags = {
    Name = "${var.name_prefix}-${each.key}-throttles"
  }
}

# O ETL Gold roda de 5 em 5 minutos. Ficar 20 minutos sem nenhuma invocação
# significa que o EventBridge parou de disparar e o dashboard está servindo
# dados congelados sem nenhum erro aparente.
resource "aws_cloudwatch_metric_alarm" "gold_sem_execucao" {
  alarm_name          = "${var.name_prefix}-gold-sem-execucao"
  alarm_description   = "ETL Gold sem invocacoes: as views podem estar desatualizadas"
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  statistic           = "Sum"
  period              = 1200
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    FunctionName = var.etl_gold_function_name
  }

  alarm_actions = local.acoes

  tags = {
    Name = "${var.name_prefix}-gold-sem-execucao"
  }
}

# ----------------------------------------------------------------------------
# DLQ
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dlq" {
  alarm_name          = "${var.name_prefix}-dlq-com-mensagens"
  alarm_description   = "Ha lotes na DLQ do ETL aguardando reprocessamento"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = var.dlq_name
  }

  alarm_actions = local.acoes

  tags = {
    Name = "${var.name_prefix}-dlq-com-mensagens"
  }
}

# ----------------------------------------------------------------------------
# RDS
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name_prefix}-rds-cpu-alta"
  alarm_description   = "CPU do RDS acima de 80% por 10 minutos"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }

  alarm_actions = local.acoes

  tags = {
    Name = "${var.name_prefix}-rds-cpu-alta"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.name_prefix}-rds-storage-baixo"
  alarm_description   = "Menos de 2 GiB livres no RDS"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648 # 2 GiB
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }

  alarm_actions = local.acoes

  tags = {
    Name = "${var.name_prefix}-rds-storage-baixo"
  }
}

resource "aws_cloudwatch_metric_alarm" "rds_conexoes" {
  alarm_name          = "${var.name_prefix}-rds-conexoes-altas"
  alarm_description   = "Conexoes simultaneas perto do limite do db.t3.micro"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.db_max_connections_alarm
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.db_instance_id
  }

  alarm_actions = local.acoes

  tags = {
    Name = "${var.name_prefix}-rds-conexoes-altas"
  }
}

# ----------------------------------------------------------------------------
# EC2 do dashboard
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "ec2_status" {
  count = var.monitor_dashboard_instance ? 1 : 0

  alarm_name          = "${var.name_prefix}-dashboard-status-check"
  alarm_description   = "Status check da EC2 do dashboard falhando"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = var.dashboard_instance_id
  }

  alarm_actions = local.acoes

  tags = {
    Name = "${var.name_prefix}-dashboard-status-check"
  }
}

# ----------------------------------------------------------------------------
# API Gateway
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${var.name_prefix}-api-5xx"
  alarm_description   = "API de ingestao retornando erros 5XX"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5XXError"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiName = var.api_name
    Stage   = var.api_stage
  }

  alarm_actions = local.acoes

  tags = {
    Name = "${var.name_prefix}-api-5xx"
  }
}

# ----------------------------------------------------------------------------
# Dashboard do CloudWatch
# ----------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "this" {
  count = var.enable_dashboard ? 1 : 0

  dashboard_name = "${var.name_prefix}-visao-geral"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = join("\n", [
            "# DriveGuard - ${var.name_prefix}",
            "Veiculo -> API Gateway -> Lambda Ingest -> **S3 Bronze** -> Lambda ETL Silver -> **RDS silver** -> Lambda ETL Gold (5 min) -> **RDS gold** -> Dashboard",
          ])
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Ingestao - requisicoes e erros na API"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiName", var.api_name, "Stage", var.api_stage],
            [".", "4XXError", ".", ".", ".", "."],
            [".", "5XXError", ".", ".", ".", "."],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Latencia da API (p50 / p95)"
          region = var.region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/ApiGateway", "Latency", "ApiName", var.api_name, "Stage", var.api_stage, { stat = "p50" }],
            ["...", { stat = "p95" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "Lambdas - invocacoes"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", var.ingest_function_name],
            [".", ".", ".", var.etl_silver_function_name],
            [".", ".", ".", var.etl_gold_function_name],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "Lambdas - erros e throttles"
          region = var.region
          view   = "timeSeries"
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", var.ingest_function_name],
            [".", ".", ".", var.etl_silver_function_name],
            [".", ".", ".", var.etl_gold_function_name],
            [".", "Throttles", ".", var.etl_silver_function_name],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 12
        height = 6
        properties = {
          title  = "Duracao do REFRESH por MATERIALIZED VIEW"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 300
          metrics = [
            for v in var.gold_views :
            [var.metric_namespace, "RefreshDuracaoMs", "View", v]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 14
        width  = 12
        height = 6
        properties = {
          title  = "RDS - CPU, conexoes e storage livre"
          region = var.region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.db_instance_id, { stat = "Average" }],
            [".", "DatabaseConnections", ".", ".", { stat = "Maximum", yAxis = "right" }],
            [".", "FreeableMemory", ".", ".", { stat = "Average", yAxis = "right" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 20
        width  = 12
        height = 6
        properties = {
          title  = "S3 Bronze - objetos armazenados"
          region = var.region
          view   = "timeSeries"
          stat   = "Average"
          period = 86400
          metrics = [
            ["AWS/S3", "NumberOfObjects", "BucketName", var.bronze_bucket, "StorageType", "AllStorageTypes"],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 20
        width  = 12
        height = 6
        properties = {
          title  = "DLQ - lotes aguardando reprocessamento"
          region = var.region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 300
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.dlq_name],
          ]
        }
      },
    ]
  })
}
