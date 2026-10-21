
variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "East US"
}

variable "resource_group_name" {
  description = "Resource group for the AD lab"
  type        = string
  default     = "pumej-ad-lab-rg"
}

variable "project_name" {
  description = "Prefix for resource names"
  type        = string
  default     = "pumej-ad"
}

variable "domain_name" {
  description = "Active Directory DNS domain"
  type        = string
  default     = "pumejlab.com"
}

variable "netbios_name" {
  description = "Active Directory NetBIOS name"
  type        = string
  default     = "PUMEJLAB"
}

variable "vnet_address_space" {
  type    = list(string)
  default = ["10.20.0.0/16"]
}

variable "subnet_address_prefix" {
  type    = string
  default = "10.20.1.0/24"
}

variable "admin_cidr" {
  description = "Your trusted public IP/CIDR, for example 203.0.113.10/32"
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_cidr))
    error_message = "admin_cidr must be a valid IPv4 CIDR."
  }
}

variable "deploy_client" {
  description = "Whether to deploy a second Windows VM"
  type        = bool
  default     = true
}

variable "vm_size" {
  description = "Azure VM size"
  type        = string
  default     = "Standard_D2s_v5"
}

variable "admin_username" {
  description = "Local Windows administrator username"
  type        = string
  default     = "labadmin"
}

variable "admin_password" {
  description = "Local Windows administrator password"
  type        = string
  sensitive   = true
}

variable "os_disk_size_gb" {
  description = "OS disk size"
  type        = number
  default     = 60
}

variable "tags" {
  type = map(string)

  default = {
    Project     = "Windows-AD-Lab"
    Environment = "prod"
    ManagedBy   = "Terraform"
  }
}
