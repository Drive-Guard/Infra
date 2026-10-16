###############################################################################
# Aplicação: deploy do Backend e publicação do dashboard no próprio apply
#
# Com isto, `terraform apply` deixa o TCC inteiro pronto para usar:
#
#   1. infraestrutura (módulos)            -> VPC, RDS, Cognito, API, EC2...
#   2. migração + seed + carga da PRF      -> módulo etl
#   3. deploy do Backend (osls)            -> rotas e Lambdas na API
#   4. build e publicação do dashboard     -> S3 -> EC2 em até 1 minuto
#
# Os repositórios Backend e Site precisam estar clonados ao lado do Infra
# (../Backend e ../Site), com Node.js 22+ no PATH. Para subir só a
# infraestrutura: -var deploy_aplicacao=false.
#
# No destroy, o stack CloudFormation do Backend é apagado ANTES da API (o
# null_resource remover_backend depende do módulo backend), então
# `terraform destroy` sozinho também não deixa Lambdas órfãs.
#
# O state é compartilhado pelo grupo (S3), então os triggers não guardam nada
# que mude de um computador para outro (caminhos absolutos, sistema): senão o
# apply de cada colega refaria o deploy à toa.
###############################################################################

locals {
  backend_dir = abspath(var.backend_dir)
  site_dir    = abspath(var.site_dir)

  arquivos_backend = var.deploy_aplicacao ? sha1(join("", concat(
    [for f in fileset(local.backend_dir, "src/**/*.ts") : filesha1("${local.backend_dir}/${f}")],
    [filesha1("${local.backend_dir}/serverless.ts"), filesha1("${local.backend_dir}/package-lock.json")],
  ))) : ""

  arquivos_site = var.deploy_aplicacao ? sha1(join("", concat(
    [for f in fileset(local.site_dir, "src/**/*") : filesha1("${local.site_dir}/${f}")],
    [filesha1("${local.site_dir}/package-lock.json"), filesha1("${local.site_dir}/index.html")],
  ))) : ""

  interpretador = local.is_windows ? ["PowerShell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"] : ["bash", "-c"]
}

# Código novo só atualiza o stack (osls deploy). Apagar o stack fica no
# recurso de baixo, que só é destruído no destroy de verdade.
resource "null_resource" "deploy_backend" {
  count = var.deploy_aplicacao ? 1 : 0

  triggers = {
    codigo = local.arquivos_backend
    api    = module.backend.api_id
    banco  = module.database.address
    stage  = var.environment
  }

  provisioner "local-exec" {
    interpreter = local.interpretador
    command = (
      local.is_windows
      ? "& '${abspath(path.module)}/scripts/deploy_backend.ps1' -BackendDir '${local.backend_dir}' -Stage '${self.triggers.stage}'"
      : "'${abspath(path.module)}/scripts/deploy_backend.sh' '${local.backend_dir}' '${self.triggers.stage}'"
    )
  }

  # A migração e o seed precisam ter rodado (o backend lê o banco no deploy
  # não, mas as primeiras requisições sim), e o site depende da API pronta.
  depends_on = [module.backend, module.etl, module.auth, null_resource.remover_backend]
}

# Só existe para o destroy: apaga o stack do Backend antes da API. O
# provisioner de destroy só enxerga `self`, por isso stack e região ficam nos
# triggers. `windows` é ignorado depois de criado: um colega em outro sistema
# não deve recriar (e com isso apagar) o stack.
resource "null_resource" "remover_backend" {
  count = var.deploy_aplicacao ? 1 : 0

  triggers = {
    stack   = "${var.project_name}-backend-${var.environment}"
    regiao  = local.region
    windows = tostring(local.is_windows)
  }

  lifecycle {
    ignore_changes = [triggers["windows"]]
  }

  provisioner "local-exec" {
    when = destroy
    interpreter = (
      self.triggers.windows == "true"
      ? ["PowerShell", "-NoProfile", "-Command"]
      : ["bash", "-c"]
    )
    command = "aws cloudformation delete-stack --region ${self.triggers.regiao} --stack-name ${self.triggers.stack}; aws cloudformation wait stack-delete-complete --region ${self.triggers.regiao} --stack-name ${self.triggers.stack}"
  }

  depends_on = [module.backend]
}

resource "null_resource" "publicar_site" {
  count = var.deploy_aplicacao && var.enable_dashboard ? 1 : 0

  triggers = {
    codigo = local.arquivos_site
    bucket = module.storage.artifacts_bucket_id
    config = aws_s3_object.site_config.etag
  }

  provisioner "local-exec" {
    interpreter = local.interpretador
    environment = {
      SITE_BUCKET = module.storage.artifacts_bucket_id
      SITE_URL    = module.dashboard[0].url
    }
    command = (
      local.is_windows
      ? "& '${abspath(path.module)}/scripts/publicar_site.ps1' -SiteDir '${local.site_dir}' -Bucket '${module.storage.artifacts_bucket_id}' -Url '${module.dashboard[0].url}'"
      : "'${abspath(path.module)}/scripts/publicar_site.sh' '${local.site_dir}'"
    )
  }

  depends_on = [null_resource.deploy_backend, module.dashboard]
}
