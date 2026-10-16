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
