###############################################################################
# Locals, data sources compartilhados e resolução de IAM
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Apenas AZs que suportam as classes de instância usadas no projeto.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# Sufixo aleatório: nomes de bucket S3 são globais e precisam ser únicos.
resource "random_id" "suffix" {
  byte_length = 3
}

# ----------------------------------------------------------------------------
# IAM: no Learner Lab as roles já existem e não podem ser criadas.
# ----------------------------------------------------------------------------

data "aws_iam_role" "lab" {
  count = var.iam_mode == "learner_lab" ? 1 : 0
  name  = var.lab_role_name
}

data "aws_iam_instance_profile" "lab" {
  count = var.iam_mode == "learner_lab" && var.enable_dashboard ? 1 : 0
  name  = var.lab_instance_profile_name
}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.region

  # Duas AZs: o RDS exige um subnet group com no mínimo duas.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  common_tags = merge(
    {
      Project     = "DriveGuard"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Owner       = var.owner
      Repository  = "Drive-Guard/Infra"
      CostCenter  = "TCC-2026"
    },
    var.extra_tags
  )

  # ARN da role usada por Lambda, EC2 e SageMaker.
  # learner_lab  -> LabRole (pré-existente)
  # self_managed -> roles criadas em iam.tf
  lambda_role_arn = (
    var.iam_mode == "learner_lab"
    ? data.aws_iam_role.lab[0].arn
    : aws_iam_role.lambda[0].arn
  )

  ec2_instance_profile_name = (
    var.iam_mode == "learner_lab"
    ? try(data.aws_iam_instance_profile.lab[0].name, var.lab_instance_profile_name)
    : try(aws_iam_instance_profile.dashboard[0].name, null)
  )

  sagemaker_role_arn = (
    var.iam_mode == "learner_lab"
    ? data.aws_iam_role.lab[0].arn
    : aws_iam_role.sagemaker[0].arn
  )
}
