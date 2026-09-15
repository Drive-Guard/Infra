###############################################################################
# Módulo: etl
#
#   S3 Bronze --(ObjectCreated)--> Lambda ETL Silver --> RDS (schema silver)
#   EventBridge (5 min)          -> Lambda ETL Gold   --> REFRESH das MVs gold
#   terraform apply              -> Lambda db_migrate --> aplica o DDL
#
# As três rodam em subnet privada porque precisam alcançar o RDS. Sem NAT
# Gateway, elas chegam ao S3 pelo endpoint gateway e ao CloudWatch Logs pelo
# endpoint de interface criados no módulo network.
#
# A senha do banco chega por variável de ambiente (criptografada em repouso
# pela chave gerenciada da AWS para Lambda). Em produção o correto seria
# Secrets Manager com rotação; aqui isso custaria um endpoint de interface a
# mais e US$0,40/mês por segredo, fora do orçamento do Learner Lab.
###############################################################################

locals {
  fn_silver  = "${var.name_prefix}-etl-silver"
  fn_gold    = "${var.name_prefix}-etl-gold"
  fn_migrate = "${var.name_prefix}-db-migrate"

  db_env = {
    DB_HOST     = var.db_host
    DB_PORT     = tostring(var.db_port)
    DB_NAME     = var.db_name
    DB_USER     = var.db_username
    DB_PASSWORD = var.db_password
    LOG_LEVEL   = var.log_level
  }

  vpc_subnets = var.private_subnet_ids
  vpc_sgs     = [var.lambda_security_group_id]
}

# ----------------------------------------------------------------------------
# Dead Letter Queue — eventos que falharam depois de todas as tentativas
# ----------------------------------------------------------------------------

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-etl-dlq"
  message_retention_seconds = 1209600 # 14 dias
  sqs_managed_sse_enabled   = true

  tags = {
    Name = "${var.name_prefix}-etl-dlq"
  }
}

# ----------------------------------------------------------------------------
# Lambda ETL Silver
# ----------------------------------------------------------------------------

data "archive_file" "etl_silver" {
  type        = "zip"
  source_dir  = "${var.build_dir}/etl_silver"
  output_path = "${var.build_dir}/_zips/etl_silver.zip"
}

