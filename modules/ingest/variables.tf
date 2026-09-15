variable "name_prefix" {
  description = "Prefixo dos nomes de recurso."
  type        = string
}

variable "build_dir" {
  description = "Diretório com os pacotes já montados pelas scripts/build_lambdas.*"
  type        = string
}

variable "lambda_role_arn" {
  description = "ARN da role de execução da Lambda."
  type        = string
}

variable "lambda_runtime" {
  description = "Runtime Python."
  type        = string
  default     = "python3.12"
}

variable "bronze_bucket" {
  description = "Nome do bucket Bronze."
  type        = string
}

variable "max_leituras_por_lote" {
  description = "Máximo de leituras aceitas em um único POST."
  type        = number
  default     = 1000
}

variable "stage_name" {
  description = "Nome do stage do API Gateway."
  type        = string
  default     = "v1"
}

variable "throttle_rate_limit" {
  description = "Requisições por segundo."
  type        = number
  default     = 50
}

variable "throttle_burst_limit" {
  description = "Burst de requisições."
  type        = number
  default     = 100
}

variable "quota_limit" {
  description = "Cota mensal de requisições."
  type        = number
  default     = 1000000
}

variable "enable_access_logs" {
  description = "Habilita access log do API Gateway."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retenção dos log groups."
  type        = number
  default     = 14
}

variable "log_level" {
  description = "LOG_LEVEL da Lambda."
  type        = string
  default     = "INFO"
}
