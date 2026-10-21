###############################################################################
# Módulo: backend
#
# O que o backend da dashboard (repositório Drive-Guard/Backend) precisa que
# já exista antes do deploy dele:
#
#   * a API HTTP com o autorizador JWT do Cognito e o stage $default;
#   * as notificações do bucket de artefatos para o EventBridge, que ligam as
#     Lambdas de dentro e de fora da VPC por arquivos no S3;
#   * os parâmetros no SSM com tudo que o serverless.ts lê no deploy.
#
# O deploy do backend (osls, um stack CloudFormation à parte) só pendura
# rotas e Lambdas nesta API. Assim a URL da API e a configuração de login
# nascem no `terraform apply` e a dashboard já sobe apontando para elas.
###############################################################################

locals {
  ssm_prefix = "/${var.name_prefix}/backend"
}

# ----------------------------------------------------------------------------
# API HTTP
# ----------------------------------------------------------------------------

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name_prefix}-backend"
  description   = "API da dashboard DriveGuard (rotas publicadas pelo deploy do backend)"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.cors_allow_origins
    allow_methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
    allow_headers = ["authorization", "content-type"]
    max_age       = 3600
  }

  tags = {
    Name = "${var.name_prefix}-backend"
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.this.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  # O front manda o ID token, que carrega o nome, a empresa e os grupos.
  # No ID token o `aud` é o client id do app.
  jwt_configuration {
    issuer   = var.cognito_issuer
    audience = [var.cognito_client_id]
  }
}

resource "aws_cloudwatch_log_group" "api" {
  count = var.enable_access_logs ? 1 : 0

  name              = "/aws/apigateway/${var.name_prefix}-backend"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }

  dynamic "access_log_settings" {
    for_each = var.enable_access_logs ? [1] : []
    content {
      destination_arn = aws_cloudwatch_log_group.api[0].arn
      format = jsonencode({
        requestId = "$context.requestId"
        ip        = "$context.identity.sourceIp"
        metodo    = "$context.httpMethod"
        rota      = "$context.routeKey"
        status    = "$context.status"
        latencia  = "$context.responseLatency"
        erro      = "$context.error.message"
        auth      = "$context.authorizer.error"
      })
    }
  }

  tags = {
    Name = "${var.name_prefix}-backend-default"
  }
}

# ----------------------------------------------------------------------------
# Bucket de artefatos -> EventBridge
#
# Os relatórios, os insights e as exportações passam por arquivos neste
# bucket: a Lambda de dentro da VPC (que lê o banco) grava o contexto, a de
# fora (que fala com a internet: IA, e-mail) reage ao arquivo, e vice-versa.
# As regras que filtram por prefixo são criadas pelo deploy do backend.
# ----------------------------------------------------------------------------

resource "aws_s3_bucket_notification" "artifacts" {
  bucket      = var.artifacts_bucket
  eventbridge = true
}

# ----------------------------------------------------------------------------
# Parâmetros lidos pelo serverless.ts do backend
# ----------------------------------------------------------------------------

resource "aws_ssm_parameter" "string" {
  for_each = {
    http_api_id         = aws_apigatewayv2_api.this.id
    authorizer_id       = aws_apigatewayv2_authorizer.cognito.id
    api_url             = aws_apigatewayv2_api.this.api_endpoint
    deployment_bucket   = var.artifacts_bucket
    reports_bucket      = var.artifacts_bucket
    security_group_id   = var.lambda_security_group_id
    lambda_role_arn     = var.lambda_role_arn
    db_host             = var.db_host
    db_port             = tostring(var.db_port)
    db_name             = var.db_name
    db_user             = var.db_username
    user_pool_id        = var.cognito_user_pool_id
    user_pool_client_id = var.cognito_client_id
    site_url            = var.site_url
    email_remetente     = var.email_remetente
    smtp_usuario        = var.smtp_usuario
    ia_modelo           = var.ia_modelo
  }

  name  = "${local.ssm_prefix}/${each.key}"
  type  = "String"
  value = each.value != "" ? each.value : "nao-configurado"

  tags = {
    Name = "${var.name_prefix}-backend-${each.key}"
  }
}

resource "aws_ssm_parameter" "subnet_ids" {
  name  = "${local.ssm_prefix}/subnet_ids"
  type  = "StringList"
  value = join(",", var.private_subnet_ids)
}

# Segredos em recursos separados: o Terraform não aceita valor sensível
# dentro de um for_each.
resource "aws_ssm_parameter" "db_password" {
  name  = "${local.ssm_prefix}/db_password"
  type  = "SecureString"
  value = var.db_password

  tags = {
    Name = "${var.name_prefix}-backend-db_password"
  }
}

# Senha de app do Gmail: segue o segredos.auto.tfvars (sem ignore_changes,
# para quem configurar o e-mail depois só rodar o subir de novo).
resource "aws_ssm_parameter" "smtp_senha" {
  name  = "${local.ssm_prefix}/smtp_senha"
  type  = "SecureString"
  value = var.smtp_senha != "" ? var.smtp_senha : "nao-configurado"

  tags = {
    Name = "${var.name_prefix}-backend-smtp_senha"
  }
}

resource "aws_ssm_parameter" "ia_api_key" {
  name  = "${local.ssm_prefix}/ia_api_key"
  type  = "SecureString"
  value = var.ia_api_key != "" ? var.ia_api_key : "nao-configurado"

  tags = {
    Name = "${var.name_prefix}-backend-ia_api_key"
  }

  # A chave pode ser trocada à mão no console sem o Terraform desfazer.
  lifecycle {
    ignore_changes = [value]
  }
}
