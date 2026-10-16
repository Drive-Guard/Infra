###############################################################################
# Módulo: auth
#
# Login da dashboard com Amazon Cognito. Cada usuário pertence a uma empresa
# (atributo custom:empresa_id) e a um papel (grupo do Cognito):
#
#   admin     — tudo, inclusive cadastro de usuários
#   gestor    — visão gerencial (KPIs, ROI, relatórios) e cadastros da frota
#   operador  — visão técnica (monitoramento em tempo real, alertas)
#
# O ID token sai do Cognito com os grupos (claim cognito:groups) e a empresa;
# o autorizador JWT da API valida a assinatura e o backend aplica o papel e o
# filtro da empresa em cada consulta.
#
# O cadastro é fechado (só administradores criam usuários): a dashboard é de
# uso interno da transportadora.
###############################################################################

resource "aws_cognito_user_pool" "this" {
  name = "${var.name_prefix}-usuarios"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length                   = var.senha_tamanho_minimo
    require_lowercase                = true
    require_uppercase                = var.senha_exige_maiuscula
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # UUID da empresa em silver.empresas. Não aparece nos atributos graváveis do
  # app client: o usuário não consegue trocar a própria empresa.
  schema {
    name                     = "empresa_id"
    attribute_data_type      = "String"
    mutable                  = true
    required                 = false
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 36
      max_length = 36
    }
  }

  deletion_protection = "INACTIVE"

  tags = {
    Name = "${var.name_prefix}-usuarios"
  }

  lifecycle {
    # O Cognito não permite alterar o schema depois de criado.
    ignore_changes = [schema]
  }
}

resource "aws_cognito_user_pool_client" "dashboard" {
  name         = "${var.name_prefix}-dashboard"
  user_pool_id = aws_cognito_user_pool.this.id

  # SPA no navegador: não há onde guardar um segredo.
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  read_attributes  = ["email", "email_verified", "name", "custom:empresa_id"]
  write_attributes = ["email", "name"]

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true
}

resource "aws_cognito_user_group" "papel" {
  for_each = {
    admin    = { precedencia = 1, descricao = "Acesso total, inclusive usuários" }
    gestor   = { precedencia = 2, descricao = "Visão gerencial, ROI, relatórios e cadastros da frota" }
    operador = { precedencia = 3, descricao = "Visão técnica: monitoramento e alertas" }
  }

  name         = each.key
  user_pool_id = aws_cognito_user_pool.this.id
  precedence   = each.value.precedencia
  description  = each.value.descricao
}

# ----------------------------------------------------------------------------
# Usuários de demonstração (um por papel), na empresa do seed
# ----------------------------------------------------------------------------

resource "random_password" "demo" {
  for_each = var.criar_usuarios_demo ? var.usuarios_demo : {}

  length      = 16
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

resource "aws_cognito_user" "demo" {
  for_each = var.criar_usuarios_demo ? var.usuarios_demo : {}

  user_pool_id = aws_cognito_user_pool.this.id
  username     = each.value.email

  # Senha definitiva: o usuário entra direto, sem a troca obrigatória.
  password       = random_password.demo[each.key].result
  message_action = "SUPPRESS"

  attributes = {
    email          = each.value.email
    email_verified = "true"
    name           = each.value.nome
    # Atributo customizado vai sem o prefixo "custom:": o provider acrescenta.
    # Com o prefixo, o apply seguinte não reconhece a chave e apaga o atributo.
    empresa_id = var.empresa_demo_id
  }
}

resource "aws_cognito_user_in_group" "demo" {
  for_each = var.criar_usuarios_demo ? var.usuarios_demo : {}

  user_pool_id = aws_cognito_user_pool.this.id
  group_name   = aws_cognito_user_group.papel[each.value.papel].name
  username     = aws_cognito_user.demo[each.key].username
}

# ----------------------------------------------------------------------------
# Usuário de teste com senha escolhida por quem opera o ambiente
#
# Fica fora dos usuários de demonstração porque a senha não é gerada: vem do
# terraform.tfvars local (que não vai para o git). Útil para a banca e para os
# testes manuais, já que a senha é fácil de digitar.
# ----------------------------------------------------------------------------

resource "aws_cognito_user" "teste" {
  count = var.usuario_teste == null ? 0 : 1

  user_pool_id   = aws_cognito_user_pool.this.id
  username       = var.usuario_teste.email
  password       = var.usuario_teste.senha
  message_action = "SUPPRESS"

  attributes = {
    email          = var.usuario_teste.email
    email_verified = "true"
    name           = var.usuario_teste.nome
    # Atributo customizado vai sem o prefixo "custom:": o provider acrescenta.
    # Com o prefixo, o apply seguinte não reconhece a chave e apaga o atributo.
    empresa_id = var.empresa_demo_id
  }
}

resource "aws_cognito_user_in_group" "teste" {
  count = var.usuario_teste == null ? 0 : 1

  user_pool_id = aws_cognito_user_pool.this.id
  group_name   = aws_cognito_user_group.papel[var.usuario_teste.papel].name
  username     = aws_cognito_user.teste[0].username
}
