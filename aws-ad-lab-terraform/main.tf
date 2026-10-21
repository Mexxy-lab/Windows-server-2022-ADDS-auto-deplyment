data "aws_availability_zones" "available" { state = "available" }

data "aws_ssm_parameter" "windows_server_2022_ami" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2022-English-Full-Base"
}

locals {
  common_tags = {
    Project     = var.project_name
    Environment = "lab"
    ManagedBy   = "Terraform"
  }
}

resource "aws_vpc" "lab" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.common_tags, { Name = "${var.project_name}-vpc" })
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = merge(local.common_tags, { Name = "${var.project_name}-igw" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.lab.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = merge(local.common_tags, { Name = "${var.project_name}-public-subnet" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
  tags = merge(local.common_tags, { Name = "${var.project_name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "lab" {
  name        = "${var.project_name}-sg"
  description = "RDP restricted to admin_cidr; lab instance traffic allowed only within this security group."
  vpc_id      = aws_vpc.lab.id

  ingress {
    description = "RDP from trusted administrator public IP only"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "WinRM HTTPS from trusted administrator IP only"
    from_port   = 5986
    to_port     = 5986
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Lab instance-to-instance traffic for AD DS, DNS, Kerberos, LDAP, SMB, RPC and domain join"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "Outbound for updates and DNS forwarding"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-sg" })
}
