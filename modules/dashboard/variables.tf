variable "name_prefix" {
  description = "Prefixo dos nomes de recurso."
  type        = string
}

variable "project_name" {
  description = "Nome do projeto (exibido na página de status)."
  type        = string
}

variable "environment" {
  description = "Ambiente lógico."
  type        = string
}

variable "region" {
  description = "Região AWS."
  type        = string
}

variable "instance_type" {
  description = "Tipo da instância EC2."
  type        = string
  default     = "t3.small"
}

variable "subnet_id" {
  description = "Subnet pública onde a instância sobe."
  type        = string
}

variable "security_group_id" {
  description = "Security Group da instância."
  type        = string
}

variable "instance_profile_name" {
  description = "Instance profile IAM da EC2."
  type        = string
}

variable "key_pair_name" {
  description = "Key pair SSH. Vazio = sem chave."
  type        = string
  default     = ""
}

variable "root_volume_gb" {
  description = "Tamanho do volume raiz em GiB."
  type        = number
  default     = 20
}

variable "ssm_uri_parameter" {
  description = "Caminho do SSM Parameter Store com a URI do banco."
  type        = string
}

variable "repo_url" {
  description = "Repositório Git do dashboard."
  type        = string
}

variable "repo_subdir" {
  description = "Subdiretório do repositório com o package.json."
  type        = string
  default     = ""
}
