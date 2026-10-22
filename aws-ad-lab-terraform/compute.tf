resource "aws_instance" "dc01" {
  ami                    = data.aws_ssm_parameter.windows_server_2022_ami.value
  instance_type          = var.dc_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.lab.id]
  iam_instance_profile   = aws_iam_instance_profile.lab.name
  # key_name                    = var.key_name
  private_ip                  = var.dc_private_ip
  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.root_volume_size_gib
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = merge(local.common_tags, {
    Name = "DC01"
    Role = "ActiveDirectoryDomainController"
  })
}

resource "aws_instance" "windows_client" {
  count = var.deploy_windows_client ? 1 : 0

  ami                         = data.aws_ssm_parameter.windows_server_2022_ami.value
  instance_type               = var.client_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.lab.id]
  iam_instance_profile        = aws_iam_instance_profile.lab.name
  private_ip                  = var.client_private_ip
  associate_public_ip_address = true

  root_block_device {
    volume_size           = var.root_volume_size_gib
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = merge(local.common_tags, {
    Name = "WIN-CLIENT-01"
    Role = "WindowsDomainClient"
  })
}
