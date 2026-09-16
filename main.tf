###############################################################################
# DriveGuard — módulo raiz
#
# Ordem de dependência real do apply:
#
#   build (pip)  ->  network  ->  storage  ->  database
#                                     |            |
#                                     +-> ingest   |
#                                     +-------------> etl (migra o schema)
#                                                  +-> dashboard
#                                                  +-> ml (opcional)
#                                                  +-> observability
###############################################################################

locals {
  build_dir = "${path.module}/build"

  # pathexpand("~") devolve "C:/Users/..." no Windows e "/home/..." no resto.
  is_windows = !startswith(pathexpand("~"), "/")

  # Muda quando qualquer .sql muda -> a migração roda de novo.
  sql_files = fileset("${path.module}/sql", "*.sql")
  sql_hash = sha1(join("", [
    for f in local.sql_files : filesha1("${path.module}/sql/${f}")
  ]))

  # Família do parameter group precisa casar com a major version do engine.
  db_parameter_group_family = "postgres${split(".", var.db_engine_version)[0]}"
}

# -----------------------------------------------------------------------------
# Empacotamento das Lambdas
#
# Roda pip install --target em lambdas/*/ e coloca o resultado em build/.
# Reexecuta quando qualquer handler, requirements ou o script de build mudar.
# -----------------------------------------------------------------------------

resource "null_resource" "build_lambdas" {
  triggers = {
    handlers = sha1(join("", [
      for f in fileset("${path.module}/lambdas", "**/*.py") :
      filesha1("${path.module}/lambdas/${f}")
    ]))
    requirements = sha1(join("", [
      for f in fileset("${path.module}/lambdas", "**/requirements.txt") :
      filesha1("${path.module}/lambdas/${f}")
    ]))
    script = filesha1(local.is_windows ? "${path.module}/scripts/build_lambdas.ps1" : "${path.module}/scripts/build_lambdas.sh")
  }

  # `interpreter` explícito em vez de uma string única: no Windows o
  # local-exec passa o comando por `cmd /C`, que engole as aspas do caminho e
  # falha com "Caracteres inválidos no caminho". Com a lista, o Terraform
  # executa o binário direto e o caminho chega inteiro.
  provisioner "local-exec" {
    interpreter = local.is_windows ? ["PowerShell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"] : ["bash"]
    command     = local.is_windows ? "${path.module}/scripts/build_lambdas.ps1" : "${path.module}/scripts/build_lambdas.sh"
    working_dir = path.module
  }
}

# -----------------------------------------------------------------------------
# Rede
# -----------------------------------------------------------------------------

module "network" {
  source = "./modules/network"

  name_prefix                    = local.name_prefix
  region                         = local.region
  vpc_cidr                       = var.vpc_cidr
  azs                            = local.azs
  public_subnet_cidrs            = var.public_subnet_cidrs
  private_subnet_cidrs           = var.private_subnet_cidrs
  enable_nat_gateway             = var.enable_nat_gateway
  enable_vpc_interface_endpoints = var.enable_vpc_interface_endpoints
  admin_cidrs                    = var.admin_cidrs
  dashboard_allowed_cidrs        = var.dashboard_allowed_cidrs
  db_publicly_accessible         = var.db_publicly_accessible
}

# -----------------------------------------------------------------------------
# Armazenamento (S3 Bronze + artefatos)
# -----------------------------------------------------------------------------

module "storage" {
  source = "./modules/storage"

  name_prefix           = local.name_prefix
  suffix                = random_id.suffix.hex
  region                = local.region
  tags                  = local.common_tags
  force_destroy         = var.force_destroy_buckets
  bronze_retention_days = var.bronze_retention_days
  sql_dir               = "${path.module}/sql"
}

# -----------------------------------------------------------------------------
# Banco (RDS PostgreSQL — camadas Silver e Gold)
# -----------------------------------------------------------------------------

module "database" {
  source = "./modules/database"

  name_prefix            = local.name_prefix
  subnet_ids             = module.network.database_subnet_ids
  security_group_id      = module.network.database_security_group_id
  engine_version         = var.db_engine_version
  parameter_group_family = local.db_parameter_group_family
  instance_class         = var.db_instance_class
  db_name                = var.db_name
  username               = var.db_username
  allocated_storage      = var.db_allocated_storage
  max_allocated_storage  = var.db_max_allocated_storage
  backup_retention_days  = var.db_backup_retention_days
  multi_az               = var.db_multi_az
  publicly_accessible    = var.db_publicly_accessible
  deletion_protection    = var.db_deletion_protection
  skip_final_snapshot    = true
}