resource "aws_cloudwatch_log_group" "etl_silver" {
  name              = "/aws/lambda/${local.fn_silver}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "etl_silver" {
  function_name = local.fn_silver
  description   = "Le o JSON cru do Bronze, normaliza e carrega no schema silver do RDS"
  role          = var.lambda_role_arn
  handler       = "handler.handler"
  runtime       = var.lambda_runtime
  architectures = ["x86_64"]

  filename         = data.archive_file.etl_silver.output_path
  source_code_hash = data.archive_file.etl_silver.output_base64sha256

  timeout     = 120
  memory_size = 512

  vpc_config {
    subnet_ids         = local.vpc_subnets
    security_group_ids = local.vpc_sgs
  }

  environment {
    variables = merge(local.db_env, {
      GAP_NOVO_TURNO_MINUTOS = tostring(var.gap_novo_turno_minutos)
    })
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  # Limita os containers simultâneos para não estourar o max_connections de um
  # db.t3.micro. -1 = sem reserva (ver variável reserve_concurrency).
  reserved_concurrent_executions = var.reserve_concurrency ? var.etl_silver_max_concurrency : -1

  tags = {
    Name  = local.fn_silver
    Layer = "silver"
  }

  depends_on = [aws_cloudwatch_log_group.etl_silver]
}

resource "aws_lambda_permission" "s3_invoke_silver" {
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.etl_silver.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = var.bronze_bucket_arn
  source_account = var.account_id
}

resource "aws_s3_bucket_notification" "bronze" {
  bucket = var.bronze_bucket

  lambda_function {
    lambda_function_arn = aws_lambda_function.etl_silver.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "eventos/"
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.s3_invoke_silver]
}

# Reprocessa objetos que falharam mesmo depois das tentativas assíncronas.
resource "aws_lambda_function_event_invoke_config" "etl_silver" {
  function_name                = aws_lambda_function.etl_silver.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600
}

# ----------------------------------------------------------------------------
# Lambda ETL Gold
# ----------------------------------------------------------------------------

data "archive_file" "etl_gold" {
  type        = "zip"
  source_dir  = "${var.build_dir}/etl_gold"
  output_path = "${var.build_dir}/_zips/etl_gold.zip"
}

resource "aws_cloudwatch_log_group" "etl_gold" {
  name              = "/aws/lambda/${local.fn_gold}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "etl_gold" {
  function_name = local.fn_gold
  description   = "Atualiza as MATERIALIZED VIEWs do schema gold a cada ciclo do EventBridge"
  role          = var.lambda_role_arn
  handler       = "handler.handler"
  runtime       = var.lambda_runtime
  architectures = ["x86_64"]

  filename         = data.archive_file.etl_gold.output_path
  source_code_hash = data.archive_file.etl_gold.output_base64sha256

  timeout     = 300
  memory_size = 512

  vpc_config {
    subnet_ids         = local.vpc_subnets
    security_group_ids = local.vpc_sgs
  }

  environment {
    variables = merge(local.db_env, {
      METRIC_NAMESPACE     = var.metric_namespace
      STATEMENT_TIMEOUT_MS = "120000"
    })
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

  # Dois refreshes concorrentes da mesma MV se bloqueiam: um de cada vez.
  reserved_concurrent_executions = var.reserve_concurrency ? 1 : -1

  tags = {
    Name  = local.fn_gold
    Layer = "gold"
  }

  depends_on = [aws_cloudwatch_log_group.etl_gold]
}

resource "aws_cloudwatch_event_rule" "etl_gold" {
  name                = "${var.name_prefix}-etl-gold-schedule"
  description         = "Dispara o refresh das views Gold"
  schedule_expression = var.gold_schedule
  state               = "ENABLED"

  tags = {
    Name = "${var.name_prefix}-etl-gold-schedule"
  }
}

resource "aws_cloudwatch_event_target" "etl_gold" {
  rule      = aws_cloudwatch_event_rule.etl_gold.name
  target_id = "lambda-etl-gold"
  arn       = aws_lambda_function.etl_gold.arn
}

resource "aws_lambda_permission" "events_invoke_gold" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.etl_gold.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.etl_gold.arn
}

# ----------------------------------------------------------------------------
# Lambda db_migrate
# ----------------------------------------------------------------------------

data "archive_file" "db_migrate" {
  type        = "zip"
  source_dir  = "${var.build_dir}/db_migrate"
  output_path = "${var.build_dir}/_zips/db_migrate.zip"
}

resource "aws_cloudwatch_log_group" "db_migrate" {
  name              = "/aws/lambda/${local.fn_migrate}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "db_migrate" {
  function_name = local.fn_migrate
  description   = "Aplica o DDL das camadas silver e gold lendo os .sql do bucket de artefatos"
  role          = var.lambda_role_arn
  handler       = "handler.handler"
  runtime       = var.lambda_runtime
  architectures = ["x86_64"]

  filename         = data.archive_file.db_migrate.output_path
  source_code_hash = data.archive_file.db_migrate.output_base64sha256

  timeout     = 600
  memory_size = 512

  vpc_config {
    subnet_ids         = local.vpc_subnets
    security_group_ids = local.vpc_sgs
  }

  environment {
    variables = merge(local.db_env, {
      ARTIFACTS_BUCKET = var.artifacts_bucket
      SQL_PREFIX       = "sql/"
      SEED_DEMO        = tostring(var.seed_demo_data)
    })
  }

  reserved_concurrent_executions = var.reserve_concurrency ? 1 : -1

  tags = {
    Name  = local.fn_migrate
    Layer = "migration"
  }

  depends_on = [aws_cloudwatch_log_group.db_migrate]
}

# Invoca a migração ao final do apply. A dependência do DB e dos objetos SQL
# garante que o banco já esteja disponível e os scripts publicados.
resource "aws_lambda_invocation" "migrate" {
  count = var.run_migrations ? 1 : 0

  function_name = aws_lambda_function.db_migrate.function_name

  input = jsonencode({
    seed = var.seed_demo_data
  })

  # Reexecuta quando os scripts SQL mudarem.
  triggers = {
    sql_hash = var.sql_hash
  }

  depends_on = [
    aws_lambda_function.db_migrate,
    aws_cloudwatch_log_group.db_migrate,
  ]
}
