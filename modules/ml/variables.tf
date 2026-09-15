variable "name_prefix" {
  description = "Prefixo dos nomes de recurso."
  type        = string
}

variable "role_arn" {
  description = "ARN da role IAM usada pelo SageMaker."
  type        = string
}

variable "instance_type" {
  description = "Tipo da instancia do notebook."
  type        = string
  default     = "ml.t3.medium"
}

variable "volume_gb" {
  description = "Tamanho do volume EBS em GiB."
  type        = number
  default     = 20
}

variable "artifacts_bucket" {
  description = "Bucket onde os modelos treinados sao salvos."
  type        = string
}

variable "bronze_bucket" {
  description = "Bucket Bronze, fonte de dados para analise exploratoria."
  type        = string
}

variable "idle_shutdown_minutes" {
  description = "Minutos de ociosidade antes do autostop do notebook."
  type        = number
  default     = 60
}
