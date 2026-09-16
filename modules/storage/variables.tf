variable "name_prefix" {
  description = "Prefixo dos nomes de recurso."
  type        = string
}

variable "suffix" {
  description = "Sufixo aleatorio para tornar o nome do bucket globalmente unico."
  type        = string
}

variable "force_destroy" {
  description = "Permite destruir buckets com objetos."
  type        = bool
  default     = false
}

variable "bronze_retention_days" {
  description = "Dias ate expirar objetos do Bronze. 0 desabilita a expiracao."
  type        = number
  default     = 365
}

variable "sql_dir" {
  description = "Diretorio local com os scripts .sql publicados no bucket de artefatos."
  type        = string
}

variable "region" {
  description = "Regiao AWS, usada no esvaziamento dos buckets no destroy."
  type        = string
}

variable "tags" {
  description = <<-EOT
    Tags do projeto. Precisam ser passadas explicitamente porque o provider
    awscc nao suporta `default_tags` como o provider aws.
  EOT
  type        = map(string)
  default     = {}
}
