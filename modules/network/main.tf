###############################################################################
# Módulo: network
#
# VPC 10.0.0.0/16 com duas camadas:
#   - Subnets públicas  : EC2 do dashboard (recebe tráfego do gestor de frota)
#   - Subnets privadas  : Lambdas de ETL e RDS PostgreSQL (sem rota para a
#                         internet; alcançam o S3 por Gateway Endpoint e o
#                         CloudWatch Logs por Interface Endpoint)
#
# O API Gateway é um serviço regional gerenciado (edge da AWS) — não vive
# dentro da VPC. Ele invoca a Lambda de ingestão pelo plano de controle da AWS.
###############################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# ----------------------------------------------------------------------------
# Subnets
# ----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-subnet-public-${var.azs[count.index]}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name = "${var.name_prefix}-subnet-private-${var.azs[count.index]}"
    Tier = "private"
  }
}

# ----------------------------------------------------------------------------
# Roteamento
# ----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.name_prefix}-rt-public"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway — opcional. Sem ele as subnets privadas não têm saída para a
# internet, o que é suficiente para este projeto (ver VPC Endpoints abaixo).
resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? length(var.public_subnet_cidrs) : 0
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}-eip-nat-${count.index}"
  }
}

resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? length(var.public_subnet_cidrs) : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${var.name_prefix}-nat-${count.index}"
  }

  depends_on = [aws_internet_gateway.this]
}

# Uma route table privada por AZ, para que cada subnet use o NAT da sua
# própria AZ quando ele estiver habilitado.
resource "aws_route_table" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name_prefix}-rt-private-${var.azs[count.index]}"
  }
}

resource "aws_route" "private_nat" {
  count = var.enable_nat_gateway ? length(var.private_subnet_cidrs) : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[count.index].id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# ----------------------------------------------------------------------------
# VPC Endpoints
#
# S3 (gateway)        : gratuito. Permite que as Lambdas privadas leiam/escrevam
#                       no Bronze e no bucket de artefatos sem NAT.
# CloudWatch (interface): ~US$0,01/h por ENI. Sem ele, uma Lambda em subnet
#                       privada sem NAT trava no envio de logs e só aparece o
#                       timeout, sem stack trace.
# ----------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(aws_route_table.private[*].id, [aws_route_table.public.id])

  tags = {
    Name = "${var.name_prefix}-vpce-s3"
  }
}

resource "aws_security_group" "vpc_endpoints" {
  count = var.enable_vpc_interface_endpoints ? 1 : 0

  name        = "${var.name_prefix}-sg-vpce"
  description = "Permite HTTPS das subnets privadas para os VPC Endpoints de interface"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS vindo da VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Saida irrestrita"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-sg-vpce"
  }
}

resource "aws_vpc_endpoint" "logs" {
  count = var.enable_vpc_interface_endpoints ? 1 : 0

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name_prefix}-vpce-logs"
  }
}

# ----------------------------------------------------------------------------
# Security Groups
# ----------------------------------------------------------------------------

# Lambdas de ETL. Sem ingress: elas só originam conexões.
resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-sg-lambda"
  description = "Lambdas de ETL em subnet privada"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "Saida para RDS, S3 e CloudWatch"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-sg-lambda"
  }
}

# EC2 do dashboard.
resource "aws_security_group" "dashboard" {
  name        = "${var.name_prefix}-sg-dashboard"
  description = "EC2 que hospeda o dashboard DriveGuard"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP do gestor de frota"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.dashboard_allowed_cidrs
  }

  ingress {
    description = "HTTPS do gestor de frota"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.dashboard_allowed_cidrs
  }

  dynamic "ingress" {
    for_each = length(var.admin_cidrs) > 0 ? [1] : []
    content {
      description = "SSH administrativo"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.admin_cidrs
    }
  }

  egress {
    description = "Saida irrestrita"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-sg-dashboard"
  }
}

# RDS. Só aceita 5432 vindo das Lambdas e da EC2 do dashboard.
resource "aws_security_group" "database" {
  name        = "${var.name_prefix}-sg-rds"
  description = "RDS PostgreSQL - acesso restrito as Lambdas e ao dashboard"
  vpc_id      = aws_vpc.this.id

  egress {
    description = "Saida irrestrita"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-sg-rds"
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_lambda" {
  security_group_id            = aws_security_group.database.id
  description                  = "PostgreSQL vindo das Lambdas de ETL"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.lambda.id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_dashboard" {
  security_group_id            = aws_security_group.database.id
  description                  = "PostgreSQL vindo da EC2 do dashboard"
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.dashboard.id
}

# Acesso administrativo direto ao banco (psql/DBeaver), apenas quando
# db_publicly_accessible = true e admin_cidrs foi preenchido.
resource "aws_vpc_security_group_ingress_rule" "db_from_admin" {
  count = var.db_publicly_accessible ? length(var.admin_cidrs) : 0

  security_group_id = aws_security_group.database.id
  description       = "PostgreSQL administrativo"
  from_port         = 5432
  to_port           = 5432
  ip_protocol       = "tcp"
  cidr_ipv4         = var.admin_cidrs[count.index]
}
