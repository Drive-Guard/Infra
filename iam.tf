###############################################################################
# IAM — criado apenas quando iam_mode = "self_managed"
#
# No AWS Academy Learner Lab estas roles NÃO são criadas: a conta bloqueia
# iam:CreateRole e obriga o uso da LabRole pré-existente (ver locals.tf).
# O bloco existe para que a mesma base de código rode numa conta AWS real com
# permissões mínimas por serviço, e para documentar no TCC exatamente quais
# permissões a solução exige.
###############################################################################

locals {
  criar_iam = var.iam_mode == "self_managed"
}

# -----------------------------------------------------------------------------
# Role das Lambdas
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  count = local.criar_iam ? 1 : 0

  name               = "${local.name_prefix}-lambda-role"
  description        = "Execucao das Lambdas de ingestao e ETL do DriveGuard"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json

  tags = {
    Name = "${local.name_prefix}-lambda-role"
  }
}

# Logs + ENI na VPC. A permissão de ENI é da própria Lambda (ec2:*NetworkInterface)
# e, por limitação do IAM, não aceita restrição por recurso.
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  count = local.criar_iam ? 1 : 0

  role       = aws_iam_role.lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "lambda_inline" {
  count = local.criar_iam ? 1 : 0

  statement {
    sid    = "BronzeLeituraEscrita"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      module.storage.bronze_bucket_arn,
      "${module.storage.bronze_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "ArtefatosLeitura"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      module.storage.artifacts_bucket_arn,
      "${module.storage.artifacts_bucket_arn}/*",
    ]
  }

  statement {
    sid       = "DeadLetterQueue"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [module.etl.dlq_arn]
  }

  statement {
    sid       = "MetricasCustomizadas"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["DriveGuard/ETL"]
    }
  }
}

resource "aws_iam_role_policy" "lambda_inline" {
  count = local.criar_iam ? 1 : 0

  name   = "${local.name_prefix}-lambda-policy"
  role   = aws_iam_role.lambda[0].id
  policy = data.aws_iam_policy_document.lambda_inline[0].json
}

# -----------------------------------------------------------------------------
# Role da EC2 do dashboard
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dashboard" {
  count = local.criar_iam && var.enable_dashboard ? 1 : 0

  name               = "${local.name_prefix}-dashboard-role"
  description        = "EC2 do dashboard DriveGuard"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Name = "${local.name_prefix}-dashboard-role"
  }
}

# Session Manager: dá shell na instância sem abrir a porta 22.
resource "aws_iam_role_policy_attachment" "dashboard_ssm" {
  count = local.criar_iam && var.enable_dashboard ? 1 : 0

  role       = aws_iam_role.dashboard[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "dashboard_inline" {
  count = local.criar_iam && var.enable_dashboard ? 1 : 0

  statement {
    sid    = "LerCredenciaisDoBanco"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [
      "arn:aws:ssm:${local.region}:${local.account_id}:parameter/${local.name_prefix}/*",
    ]
  }

  statement {
    sid       = "DecriptarSecureString"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.region}.amazonaws.com"]
    }
  }

  statement {
    sid       = "EnviarMetricasDoDashboard"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["DriveGuard/Dashboard"]
    }
  }
}

resource "aws_iam_role_policy" "dashboard_inline" {
  count = local.criar_iam && var.enable_dashboard ? 1 : 0

  name   = "${local.name_prefix}-dashboard-policy"
  role   = aws_iam_role.dashboard[0].id
  policy = data.aws_iam_policy_document.dashboard_inline[0].json
}

resource "aws_iam_instance_profile" "dashboard" {
  count = local.criar_iam && var.enable_dashboard ? 1 : 0

  name = "${local.name_prefix}-dashboard-profile"
  role = aws_iam_role.dashboard[0].name

  tags = {
    Name = "${local.name_prefix}-dashboard-profile"
  }
}

# -----------------------------------------------------------------------------
# Role do SageMaker
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "sagemaker_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["sagemaker.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sagemaker" {
  count = local.criar_iam && var.enable_sagemaker ? 1 : 0

  name               = "${local.name_prefix}-sagemaker-role"
  description        = "Notebook SageMaker de treino dos modelos do DriveGuard"
  assume_role_policy = data.aws_iam_policy_document.sagemaker_assume.json

  tags = {
    Name = "${local.name_prefix}-sagemaker-role"
  }
}

resource "aws_iam_role_policy_attachment" "sagemaker_full" {
  count = local.criar_iam && var.enable_sagemaker ? 1 : 0

  role       = aws_iam_role.sagemaker[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

data "aws_iam_policy_document" "sagemaker_inline" {
  count = local.criar_iam && var.enable_sagemaker ? 1 : 0

  statement {
    sid    = "DadosEModelos"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      module.storage.artifacts_bucket_arn,
      "${module.storage.artifacts_bucket_arn}/*",
      module.storage.bronze_bucket_arn,
      "${module.storage.bronze_bucket_arn}/*",
    ]
  }

  # Permite que o autostop por ociosidade desligue o próprio notebook.
  statement {
    sid       = "AutostopDoProprioNotebook"
    effect    = "Allow"
    actions   = ["sagemaker:StopNotebookInstance"]
    resources = ["arn:aws:sagemaker:${local.region}:${local.account_id}:notebook-instance/${local.name_prefix}-ml"]
  }
}

resource "aws_iam_role_policy" "sagemaker_inline" {
  count = local.criar_iam && var.enable_sagemaker ? 1 : 0

  name   = "${local.name_prefix}-sagemaker-policy"
  role   = aws_iam_role.sagemaker[0].id
  policy = data.aws_iam_policy_document.sagemaker_inline[0].json
}