# -----------------------------------------------------------------------------
# Ingestão (API Gateway + Lambda)
# -----------------------------------------------------------------------------

module "ingest" {
  source = "./modules/ingest"

  name_prefix     = local.name_prefix
  build_dir       = local.build_dir
  lambda_role_arn = local.lambda_role_arn
  lambda_runtime  = var.lambda_runtime

  bronze_bucket = module.storage.bronze_bucket_id

  stage_name           = var.api_stage_name
  throttle_rate_limit  = var.api_throttle_rate_limit
  throttle_burst_limit = var.api_throttle_burst_limit
  quota_limit          = var.api_quota_limit
  enable_access_logs   = var.enable_apigw_access_logs
  log_retention_days   = var.lambda_log_retention_days

  depends_on = [null_resource.build_lambdas]
}

# -----------------------------------------------------------------------------
# ETL (Silver, Gold e migração do schema)
# -----------------------------------------------------------------------------

module "etl" {
  source = "./modules/etl"

  name_prefix     = local.name_prefix
  account_id      = local.account_id
  build_dir       = local.build_dir
  lambda_role_arn = local.lambda_role_arn
  lambda_runtime  = var.lambda_runtime

  private_subnet_ids       = module.network.private_subnet_ids
  lambda_security_group_id = module.network.lambda_security_group_id

  bronze_bucket     = module.storage.bronze_bucket_id
  bronze_bucket_arn = module.storage.bronze_bucket_arn
  artifacts_bucket  = module.storage.artifacts_bucket_id

  db_host     = module.database.address
  db_port     = module.database.port
  db_name     = module.database.db_name
  db_username = module.database.username
  db_password = module.database.password

  gold_schedule       = var.etl_gold_schedule
  log_retention_days  = var.lambda_log_retention_days
  reserve_concurrency = var.lambda_reserve_concurrency

  run_migrations = var.run_migrations_on_apply
  seed_demo_data = var.seed_demo_data
  sql_hash       = local.sql_hash

  depends_on = [
    null_resource.build_lambdas,
    module.storage,
    module.database,
  ]
}

# -----------------------------------------------------------------------------
# Dashboard (EC2)
# -----------------------------------------------------------------------------

module "dashboard" {
  source = "./modules/dashboard"
  count  = var.enable_dashboard ? 1 : 0

  name_prefix  = local.name_prefix
  project_name = var.project_name
  environment  = var.environment
  region       = local.region

  instance_type         = var.dashboard_instance_type
  subnet_id             = module.network.public_subnet_ids[0]
  security_group_id     = module.network.dashboard_security_group_id
  instance_profile_name = local.ec2_instance_profile_name
  key_pair_name         = var.dashboard_key_pair_name
  root_volume_gb        = var.dashboard_root_volume_gb

  ssm_uri_parameter = module.database.ssm_uri_parameter
  repo_url          = var.dashboard_repo_url
  repo_subdir       = var.dashboard_repo_subdir
}

# -----------------------------------------------------------------------------
# Machine Learning (SageMaker) — opcional
# -----------------------------------------------------------------------------

module "ml" {
  source = "./modules/ml"
  count  = var.enable_sagemaker ? 1 : 0

  name_prefix      = local.name_prefix
  role_arn         = local.sagemaker_role_arn
  instance_type    = var.sagemaker_instance_type
  volume_gb        = var.sagemaker_volume_gb
  artifacts_bucket = module.storage.artifacts_bucket_id
  bronze_bucket    = module.storage.bronze_bucket_id
}

# -----------------------------------------------------------------------------
# Observabilidade
# -----------------------------------------------------------------------------

module "observability" {
  source = "./modules/observability"

  name_prefix = local.name_prefix
  region      = local.region
  alarm_email = var.alarm_email

  ingest_function_name     = module.ingest.lambda_function_name
  etl_silver_function_name = module.etl.etl_silver_function_name
  etl_gold_function_name   = module.etl.etl_gold_function_name
  dlq_name                 = module.etl.dlq_name

  db_instance_id             = module.database.instance_id
  monitor_dashboard_instance = var.enable_dashboard
  dashboard_instance_id      = var.enable_dashboard ? module.dashboard[0].instance_id : ""

  api_name  = module.ingest.api_name
  api_stage = var.api_stage_name

  bronze_bucket    = module.storage.bronze_bucket_id
  enable_dashboard = var.enable_cloudwatch_dashboard
}
