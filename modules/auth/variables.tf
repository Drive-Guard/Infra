variable "name_prefix" {
  description = "Prefixo dos nomes de recurso."
  type        = string
}

variable "criar_usuarios_demo" {
  description = "Cria um usuário de demonstração por papel, na empresa do seed."
  type        = bool
  default     = true
}

variable "empresa_demo_id" {
  description = "UUID da empresa de demonstração criada pelo seed (sql/05_seed_demo.sql)."
  type        = string
  default     = "00000000-0000-4000-8000-000000000001"
}

variable "usuarios_demo" {
  description = "Usuários de demonstração: chave -> e-mail, nome e papel (admin, gestor ou operador)."
  type = map(object({
    email = string
    nome  = string
    papel = string
  }))
  default = {
    admin = {
      email = "admin.driveguard@example.com"
      nome  = "Administradora Demo"
      papel = "admin"
    }
    gestor = {
      email = "gestor.driveguard@example.com"
      nome  = "Gestor de Frota Demo"
      papel = "gestor"
    }
    operador = {
      email = "operador.driveguard@example.com"
      nome  = "Operador de Monitoramento Demo"
      papel = "operador"
    }
  }

  validation {
    condition     = alltrue([for u in values(var.usuarios_demo) : contains(["admin", "gestor", "operador"], u.papel)])
    error_message = "O papel de cada usuário precisa ser admin, gestor ou operador."
  }
}

variable "usuario_teste" {
  description = "Usuário de teste com senha definida no tfvars (null para não criar)."
  type = object({
    email = string
    nome  = string
    papel = string
    senha = string
  })
  default   = null
  sensitive = true
}

variable "senha_tamanho_minimo" {
  description = "Tamanho mínimo das senhas do Cognito."
  type        = number
  default     = 10
}

variable "senha_exige_maiuscula" {
  description = "Se as senhas do Cognito precisam de letra maiúscula."
  type        = bool
  default     = true
}
