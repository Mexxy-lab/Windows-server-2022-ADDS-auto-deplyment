
variable "aws_region" {
  type        = string
  description = "AWS Region for the lab."
  default     = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "pumej-ad-lab"
}

variable "domain_name" {
  type    = string
  default = "pumejlab.com"
}

variable "domain_netbios_name" {
  type    = string
  default = "PUMEJLAB"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.20.1.0/24"
}

variable "dc_private_ip" {
  type    = string
  default = "10.20.1.10"
}

variable "client_private_ip" {
  type    = string
  default = "10.20.1.20"
}

variable "admin_cidr" {
  type        = string
  description = "Your trusted public IP in CIDR format, e.g. 198.51.100.25/32."

  validation {
    condition     = can(cidrnetmask(var.admin_cidr))
    error_message = "Provide a valid IPv4 CIDR."
  }
}

# variable "key_name" {
#   type        = string
#   description = "Existing EC2 key pair name in the selected Region."
# }

variable "dc_instance_type" {
  type    = string
  default = "t3.large"
}

variable "client_instance_type" {
  type    = string
  default = "t3.large"
}

variable "deploy_windows_client" {
  type    = bool
  default = false
}

variable "windows_client_ami_id" {
  type    = string
  default = ""
}

variable "root_volume_size_gib" {
  type    = number
  default = 60
}

variable "network_strategy" {
  description = "Network design for the AD lab."
  type        = string
  default     = "shared_vpc"

  validation {
    condition = contains(
      ["shared_vpc", "routed"],
      var.network_strategy
    )
    error_message = "Choose shared_vpc or routed."
  }
}