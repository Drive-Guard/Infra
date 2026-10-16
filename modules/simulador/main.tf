###############################################################################
# Módulo: simulador (opcional)
#
# Faz o papel das câmeras para a dashboard ter dados ao vivo numa
# apresentação sem veículo rodando. A cada minuto, uma Lambda fora da VPC
# posta um lote por câmera do seed na API de ingestão, com a API Key dos
# dispositivos; todo o caminho depois dela (Bronze, ETL, Gold) é o real.
#
# O módulo raiz só o cria depois da migração do banco, para os primeiros
# lotes já encontrarem as tabelas.
###############################################################################

locals {
  function_name = "${var.name_prefix}-simulador"
}

data "archive_file" "simulador" {
  type        = "zip"
  source_dir  = "${var.build_dir}/simulador"
  output_path = "${var.build_dir}/_zips/simulador.zip"
}

resource "aws_cloudwatch_log_group" "simulador" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "simulador" {
  function_name = local.function_name
  description   = "Simula as cameras embarcadas enviando lotes para a API de ingestao"
  role          = var.lambda_role_arn
  handler       = "handler.handler"
  runtime       = var.lambda_runtime
  architectures = ["x86_64"]

  filename         = data.archive_file.simulador.output_path
  source_code_hash = data.archive_file.simulador.output_base64sha256

  timeout     = 30
  memory_size = 128

  environment {
    variables = {
      INGEST_URL        = var.ingest_url
      API_KEY           = var.api_key
      CAMERAS           = tostring(var.cameras)
      LEITURAS_POR_LOTE = "1"
    }
  }

  tags = {
    Name  = local.function_name
    Layer = "demo"
  }

  depends_on = [aws_cloudwatch_log_group.simulador]
}

resource "aws_cloudwatch_event_rule" "simulador" {
  name                = local.function_name
  description         = "Dispara o simulador de telemetria a cada minuto"
  schedule_expression = "rate(1 minute)"
  state               = var.ativo ? "ENABLED" : "DISABLED"

  # Depois de criada, quem liga e desliga é scripts/dados_ao_vivo.* (sem
  # passar pelo Terraform): o apply seguinte não desfaz a escolha.
  lifecycle {
    ignore_changes = [state]
  }
}

resource "aws_cloudwatch_event_target" "simulador" {
  rule      = aws_cloudwatch_event_rule.simulador.name
  target_id = "lambda-simulador"
  arn       = aws_lambda_function.simulador.arn
}

resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.simulador.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.simulador.arn
}
