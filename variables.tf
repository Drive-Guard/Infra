###############################################################################
# Variáveis do módulo raiz
###############################################################################

# ----------------------------------------------------------------------------
# Identificação / Provider
# ----------------------------------------------------------------------------

variable "project_name" {
  description = "Prefixo usado no nome de todos os recursos."
  type        = string
  default     = "driveguard"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.project_name))
    error_message = "project_name deve ser minúsculo, começar com letra e ter entre 3 e 21 caracteres."
  }
}

variable "environment" {
  description = "Ambiente lógico (dev, hml, prod). Compõe o nome dos recursos."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "hml", "prod"], var.environment)
    error_message = "environment deve ser dev, hml ou prod."
  }
}

variable "aws_region" {
  description = "Região AWS. O Learner Lab permite apenas us-east-1 e us-west-2."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Profile do AWS CLI a usar. Vazio = usa variáveis de ambiente."
  type        = string
  default     = ""
}

variable "owner" {
  description = "Responsável pelo ambiente (tag Owner)."
  type        = string
  default     = "TCC-DriveGuard"
}

variable "extra_tags" {
  description = "Tags adicionais aplicadas a todos os recursos."
  type        = map(string)
  default     = {}
}

# ----------------------------------------------------------------------------
# IAM — Learner Lab vs. conta própria
# ----------------------------------------------------------------------------

variable "iam_mode" {
  description = <<-EOT
    Como as permissões são resolvidas:

      "learner_lab"  - NÃO cria roles. Reutiliza a role pré-existente do AWS
                       Academy (LabRole) e o instance profile LabInstanceProfile.
                       É o único modo que funciona no Learner Lab, onde
                       iam:CreateRole é negado.

      "self_managed" - Cria roles e policies dedicadas por serviço, com
                       permissões mínimas. Use em uma conta AWS própria.
  EOT
  type        = string
  default     = "learner_lab"

  validation {
    condition     = contains(["learner_lab", "self_managed"], var.iam_mode)
    error_message = "iam_mode deve ser learner_lab ou self_managed."
  }
}

variable "lab_role_name" {
  description = "Nome da role pré-existente do Learner Lab usada por Lambda/EC2/SageMaker."
  type        = string
  default     = "LabRole"
}

variable "lab_instance_profile_name" {
  description = "Instance profile pré-existente do Learner Lab usado pela EC2."
  type        = string
  default     = "LabInstanceProfile"
}

# ----------------------------------------------------------------------------
# Rede
# ----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "Bloco CIDR da VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs das subnets públicas (EC2 Dashboard). Uma por AZ."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs das subnets privadas (Lambdas ETL + RDS). Uma por AZ."
  type        = list(string)
  default     = ["10.0.2.0/24", "10.0.4.0/24"]
}

variable "enable_nat_gateway" {
  description = <<-EOT
    Cria NAT Gateway para dar saída à internet às subnets privadas.
    DESLIGADO por padrão: custa ~US$32/mês + tráfego, o que consome um terço
    do budget de US$100 do Learner Lab. A arquitetura foi desenhada para não
    precisar dele (ver enable_vpc_interface_endpoints).
  EOT
  type        = bool
  default     = false
}

variable "enable_vpc_interface_endpoints" {
  description = <<-EOT
    Cria VPC Endpoints de interface para CloudWatch Logs, permitindo que as
    Lambdas em subnet privada gravem log sem NAT Gateway.
    Custo ~US$0,01/h por ENI (uma por subnet privada).
    O endpoint gateway do S3 é sempre criado (é gratuito).
  EOT
  type        = bool
  default     = true
}

variable "admin_cidrs" {
  description = "CIDRs autorizados a acessar SSH (22) na EC2 do dashboard."
  type        = list(string)
  default     = []
}

