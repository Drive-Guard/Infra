###############################################################################
# Módulo: ml
#
# SageMaker Notebook Instance para o treino dos modelos do TCC:
#   Caminho A — Feature Engineering + XGBoost/Random Forest sobre EAR, MAR,
#               PERCLOS, blink rate e head pose (modelo de produção).
#   Caminho B — YOLOv8n/YOLOv11n sobre o frame bruto (comparativo científico).
#
# Fica FORA da VPC, como os demais serviços regionais do desenho: o notebook
# precisa baixar pacotes do PyPI e datasets, e colocá-lo em subnet privada
# exigiria NAT Gateway (~US$32/mês).
#
# Desligado por padrão (enable_sagemaker = false): a instância cobra por hora
# enquanto estiver InService, mesmo ociosa. O lifecycle config abaixo instala
# um autostop por ociosidade como segunda linha de defesa do orçamento.
###############################################################################

locals {
  # Instala o autostop e exporta as variáveis que os notebooks usam para
  # localizar os buckets de dados e de modelos.
  on_start = <<-SCRIPT
    #!/bin/bash
    set -euo pipefail

    cat > /home/ec2-user/SageMaker/.driveguard_env <<'ENVFILE'
    export DRIVEGUARD_ARTIFACTS_BUCKET=${var.artifacts_bucket}
    export DRIVEGUARD_BRONZE_BUCKET=${var.bronze_bucket}
    export DRIVEGUARD_MODELS_PREFIX=modelos/
    export DRIVEGUARD_DATASETS_PREFIX=datasets/
    ENVFILE
    chown ec2-user:ec2-user /home/ec2-user/SageMaker/.driveguard_env

    echo '${base64encode(file("${path.module}/autostop.py"))}' | base64 -d > /usr/local/bin/driveguard-autostop.py
    chmod +x /usr/local/bin/driveguard-autostop.py

    cat > /etc/cron.d/driveguard-autostop <<'CRONFILE'
    IDLE_LIMIT_MINUTES=${var.idle_shutdown_minutes}
    */5 * * * * root /usr/bin/python3 /usr/local/bin/driveguard-autostop.py >> /var/log/driveguard-autostop.log 2>&1
    CRONFILE
    chmod 0644 /etc/cron.d/driveguard-autostop
  SCRIPT
}

resource "aws_sagemaker_notebook_instance_lifecycle_configuration" "this" {
  name     = "${var.name_prefix}-ml-lifecycle"
  on_start = base64encode(local.on_start)
}

resource "aws_sagemaker_notebook_instance" "this" {
  name          = "${var.name_prefix}-ml"
  role_arn      = var.role_arn
  instance_type = var.instance_type
  volume_size   = var.volume_gb

  # Nenhum dado sensível chega ao notebook — só features numéricas
  # anonimizadas — mas o volume é cifrado do mesmo jeito.
  direct_internet_access = "Enabled"
  root_access            = "Enabled"

  lifecycle_config_name = aws_sagemaker_notebook_instance_lifecycle_configuration.this.name

  tags = {
    Name  = "${var.name_prefix}-ml"
    Layer = "machine-learning"
  }
}
