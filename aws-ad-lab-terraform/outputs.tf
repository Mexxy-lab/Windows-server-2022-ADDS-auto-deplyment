output "aws_region" { value = var.aws_region }
output "domain_name" { value = var.domain_name }
output "dc01_public_ip" {
  description = "RDP address for DC01; security group restricts RDP to admin_cidr."
  value       = aws_instance.dc01.public_ip
}
output "dc01_private_ip" {
  description = "Use as client DNS server after AD DS/DNS is installed."
  value       = aws_instance.dc01.private_ip
}

output "bootstrap_secret_arn" {
  description = "Secrets Manager ARN for the Windows bootstrap credential."
  value       = aws_secretsmanager_secret.bootstrap.arn
}

output "network_strategy" {
  description = "Selected network deployment strategy."
  value       = var.network_strategy
}

output "dc01_instance_id" { value = aws_instance.dc01.id }
# output "windows_server_2022_ami_id" { value = data.aws_ssm_parameter.windows_server_2022_ami.value }
output "windows_client_public_ip" { value = try(aws_instance.windows_client[0].public_ip, null) }
output "windows_client_private_ip" { value = try(aws_instance.windows_client[0].private_ip, null) }
output "windows_client_instance_id" { value = try(aws_instance.windows_client[0].id, null) }
