terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  tags = merge(
    var.common_tags,
    {
      Name = var.instance_name
    }
  )

  selected_availability_zone = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.available.names[0]

  instance_versions_sorted = sort(tolist(var.instance_versions))
  latest_instance_version  = local.instance_versions_sorted[length(local.instance_versions_sorted) - 1]
}

resource "tls_private_key" "tfm" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "tfm" {
  key_name   = "${var.instance_name}-key"
  public_key = tls_private_key.tfm.public_key_openssh

  tags = merge(
    local.tags,
    {
      Resource = "keypair"
    }
  )
}

resource "local_file" "private_key" {
  content         = tls_private_key.tfm.private_key_pem
  filename        = "${path.module}/tfm-private-key.pem"
  file_permission = "0600"

  depends_on = [null_resource.windows_private_key_prewrite_acl]
}

resource "null_resource" "windows_private_key_prewrite_acl" {
  count = var.enable_windows_key_acl_fix ? 1 : 0

  triggers = {
    key_path = "${path.module}/tfm-private-key.pem"
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = "$keyPath = \"${replace(path.module, "/", "\\")}\\tfm-private-key.pem\"; if (Test-Path $keyPath) { attrib -r $keyPath; icacls $keyPath /inheritance:e /grant:r \"$($env:USERDOMAIN)\\$($env:USERNAME):(R,W)\" | Out-Null }"
  }
}

resource "null_resource" "windows_private_key_acl" {
  count = var.enable_windows_key_acl_fix ? 1 : 0

  triggers = {
    key_path = local_file.private_key.filename
    key_sha  = sha256(tls_private_key.tfm.private_key_pem)
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = "icacls \"${replace(local_file.private_key.filename, "/", "\\")}\" /inheritance:r /grant:r \"$($env:USERDOMAIN)\\$($env:USERNAME):(R,W)\" /remove:g \"BUILTIN\\Users\" \"NT AUTHORITY\\Authenticated Users\""
  }

  depends_on = [local_file.private_key]
}

data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = [var.canonical_owner]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(
    local.tags,
    {
      Resource = "vpc"
    }
  )
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(
    local.tags,
    {
      Resource = "igw"
    }
  )
}

resource "aws_subnet" "main" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.subnet_cidr
  availability_zone       = local.selected_availability_zone
  map_public_ip_on_launch = true

  tags = merge(
    local.tags,
    {
      Resource = "subnet"
    }
  )
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(
    local.tags,
    {
      Resource = "route-table"
    }
  )
}

resource "aws_route_table_association" "main" {
  subnet_id      = aws_subnet.main.id
  route_table_id = aws_route_table.main.id
}

resource "aws_security_group" "tfm" {
  name        = "${var.instance_name}-sg"
  description = "Security Group para instancia TFM"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_http_cidr]
  }

  ingress {
    description = "SSH"
    from_port   = var.ssh_port
    to_port     = var.ssh_port
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "Nginx NodePort"
    from_port   = 30080
    to_port     = 30080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_app_cidr]
  }

  ingress {
    description = "ArgoCD NodePort"
    from_port   = 30443
    to_port     = 30443
    protocol    = "tcp"
    cidr_blocks = [var.allowed_app_cidr]
  }

  ingress {
    description = "Prometheus UI"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.allowed_app_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    local.tags,
    {
      Resource = "security-group"
    }
  )
}

resource "aws_instance" "tfm" {
  for_each = var.instance_versions

  ami                         = data.aws_ami.ubuntu_2204.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.main.id
  vpc_security_group_ids      = [aws_security_group.tfm.id]
  key_name                    = aws_key_pair.tfm.key_name
  associate_public_ip_address = true
  user_data_replace_on_change = true
  user_data                   = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # Instalar dependencias base para bootstrap y analisis de resultados
    apt-get update -qq
    apt-get install -y -qq git python3 python3-pip

    # Paquetes Python para graficas/analisis (usados por experiments/pruebas_reales)
    python3 -m pip install --upgrade pip
    python3 -m pip install matplotlib pandas seaborn numpy

    # Cambia el puerto SSH en la primera configuracion de la instancia.
    sed -i -E 's/^#?Port[[:space:]]+[0-9]+/Port ${var.ssh_port}/' /etc/ssh/sshd_config
    if ! grep -qE '^Port[[:space:]]+${var.ssh_port}$' /etc/ssh/sshd_config; then
      echo "Port ${var.ssh_port}" >> /etc/ssh/sshd_config
    fi
    systemctl restart ssh
  EOF

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(
    local.tags,
    {
      Name       = "${var.instance_name}-${each.key}"
      Resource   = "ec2"
      Deployment = each.key
      CreatedAt  = each.key
      Latest     = tostring(each.key == local.latest_instance_version)
    }
  )

  lifecycle {
    ignore_changes = [key_name]
  }

  depends_on = [aws_internet_gateway.main]
}
