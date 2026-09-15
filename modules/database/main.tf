###############################################################################
# Módulo: database
#
# Amazon RDS PostgreSQL — hospeda as camadas Silver e Gold do Medallion:
#   schema silver : modelo OLTP normalizado (12 tabelas)
#   schema gold   : MATERIALIZED VIEWs mv_* consumidas pelo dashboard
#
# A senha é gerada pelo Terraform e guardada no SSM Parameter Store como
# SecureString (KMS gerenciado pela AWS, sem custo adicional). O Parameter
# Store foi escolhido em vez do Secrets Manager porque parâmetros Standard
# são gratuitos — no Secrets Manager cada segredo custa US$0,40/mês, o que
# pesa no budget de US$100 do Learner Lab.
###############################################################################

resource "random_password" "db" {
  length  = 24
  special = true
  # O RDS rejeita '/', '@', '"' e espaço na senha master.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_db_subnet_group" "this" {
  name        = "${var.name_prefix}-db-subnet-group"
  description = "Subnets do RDS PostgreSQL do DriveGuard"
  subnet_ids  = var.subnet_ids

  tags = {
    Name = "${var.name_prefix}-db-subnet-group"
  }
}

# Parameter group dedicado: força SSL e liga o log de statements lentos,
# usado na análise de desempenho das consultas do dashboard.
resource "aws_db_parameter_group" "this" {
  name        = "${var.name_prefix}-pg16"
  family      = var.parameter_group_family
  description = "Parametros do PostgreSQL do DriveGuard"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.name_prefix}-pg16"
  }
}

resource "aws_db_instance" "this" {
  identifier = "${var.name_prefix}-postgres"

  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.username
  password = random_password.db.result
  port     = 5432

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage > 0 ? var.max_allocated_storage : null
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = var.publicly_accessible
  multi_az               = var.multi_az

  parameter_group_name = aws_db_parameter_group.this.name

  backup_retention_period = var.backup_retention_days
  backup_window           = "06:00-07:00"
  maintenance_window      = "Mon:07:30-Mon:08:30"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  deletion_protection        = var.deletion_protection

  # No Learner Lab o ambiente é efêmero: pular o snapshot final acelera o
  # destroy e evita custo de armazenamento de snapshot órfão.
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  # Performance Insights e Enhanced Monitoring exigem role própria e geram
  # custo; ficam desligados no ambiente do TCC.
  performance_insights_enabled = false
  monitoring_interval          = 0

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  apply_immediately = true

  tags = {
    Name          = "${var.name_prefix}-postgres"
    MedallionTier = "silver-gold"
  }

  lifecycle {
    ignore_changes = [final_snapshot_identifier]
  }
}

# ----------------------------------------------------------------------------
# Credenciais no SSM Parameter Store
# ----------------------------------------------------------------------------

resource "aws_ssm_parameter" "db_password" {
  name        = "/${var.name_prefix}/rds/password"
  description = "Senha master do RDS PostgreSQL do DriveGuard"
  type        = "SecureString"
  value       = random_password.db.result

  tags = {
    Name = "${var.name_prefix}-rds-password"
  }
}

resource "aws_ssm_parameter" "db_endpoint" {
  name        = "/${var.name_prefix}/rds/endpoint"
  description = "Endpoint do RDS PostgreSQL do DriveGuard"
  type        = "String"
  value       = aws_db_instance.this.address

  tags = {
    Name = "${var.name_prefix}-rds-endpoint"
  }
}

resource "aws_ssm_parameter" "db_uri" {
  name        = "/${var.name_prefix}/rds/uri"
  description = "URI de conexao completa (usada pelo dashboard na EC2)"
  type        = "SecureString"
  value       = "postgresql://${var.username}:${urlencode(random_password.db.result)}@${aws_db_instance.this.address}:${aws_db_instance.this.port}/${var.db_name}?sslmode=require"

  tags = {
    Name = "${var.name_prefix}-rds-uri"
  }
}
