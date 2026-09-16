variable "name_prefix" {
  description = "Prefixo dos nomes de recurso."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets do DB subnet group (mínimo duas AZs)."
  type        = list(string)
}

variable "security_group_id" {
  description = "Security Group do RDS."
  type        = string
}

variable "engine_version" {
  description = "Versão do PostgreSQL."
  type        = string
  default     = "16.15"
}

variable "parameter_group_family" {
  description = "Família do parameter group (deve casar com a major version)."
  type        = string
  default     = "postgres16"
}

variable "instance_class" {
  description = "Classe da instância."
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Nome do banco criado na instância."
  type        = string
  default     = "driveguard"
}

variable "username" {
  description = "Usuário master."
  type        = string
  default     = "dgadmin"
}

variable "allocated_storage" {
  description = "Storage inicial em GiB."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Teto do autoscaling de storage em GiB. 0 desabilita."
  type        = number
  default     = 50
}

variable "backup_retention_days" {
  description = "Dias de retenção de backup."
  type        = number
  default     = 1
}

variable "multi_az" {
  description = "Habilita Multi-AZ."
  type        = bool
  default     = false
}

variable "publicly_accessible" {
  description = "Atribui IP público ao RDS."
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "Impede destroy do RDS."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Pula o snapshot final no destroy."
  type        = bool
  default     = true
}
