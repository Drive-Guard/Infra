variable "name_prefix" {
  description = "Prefixo dos nomes de recurso."
  type        = string
}

variable "cognito_issuer" {
  description = "Issuer do user pool (https://cognito-idp.<regiao>.amazonaws.com/<pool>)."
  type        = string
}

variable "cognito_user_pool_id" {
  description = "ID do user pool."
  type        = string
}

variable "cognito_client_id" {
  description = "ID do app client da dashboard (audience do ID token)."
  type        = string
}

variable "cors_allow_origins" {
  description = "Origens que podem chamar a API pelo navegador."
  type        = list(string)
}

variable "throttle_rate_limit" {
  description = "Requisições por segundo, em regime, por rota."
  type        = number
  default     = 50
}

variable "throttle_burst_limit" {
  description = "Rajada máxima por rota."
  type        = number
  default     = 100
}

variable "log_retention_days" {
  description = "Retenção do log de acesso da API."
  type        = number
  default     = 14
}

variable "enable_access_logs" {
  description = "Grava o log de acesso da API no CloudWatch."
  type        = bool
  default     = false
}

variable "artifacts_bucket" {
  description = "Bucket de artefatos: deploy do backend, relatórios e arquivos de troca."
  type        = string
}

variable "private_subnet_ids" {
  description = "Subnets privadas para as Lambdas do backend que falam com o banco."
  type        = list(string)
}

variable "lambda_security_group_id" {
  description = "Security Group das Lambdas (já liberado no SG do RDS)."
  type        = string
}

variable "lambda_role_arn" {
  description = "Role de execução das Lambdas (LabRole no Learner Lab)."
  type        = string
}

variable "db_host" {
  description = "Hostname do RDS."
  type        = string
}

variable "db_port" {
  description = "Porta do RDS."
  type        = number
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

variable "site_url" {
  description = "URL pública da dashboard (vai nos e-mails de relatório)."
  type        = string
  default     = ""
}

variable "email_remetente" {
  description = "Remetente verificado no SES para o envio de relatórios. Vazio = só link no S3."
  type        = string
  default     = ""
}

variable "ia_modelo" {
  description = "Modelo de IA usado nos insights (camada gratuita)."
  type        = string
  default     = "gemini-3.6-flash,gemini-3.5-flash"
}

variable "ia_api_key" {
  description = "Chave da API de IA. Vazio = os insights saem das regras, sem IA."
  type        = string
  default     = ""
  sensitive   = true
}
