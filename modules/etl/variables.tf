variable "name_prefix" {
  description = "Prefixo dos nomes de recurso."
  type        = string
}

variable "account_id" {
  description = "ID da conta AWS (usado no source_account do trigger S3)."
  type        = string
}

variable "build_dir" {
  description = "Diretório com os pacotes montados por scripts/build_lambdas.*"
  type        = string
}

variable "lambda_role_arn" {
  description = "ARN da role de execução das Lambdas."
  type        = string
}

variable "lambda_runtime" {
  description = "Runtime Python."
  type        = string
  default     = "python3.12"
}

variable "private_subnet_ids" {
  description = "Subnets privadas onde as Lambdas rodam."
  type        = list(string)
}

variable "lambda_security_group_id" {
  description = "Security Group das Lambdas."
  type        = string
}

variable "bronze_bucket" {
  description = "Nome do bucket Bronze."
  type        = string
}

variable "bronze_bucket_arn" {
  description = "ARN do bucket Bronze."
  type        = string
}

variable "artifacts_bucket" {
  description = "Nome do bucket de artefatos (onde ficam os .sql)."
  type        = string
}

variable "db_host" {
  description = "Hostname do RDS."
  type        = string
}

variable "db_port" {
  description = "Porta do RDS."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Nome do banco."
  type        = string
}

variable "db_username" {
  description = "Usuário do banco."
  type        = string
}

variable "db_password" {
  description = "Senha do banco."
  type        = string
  sensitive   = true
}

variable "gold_schedule" {
  description = "Expressão de agendamento do refresh Gold."
  type        = string
  default     = "rate(5 minutes)"
}

variable "gap_novo_turno_minutos" {
  description = "Intervalo sem leituras que faz o ETL abrir um novo turno."
  type        = number
  default     = 45
}

variable "etl_silver_max_concurrency" {
  description = "Concorrência reservada do ETL Silver (protege o pool do RDS)."
  type        = number
  default     = 5
}

variable "reserve_concurrency" {
  description = <<-EOT
    Reserva concorrência por função. A AWS só aceita a reserva se sobrarem ao
    menos 100 de concorrência não reservada na conta — contas de laboratório
    com cota reduzida rejeitam o apply com InvalidParameterValueException.
    Desligue nesse caso: as funções passam a usar o pool compartilhado.
  EOT
  type        = bool
  default     = true
}

variable "metric_namespace" {
  description = "Namespace das métricas customizadas do ETL."
  type        = string
  default     = "DriveGuard/ETL"
}

variable "log_retention_days" {
  description = "Retenção dos log groups."
  type        = number
  default     = 14
}

variable "log_level" {
  description = "LOG_LEVEL das Lambdas."
  type        = string
  default     = "INFO"
}

variable "run_migrations" {
  description = "Invoca a Lambda de migração ao final do apply."
  type        = bool
  default     = true
}

variable "seed_demo_data" {
  description = "Aplica também o script de seed."
  type        = bool
  default     = true
}

variable "sql_hash" {
  description = "Hash do conteúdo dos scripts SQL; muda -> migração reexecuta."
  type        = string
  default     = ""
}
