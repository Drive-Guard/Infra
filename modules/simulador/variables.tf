variable "name_prefix" {
  description = "Prefixo dos nomes de recurso."
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
}

variable "ingest_url" {
  description = "URL base da API de ingestão (stage), sem /eventos."
  type        = string
}

variable "api_key" {
  description = "API Key dos dispositivos embarcados."
  type        = string
  sensitive   = true
}

variable "cameras" {
  description = "Quantas câmeras do seed enviam dados (dg-edge-0001 em diante)."
  type        = number
  default     = 16
}

variable "log_retention_days" {
  description = "Retenção do log group."
  type        = number
  default     = 7
}

variable "ativo" {
  description = "Estado inicial dos dados ao vivo (regra do EventBridge). Depois, use scripts/dados_ao_vivo.*."
  type        = bool
  default     = true
}

variable "etl_silver_function" {
  description = "Lambda do ETL Silver, que responde a última leitura de cada câmera (preenchimento de lacunas)."
  type        = string
}

variable "estado_bucket" {
  description = "Bucket onde fica o estado do preenchimento de lacunas (simulador/preenchimento.json)."
  type        = string
}

variable "preencher_max_dias" {
  description = "Até quantos dias para trás o simulador preenche quando encontra uma lacuna."
  type        = number
  default     = 30
}
