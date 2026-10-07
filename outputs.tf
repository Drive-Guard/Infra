###############################################################################
# Outputs
#
# Valores sensíveis (API Key, senha do banco) não aparecem no terminal.
# Para lê-los:
#     terraform output -raw api_key_value
#     terraform output -raw db_password
###############################################################################

# ----------------------------------------------------------------------------
# Resumo
# ----------------------------------------------------------------------------

output "resumo" {
  description = "Principais endereços da infraestrutura provisionada."
  value = {
    regiao               = local.region
    conta                = local.account_id
    ambiente             = var.environment
    api_eventos          = module.ingest.eventos_endpoint
    api_health           = module.ingest.health_endpoint
    dashboard_url        = var.enable_dashboard ? module.dashboard[0].url : "desabilitado"
    banco                = module.database.endpoint
    bucket_bronze        = module.storage.bronze_bucket_id
    bucket_artefatos     = module.storage.artifacts_bucket_id
    notebook_sagemaker   = var.enable_sagemaker ? module.ml[0].notebook_url : "desabilitado"
    cloudwatch_dashboard = var.enable_cloudwatch_dashboard ? "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${local.name_prefix}-visao-geral" : "desabilitado"
  }
}

# ----------------------------------------------------------------------------
# Rede
# ----------------------------------------------------------------------------

output "vpc_id" {
  description = "ID da VPC."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Subnets públicas."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Subnets privadas."
  value       = module.network.private_subnet_ids
}

# ----------------------------------------------------------------------------
# Ingestão
# ----------------------------------------------------------------------------

output "api_invoke_url" {
  description = "URL base da API de ingestão."
  value       = module.ingest.invoke_url
}

output "api_eventos_endpoint" {
  description = "Endpoint POST de ingestão de eventos."
  value       = module.ingest.eventos_endpoint
}

output "api_key_value" {
  description = "API Key dos dispositivos embarcados. Use `terraform output -raw api_key_value`."
  value       = module.ingest.api_key_value
  sensitive   = true
}

output "curl_de_teste" {
  description = "Comando pronto para testar a ingestão (substitua SUA_API_KEY)."
  value       = <<-EOT
    curl -X POST '${module.ingest.eventos_endpoint}' \
      -H 'x-api-key: SUA_API_KEY' \
      -H 'Content-Type: application/json' \
      -d '{"device_id":"dg-edge-0001","motorista_hash":"abc123","veiculo_hash":"veh123","leituras":[{"registrado_em":"2026-01-01T03:00:00Z","ear":0.16,"mar":0.51,"perclos":0.54,"blink_rate":8,"head_pitch":-18,"score_fadiga":88,"estado":"sonolento"}]}'
  EOT
}

# ----------------------------------------------------------------------------
# Armazenamento
# ----------------------------------------------------------------------------

output "bronze_bucket" {
  description = "Bucket da camada Bronze."
  value       = module.storage.bronze_bucket_id
}

output "artifacts_bucket" {
  description = "Bucket de artefatos (código, SQL, modelos)."
  value       = module.storage.artifacts_bucket_id
}

# ----------------------------------------------------------------------------
# Banco
# ----------------------------------------------------------------------------

output "db_endpoint" {
  description = "Endpoint host:porta do RDS."
  value       = module.database.endpoint
}

output "db_name" {
  description = "Nome do banco."
  value       = module.database.db_name
}

output "db_username" {
  description = "Usuário master."
  value       = module.database.username
}

output "db_password" {
  description = "Senha master. Use `terraform output -raw db_password`."
  value       = module.database.password
  sensitive   = true
}

output "db_connection_uri" {
  description = "URI completa de conexão. Use `terraform output -raw db_connection_uri`."
  value       = module.database.connection_uri
  sensitive   = true
}

output "db_ssm_parameters" {
  description = "Caminhos no SSM Parameter Store com as credenciais."
  value = {
    senha = module.database.ssm_password_parameter
    uri   = module.database.ssm_uri_parameter
  }
}

# ----------------------------------------------------------------------------
# ETL
# ----------------------------------------------------------------------------

output "lambdas" {
  description = "Nomes das funções Lambda da solução."
  value = {
    ingest     = module.ingest.lambda_function_name
    etl_silver = module.etl.etl_silver_function_name
    etl_gold   = module.etl.etl_gold_function_name
    db_migrate = module.etl.db_migrate_function_name
  }
}

output "etl_dlq_url" {
  description = "URL da DLQ do ETL."
  value       = module.etl.dlq_url
}

output "gold_refresh_schedule" {
  description = "Agendamento do refresh das views Gold."
  value       = var.etl_gold_schedule
}

output "migration_result" {
  description = "Resultado da migração do schema executada no apply."
  value       = module.etl.migration_result
}

# ----------------------------------------------------------------------------
# Dashboard e ML
# ----------------------------------------------------------------------------

output "dashboard_url" {
  description = "URL pública do dashboard DriveGuard."
  value       = var.enable_dashboard ? module.dashboard[0].url : null
}

output "dashboard_instance_id" {
  description = "ID da EC2 do dashboard."
  value       = var.enable_dashboard ? module.dashboard[0].instance_id : null
}

output "sagemaker_notebook_url" {
  description = "URL do notebook SageMaker."
  value       = var.enable_sagemaker ? module.ml[0].notebook_url : null
}

# ----------------------------------------------------------------------------
# Observabilidade
# ----------------------------------------------------------------------------

output "sns_topic_alarmes" {
  description = "Tópico SNS que recebe os alarmes."
  value       = module.observability.sns_topic_arn
}

output "cloudwatch_dashboard_name" {
  description = "Nome do dashboard do CloudWatch."
  value       = module.observability.dashboard_name
}
