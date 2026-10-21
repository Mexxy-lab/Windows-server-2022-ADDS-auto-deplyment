
locals {
  vm_definitions = merge(
    {
      dc01 = {
        name          = "DC01"
        private_ip    = "10.20.1.10"
        computer_name = "DC01"
      }
    },
    var.deploy_client ? {
      client01 = {
        name          = "WIN-CLIENT-01"
        private_ip    = "10.20.1.20"
        computer_name = "WIN-CLIENT-01"
      }
    } : {}
  )
}

resource "azurerm_public_ip" "vm" {
  for_each = local.vm_definitions

  name                = "${var.project_name}-${each.key}-pip"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "vm" {
  for_each = local.vm_definitions

  name                = "${var.project_name}-${each.key}-nic"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags                = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.lab.id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.private_ip
    public_ip_address_id          = azurerm_public_ip.vm[each.key].id
  }
}

resource "azurerm_network_interface_security_group_association" "vm" {
  for_each = local.vm_definitions

  network_interface_id      = azurerm_network_interface.vm[each.key].id
  network_security_group_id = azurerm_network_security_group.lab.id
}

resource "azurerm_windows_virtual_machine" "vm" {
  for_each = local.vm_definitions

  name                = each.value.name
  computer_name       = each.value.computer_name
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = var.admin_password

  network_interface_ids = [
    azurerm_network_interface.vm[each.key].id
  ]

  provision_vm_agent = true
  #   enable_automatic_updates   = true
  patch_mode            = "AutomaticByPlatform"
  patch_assessment_mode = "AutomaticByPlatform"

  # Initial baseline: Windows Server 2022 on both VMs.
  # A Windows 11 client requires a separate image/licensing design.
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition-smalldisk"
    version   = "latest"
  }

  os_disk {
    name                 = "${var.project_name}-${each.key}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  identity {
    type = "SystemAssigned"
  }

  boot_diagnostics {}

  tags = var.tags
}