variable "dashboard_allowed_cidrs" {
  description = "CIDRs autorizados a acessar o dashboard via HTTP/HTTPS."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ----------------------------------------------------------------------------
# Banco de dados (RDS PostgreSQL)
# ----------------------------------------------------------------------------

variable "db_engine_version" {
  description = "Versão do PostgreSQL no RDS."
  type        = string
  default     = "16.15"
}

variable "db_instance_class" {
  description = "Classe da instância RDS. db.t3.micro é elegível ao free tier."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Armazenamento inicial do RDS em GiB."
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Teto do autoscaling de storage do RDS em GiB. 0 desabilita."
  type        = number
  default     = 50
}

variable "db_name" {
  description = "Nome do banco de dados criado na instância."
  type        = string
  default     = "driveguard"
}

variable "db_username" {
  description = "Usuário master do RDS."
  type        = string
  default     = "dgadmin"
}

variable "db_backup_retention_days" {
  description = "Dias de retenção de backup automático do RDS."
  type        = number
  default     = 1
}

variable "db_multi_az" {
  description = "Habilita Multi-AZ no RDS. Dobra o custo; desligado no TCC."
  type        = bool
  default     = false
}

variable "db_deletion_protection" {
  description = "Impede destroy acidental do RDS."
  type        = bool
  default     = false
}

variable "db_publicly_accessible" {
  description = <<-EOT
    Coloca o RDS em subnet pública com IP roteável (ainda protegido por
    Security Group). Útil para inspecionar o banco a partir da sua máquina
    com psql/DBeaver. Em produção deve ser false.
  EOT
  type        = bool
  default     = false
}

variable "run_migrations_on_apply" {
  description = "Executa o DDL (silver + gold) automaticamente ao final do apply."
  type        = bool
  default     = true
}

variable "seed_demo_data" {
  description = "Popula o banco com dados sintéticos de demonstração após o DDL."
  type        = bool
  default     = true
}

# ----------------------------------------------------------------------------
# Ingestão (API Gateway + Lambda)
# ----------------------------------------------------------------------------

variable "api_stage_name" {
  description = "Nome do stage do API Gateway."
  type        = string
  default     = "v1"
}

variable "api_throttle_rate_limit" {
  description = "Requisições por segundo permitidas pelo usage plan."
  type        = number
  default     = 50
}

variable "api_throttle_burst_limit" {
  description = "Burst de requisições permitido pelo usage plan."
  type        = number
  default     = 100
}

variable "api_quota_limit" {
  description = "Cota de requisições por mês no usage plan."
  type        = number
  default     = 1000000
}

variable "enable_apigw_access_logs" {
  description = <<-EOT
    Habilita access log do API Gateway no CloudWatch. Exige que a conta tenha
    uma role configurada em `aws_api_gateway_account` (ajuste global da conta).
    Desligado por padrão para não conflitar com outros alunos do mesmo lab.
  EOT
  type        = bool
  default     = false
}

# ----------------------------------------------------------------------------
# ETL
# ----------------------------------------------------------------------------

variable "etl_gold_schedule" {
  description = "Expressão EventBridge que dispara o refresh das views Gold."
  type        = string
  default     = "rate(5 minutes)"
}

variable "lambda_runtime" {
  description = "Runtime Python das funções Lambda."
  type        = string
  default     = "python3.12"
}

variable "lambda_reserve_concurrency" {
  description = <<-EOT
    Reserva concorrência nas Lambdas de ETL para proteger o pool de conexões
    do RDS. A AWS exige que sobrem ao menos 100 de concorrência não reservada
    na conta; se o apply falhar com InvalidParameterValueException citando
    ReservedConcurrentExecutions, ponha false aqui.
  EOT
  type        = bool
  default     = true
}

variable "lambda_log_retention_days" {
  description = "Retenção dos log groups das Lambdas, em dias."
  type        = number
  default     = 14
}

# ----------------------------------------------------------------------------
# Dashboard (EC2)
# ----------------------------------------------------------------------------

variable "enable_dashboard" {
  description = "Provisiona a EC2 que hospeda o dashboard DriveGuard."
  type        = bool
  default     = true
}

variable "dashboard_instance_type" {
  description = "Tipo da instância EC2 do dashboard."
  type        = string
  default     = "t3.small"
}

variable "dashboard_key_pair_name" {
  description = <<-EOT
    Key pair para acesso SSH à EC2. No Learner Lab o par padrão chama-se
    "vockey". Deixe vazio para subir a instância sem chave.
  EOT
  type        = string
  default     = "vockey"
}

variable "dashboard_repo_url" {
  description = "Repositório Git do dashboard clonado pelo user_data da EC2."
  type        = string
  default     = "https://github.com/Drive-Guard/Site.git"
}

variable "dashboard_repo_subdir" {
  description = "Subdiretório do repositório onde está o package.json do dashboard."
  type        = string
  default     = "driveguard-codigo"
}

variable "dashboard_root_volume_gb" {
  description = "Tamanho do volume raiz (gp3) da EC2 do dashboard."
  type        = number
  default     = 20
}

# ----------------------------------------------------------------------------
# Machine Learning (SageMaker)
# ----------------------------------------------------------------------------

variable "enable_sagemaker" {
  description = <<-EOT
    Provisiona um SageMaker Notebook Instance para treino dos modelos.
    DESLIGADO por padrão: ml.t3.medium custa ~US$0,05/h e continua cobrando
    enquanto estiver "InService". Ligue só quando for treinar.
  EOT
  type        = bool
  default     = false
}

variable "sagemaker_instance_type" {
  description = "Tipo da instância do notebook SageMaker."
  type        = string
  default     = "ml.t3.medium"
}

variable "sagemaker_volume_gb" {
  description = "Volume EBS do notebook SageMaker em GiB."
  type        = number
  default     = 20
}

# ----------------------------------------------------------------------------
# Observabilidade
# ----------------------------------------------------------------------------

variable "alarm_email" {
  description = "E-mail inscrito no tópico SNS de alarmes. Vazio = sem inscrição."
  type        = string
  default     = ""
}

variable "enable_cloudwatch_dashboard" {
  description = "Cria um dashboard do CloudWatch com as métricas da solução."
  type        = bool
  default     = true
}

# ----------------------------------------------------------------------------
# Armazenamento
# ----------------------------------------------------------------------------

variable "bronze_retention_days" {
  description = "Dias até expirar objetos do bucket Bronze. 0 = nunca expira."
  type        = number
  default     = 365
}

variable "force_destroy_buckets" {
  description = <<-EOT
    Permite que `terraform destroy` apague buckets com objetos dentro.
    true no TCC para facilitar o teardown ao fim da sessão do lab.
  EOT
  type        = bool
  default     = true
}
