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
###############################################################################

locals {
  bronze_bucket_name    = "${var.name_prefix}-bronze-${var.suffix}"
  artifacts_bucket_name = "${var.name_prefix}-artifacts-${var.suffix}"
}

# ----------------------------------------------------------------------------
# Bucket Bronze
# ----------------------------------------------------------------------------

resource "aws_s3_bucket" "bronze" {
  bucket        = local.bronze_bucket_name
  force_destroy = var.force_destroy

  tags = {
    Name          = local.bronze_bucket_name
    MedallionTier = "bronze"
  }
}

resource "aws_s3_bucket_public_access_block" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "bronze" {
  bucket = aws_s3_bucket.bronze.id

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
}

# Impede qualquer escrita sem TLS.
resource "aws_s3_bucket_policy" "bronze" {
  bucket = aws_s3_bucket.bronze.id
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
      aws_s3_bucket.bronze.arn,
      "${aws_s3_bucket.bronze.arn}/*",
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

resource "aws_s3_bucket" "artifacts" {
  bucket        = local.artifacts_bucket_name
  force_destroy = var.force_destroy

  tags = {
    Name = local.artifacts_bucket_name
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

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
}

# ----------------------------------------------------------------------------
# Scripts SQL de migração publicados no bucket de artefatos.
# A Lambda db_migrate os lê e executa contra o RDS.
# ----------------------------------------------------------------------------

resource "aws_s3_object" "sql" {
  for_each = fileset(var.sql_dir, "*.sql")

  bucket       = aws_s3_bucket.artifacts.id
  key          = "sql/${each.value}"
  source       = "${var.sql_dir}/${each.value}"
  etag         = filemd5("${var.sql_dir}/${each.value}")
  content_type = "application/sql"

  tags = {
    Name = each.value
  }
}
