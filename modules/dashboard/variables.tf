variable "name_prefix" {
  description = "Prefixo dos nomes de recurso."
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
  default     = "t3.micro"
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

variable "site_bucket" {
  description = "Bucket com o build do dashboard (prefixo site/) e o config.json (site-config/)."
  type        = string
}
