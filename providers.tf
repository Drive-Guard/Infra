###############################################################################
# Provider AWS
#
# No AWS Academy Learner Lab as credenciais são temporárias (access key +
# secret key + session token) e expiram a cada sessão do laboratório.
# Exporte-as como variáveis de ambiente antes do `terraform apply`:
#
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / AWS_SESSION_TOKEN
#
# ou use um profile do ~/.aws/credentials informando `aws_profile`.
###############################################################################

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = local.common_tags
  }
}

# Cloud Control API. Usado apenas para criar os buckets S3 — ver o cabecalho
# de modules/storage/main.tf para o motivo.
provider "awscc" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null
}
