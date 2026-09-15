###############################################################################
# Módulo: ingest
#
# Veículo --HTTPS--> API Gateway (REST, API Key + throttling)
#                        |
#                        v
#                   Lambda Ingest  --> S3 Bronze (JSON cru)
#
# A Lambda de ingestão fica FORA da VPC de propósito: ela só fala com o S3,
# e uma Lambda em VPC paga ENI e cold start de rede sem ganhar nada aqui.
###############################################################################

locals {
  function_name = "${var.name_prefix}-ingest"
}

# ----------------------------------------------------------------------------
# Lambda
# ----------------------------------------------------------------------------

data "archive_file" "ingest" {
  type        = "zip"
  source_dir  = "${var.build_dir}/ingest"
  output_path = "${var.build_dir}/_zips/ingest.zip"
}

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${local.function_name}-logs"
  }
}

resource "aws_lambda_function" "ingest" {
  function_name = local.function_name
  description   = "Grava os lotes de eventos do veiculo na camada Bronze do S3"
  role          = var.lambda_role_arn
  handler       = "handler.handler"
  runtime       = var.lambda_runtime
  architectures = ["x86_64"]

  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256

  timeout     = 15
  memory_size = 256

  environment {
    variables = {
      BRONZE_BUCKET         = var.bronze_bucket
      BRONZE_PREFIX         = "eventos"
      MAX_LEITURAS_POR_LOTE = tostring(var.max_leituras_por_lote)
      LOG_LEVEL             = var.log_level
    }
  }

  tags = {
    Name  = local.function_name
    Layer = "ingest"
  }

  depends_on = [aws_cloudwatch_log_group.ingest]
}

# ----------------------------------------------------------------------------
# API Gateway REST
# ----------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "this" {
  name        = "${var.name_prefix}-api"
  description = "API de ingestao de eventos de fadiga do DriveGuard"

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  # Comprime as respostas acima de 1 KB. O limite de tamanho do corpo da
  # requisicao e imposto pelo proprio API Gateway (10 MB) e por
  # MAX_LEITURAS_POR_LOTE na Lambda.
  minimum_compression_size = 1024

  tags = {
    Name = "${var.name_prefix}-api"
  }
}

# --- POST /eventos ---------------------------------------------------------

resource "aws_api_gateway_resource" "eventos" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "eventos"
}

resource "aws_api_gateway_method" "post_eventos" {
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.eventos.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "post_eventos" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.eventos.id
  http_method = aws_api_gateway_method.post_eventos.http_method

  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.ingest.invoke_arn
  timeout_milliseconds    = 15000
}

# --- GET /health -----------------------------------------------------------
# Sem API Key: serve para o veículo checar conectividade antes de gastar
# bateria montando um lote, e para o health check do monitoramento.

resource "aws_api_gateway_resource" "health" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "health"
}

resource "aws_api_gateway_method" "get_health" {
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.health.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = false
}

resource "aws_api_gateway_integration" "get_health" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.health.id
  http_method = aws_api_gateway_method.get_health.http_method

  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.ingest.invoke_arn
}

# --- Deployment + Stage ----------------------------------------------------

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Redeploy sempre que método ou integração mudarem.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.eventos.id,
      aws_api_gateway_method.post_eventos.id,
      aws_api_gateway_integration.post_eventos.id,
      aws_api_gateway_resource.health.id,
      aws_api_gateway_method.get_health.id,
      aws_api_gateway_integration.get_health.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "api_access" {
  count = var.enable_access_logs ? 1 : 0

  name              = "/aws/apigateway/${var.name_prefix}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name

  description          = "Stage ${var.stage_name} da API de ingestao"
  xray_tracing_enabled = false

  dynamic "access_log_settings" {
    for_each = var.enable_access_logs ? [1] : []
    content {
      destination_arn = aws_cloudwatch_log_group.api_access[0].arn
      format = jsonencode({
        requestId      = "$context.requestId"
        ip             = "$context.identity.sourceIp"
        requestTime    = "$context.requestTime"
        httpMethod     = "$context.httpMethod"
        resourcePath   = "$context.resourcePath"
        status         = "$context.status"
        responseLength = "$context.responseLength"
        latency        = "$context.responseLatency"
        apiKeyId       = "$context.identity.apiKeyId"
      })
    }
  }

  tags = {
    Name = "${var.name_prefix}-api-${var.stage_name}"
  }
}

resource "aws_api_gateway_method_settings" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
    metrics_enabled        = true
    logging_level          = var.enable_access_logs ? "INFO" : "OFF"
    data_trace_enabled     = false
  }
}

# --- API Key + Usage Plan --------------------------------------------------

resource "aws_api_gateway_api_key" "edge" {
  name        = "${var.name_prefix}-edge-key"
  description = "Chave usada pelos dispositivos embarcados nos veiculos"
  enabled     = true

  tags = {
    Name = "${var.name_prefix}-edge-key"
  }
}

resource "aws_api_gateway_usage_plan" "this" {
  name        = "${var.name_prefix}-usage-plan"
  description = "Limites de uso da frota embarcada"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    rate_limit  = var.throttle_rate_limit
    burst_limit = var.throttle_burst_limit
  }

  quota_settings {
    limit  = var.quota_limit
    period = "MONTH"
  }

  tags = {
    Name = "${var.name_prefix}-usage-plan"
  }
}

resource "aws_api_gateway_usage_plan_key" "edge" {
  key_id        = aws_api_gateway_api_key.edge.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.this.id
}

# --- Permissão para o API Gateway invocar a Lambda -------------------------

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}
