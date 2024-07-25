resource "tls_private_key" "aws_ssh_key" {
  algorithm = "RSA"
}

resource "local_file" "private_key_pem" {
  content  = tls_private_key.aws_ssh_key.private_key_pem
  filename = local.private_key_filename
}

resource "null_resource" "chmod" {
  triggers = {
    key_data = local_file.private_key_pem.content
  }

  provisioner "local-exec" {
    command = "chmod 600 ${local.private_key_filename}"
  }
}

provider "aws" {
  region = var.aws_region
}

resource "aws_vpc" "hashidemos" {
  cidr_block           = var.address_space
  enable_dns_hostnames = true
}

resource "aws_subnet" "hashidemos" {
  cidr_block = var.subnet_prefix
  vpc_id     = aws_vpc.hashidemos.id
}

resource "aws_security_group" "hashidemos" {
  name   = "hashidemos-security-group"
  vpc_id = aws_vpc.hashidemos.id

  ingress {
    protocol    = "icmp"
    cidr_blocks = ["10.0.0.0/8"]
    from_port   = -1
    to_port     = -1
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed-source-ip]
  }

  ingress {
    from_port   = 4646
    to_port     = 4646
    protocol    = "tcp"
    cidr_blocks = [var.allowed-source-ip]
  }

  ingress {
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = [var.allowed-source-ip]
  }

  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["10.0.0.0/8"]
    prefix_list_ids = []
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
    prefix_list_ids = []
  }
}

resource "aws_internet_gateway" "hashidemos" {
  vpc_id = aws_vpc.hashidemos.id
}

resource "aws_route_table" "hashidemos" {
  vpc_id = aws_vpc.hashidemos.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hashidemos.id
  }
}

resource "aws_route_table_association" "hashidemos" {
  route_table_id = aws_route_table.hashidemos.id
  subnet_id      = aws_subnet.hashidemos.id
}

resource "aws_key_pair" "hashidemos" {
  key_name   = local.private_key_filename
  public_key = tls_private_key.aws_ssh_key.public_key_openssh
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_instance" "vault-server" {
  ami                         = data.aws_ami.ubuntu.id
  associate_public_ip_address = true
iam_instance_profile        = aws_iam_instance_profile.vault-server.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.hashidemos.key_name
  subnet_id                   = aws_subnet.hashidemos.id
  vpc_security_group_ids      = [aws_security_group.hashidemos.id]

  user_data = templatefile("${path.module}/templates/vault-server.tpl", {
    kms_key           = aws_kms_key.vault.id
    aws_region        = var.aws_region
    nomad_server_addr = aws_instance.nomad-server.private_ip
  })
}

resource "aws_instance" "nomad-server" {
  ami                         = data.aws_ami.ubuntu.id
  associate_public_ip_address = true
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.hashidemos.key_name
  subnet_id                   = aws_subnet.hashidemos.id
  vpc_security_group_ids      = [aws_security_group.hashidemos.id]

  user_data = templatefile("${path.module}/templates/nomad-server.tpl", {
    ssh_username = var.ssh_username
  })
}

resource "aws_instance" "nomad-client" {
  ami                         = data.aws_ami.ubuntu.id
  associate_public_ip_address = true
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.hashidemos.key_name
  subnet_id                   = aws_subnet.hashidemos.id
  vpc_security_group_ids      = [aws_security_group.hashidemos.id]

  user_data = templatefile("${path.module}/templates/nomad-client.tpl", {
    nomad_server_addr = aws_instance.nomad-server.private_ip
    ssh_username      = var.ssh_username
    vault_server_addr = aws_instance.vault-server.private_ip
  })
}

resource "aws_iam_instance_profile" "vault-server" {
  name = "vault-server-instance-profile"
  role = aws_iam_role.vault-server.name
}

resource "aws_iam_role" "vault-server" {
  name               = "vault-server-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_ec2.json
}

resource "aws_iam_role_policy" "vault-server" {
  name   = "vault-server-role-policy"
  role   = aws_iam_role.vault-server.id
  policy = data.aws_iam_policy_document.vault-server.json
}

data "aws_iam_policy_document" "assume_role_ec2" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "vault-server" {
  statement {
    sid    = "VaultKMSUnseal"
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]

    resources = [aws_kms_key.vault.arn]
  }
}

resource "aws_kms_key" "vault" {
  description             = "Vault unseal key"
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "vault" {
  name          = "alias/vault-kms-unseal-key"
  target_key_id = aws_kms_key.vault.key_id
}