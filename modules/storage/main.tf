###############################################################################
# Módulo: storage
#
# Dois buckets:
#   bronze    — camada Bronze do Medallion. JSON cru e imutável enviado pelo
#               veículo, particionado por data (dt=YYYY-MM-DD/). Versionado,
#               criptografado e fechado para acesso público.
#   artifacts — código empacotado das Lambdas, scripts SQL de migração,
#               modelos treinados e saídas do SageMaker.
#
# Não há bucket "silver"/"gold": essas camadas vivem no RDS PostgreSQL
# (schema silver + MATERIALIZED VIEWs mv_*).
#
# ---------------------------------------------------------------------------
# POR QUE `awscc_s3_bucket` E NÃO `aws_s3_bucket`
#
# A Service Control Policy do AWS Academy Learner Lab nega explicitamente
# `s3:GetBucketObjectLockConfiguration`. O recurso `aws_s3_bucket` chama essa
# API em TODO refresh, então ele quebra o `plan` e o `apply` nesta conta:
#
#   Error: reading S3 Bucket (...) object lock configuration: ...
#   AccessDenied ... with an explicit deny in a service control policy
#
# Não há como desligar essa leitura, e o problema persiste no provider 6.x.
# O `awscc_s3_bucket` usa a Cloud Control API, que não faz essa chamada e
# funciona normalmente aqui.
#
# A configuração continua toda declarativa no provider `aws`: versionamento,
# criptografia, lifecycle, bloqueio de acesso público e policy são recursos
# separados (`aws_s3_bucket_*`), e todas as APIs que eles usam são permitidas
# pelo SCP. Só a criação do bucket muda de provider.
###############################################################################

locals {
  bronze_bucket_name    = "${var.name_prefix}-bronze-${var.suffix}"
  artifacts_bucket_name = "${var.name_prefix}-artifacts-${var.suffix}"

  # O provider awscc não tem `default_tags`, e espera uma lista de pares em
  # vez de um mapa. As tags do projeto são convertidas aqui.
  tags_awscc = [for k, v in var.tags : { key = k, value = v }]
}

# ----------------------------------------------------------------------------
# Bucket Bronze
# ----------------------------------------------------------------------------

resource "awscc_s3_bucket" "bronze" {
  bucket_name = local.bronze_bucket_name

  tags = concat(local.tags_awscc, [
    { key = "Name", value = local.bronze_bucket_name },
    { key = "MedallionTier", value = "bronze" },
  ])
}

resource "aws_s3_bucket_public_access_block" "bronze" {
  bucket = awscc_s3_bucket.bronze.bucket_name

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "bronze" {
  bucket = awscc_s3_bucket.bronze.bucket_name

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bronze" {
  bucket = awscc_s3_bucket.bronze.bucket_name

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "bronze" {
  bucket = awscc_s3_bucket.bronze.bucket_name

  # Eventos crus são lidos pelo ETL em minutos e depois quase nunca relidos:
  # migram para classes mais baratas rapidamente.
  rule {
    id     = "transicao-para-classes-frias"
    status = "Enabled"

    filter {
      prefix = "eventos/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    dynamic "expiration" {
      for_each = var.bronze_retention_days > 0 ? [1] : []
      content {
        days = var.bronze_retention_days
      }
    }
  }

  rule {
    id     = "limpeza-de-versoes-antigas"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.bronze]
}

# Impede qualquer acesso sem TLS.
resource "aws_s3_bucket_policy" "bronze" {
  bucket = awscc_s3_bucket.bronze.bucket_name
  policy = data.aws_iam_policy_document.bronze.json

  depends_on = [aws_s3_bucket_public_access_block.bronze]
}

data "aws_iam_policy_document" "bronze" {
  statement {
    sid    = "NegarTrafegoSemTLS"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      awscc_s3_bucket.bronze.arn,
      "${awscc_s3_bucket.bronze.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# ----------------------------------------------------------------------------
# Bucket de artefatos
# ----------------------------------------------------------------------------

resource "awscc_s3_bucket" "artifacts" {
  bucket_name = local.artifacts_bucket_name

  tags = concat(local.tags_awscc, [
    { key = "Name", value = local.artifacts_bucket_name },
  ])
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = awscc_s3_bucket.artifacts.bucket_name

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = awscc_s3_bucket.artifacts.bucket_name

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = awscc_s3_bucket.artifacts.bucket_name

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = awscc_s3_bucket.artifacts.bucket_name

  rule {
    id     = "limpeza-de-versoes-antigas"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 15
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.artifacts]
}

# ----------------------------------------------------------------------------
# Esvaziamento no destroy
#
# A Cloud Control API recusa apagar bucket com objetos, e `awscc_s3_bucket`
# não tem o `force_destroy` do provider aws. Como os buckets são VERSIONADOS,
# `aws s3 rm --recursive` não basta: ele só remove a versão corrente e deixa
# as versões antigas e os delete markers — e o destroy trava no bucket.
# scripts/esvaziar_bucket.* apaga todas as versões.
#
# Estes null_resource dependem dos buckets, então o Terraform os destrói
# ANTES deles. Provisioner de destroy só enxerga `self`, por isso tudo que o
# comando precisa (script, SO, região) vai nos triggers.
# ----------------------------------------------------------------------------

locals {
  is_windows = !startswith(pathexpand("~"), "/")
  script_esvaziar = abspath(
    local.is_windows
    ? "${path.module}/../../scripts/esvaziar_bucket.ps1"
    : "${path.module}/../../scripts/esvaziar_bucket.sh"
  )
}

resource "null_resource" "esvaziar" {
  for_each = var.force_destroy ? {
    bronze    = awscc_s3_bucket.bronze.bucket_name
    artifacts = awscc_s3_bucket.artifacts.bucket_name
  } : {}

  triggers = {
    bucket  = each.value
    region  = var.region
    windows = tostring(local.is_windows)
    script  = local.script_esvaziar
  }

  provisioner "local-exec" {
    when = destroy
    interpreter = (
      self.triggers.windows == "true"
      ? ["PowerShell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]
      : ["bash", "-c"]
    )
    command = (
      self.triggers.windows == "true"
      ? "& '${self.triggers.script}' -Bucket '${self.triggers.bucket}' -Regiao '${self.triggers.region}'"
      : "'${self.triggers.script}' '${self.triggers.bucket}' '${self.triggers.region}'"
    )
  }
}

# ----------------------------------------------------------------------------
# Scripts SQL de migração publicados no bucket de artefatos.
# A Lambda db_migrate os lê e executa contra o RDS.
# ----------------------------------------------------------------------------

resource "aws_s3_object" "sql" {
  for_each = fileset(var.sql_dir, "*.sql")

  bucket       = awscc_s3_bucket.artifacts.bucket_name
  key          = "sql/${each.value}"
  source       = "${var.sql_dir}/${each.value}"
  etag         = filemd5("${var.sql_dir}/${each.value}")
  content_type = "application/sql"

  tags = {
    Name = each.value
  }
}
