###############################################################################
# Módulo: dashboard
#
# EC2 em subnet pública hospedando o dashboard DriveGuard (TanStack Start /
# Vite + React), atrás de nginx. O gestor de frota acessa pelo Elastic IP.
#
# O IP é elástico porque o Learner Lab para as instâncias ao fim de cada
# sessão; sem EIP o endereço mudaria a cada retomada e o link entregue na
# banca deixaria de funcionar.
###############################################################################

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  app_port = 3000

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    project_name      = var.project_name
    environment       = var.environment
    region            = var.region
    ssm_uri_parameter = var.ssm_uri_parameter
    repo_url          = var.repo_url
    repo_subdir       = var.repo_subdir
    app_port          = local.app_port
  })
}

resource "aws_instance" "dashboard" {
  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type
  subnet_id     = var.subnet_id
  key_name      = var.key_pair_name != "" ? var.key_pair_name : null

  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = var.instance_profile_name

  associate_public_ip_address = true

  user_data                   = local.user_data
  user_data_replace_on_change = true

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "${var.name_prefix}-dashboard-root"
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 obrigatório
    http_put_response_hop_limit = 2
  }

  monitoring = false

  tags = {
    Name  = "${var.name_prefix}-dashboard"
    Layer = "apresentacao"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

resource "aws_eip" "dashboard" {
  instance = aws_instance.dashboard.id
  domain   = "vpc"

  tags = {
    Name = "${var.name_prefix}-dashboard-eip"
  }
}
