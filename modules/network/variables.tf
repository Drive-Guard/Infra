variable "name_prefix" {
  description = "Prefixo dos nomes de recurso."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR da VPC."
  type        = string
}

variable "azs" {
  description = "Availability Zones utilizadas."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDRs das subnets públicas."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDRs das subnets privadas."
  type        = list(string)
}

variable "enable_nat_gateway" {
  description = "Cria NAT Gateway (um por AZ pública)."
  type        = bool
  default     = false
}

variable "enable_vpc_interface_endpoints" {
  description = "Cria VPC Endpoints de interface para CloudWatch Logs."
  type        = bool
  default     = true
}

variable "admin_cidrs" {
  description = "CIDRs com acesso SSH à EC2."
  type        = list(string)
  default     = []
}

variable "dashboard_allowed_cidrs" {
  description = "CIDRs com acesso HTTP/HTTPS ao dashboard."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "db_publicly_accessible" {
  description = "Se true, o RDS fica em subnet pública."
  type        = bool
  default     = false
}

variable "region" {
  description = "Região AWS (usada nos service names dos endpoints)."
  type        = string
}
