
output "resource_group_name" {
  value = azurerm_resource_group.lab.name
}

output "location" {
  value = azurerm_resource_group.lab.location
}

output "domain_name" {
  value = var.domain_name
}

output "netbios_name" {
  value = var.netbios_name
}

output "vm_details" {
  value = {
    for key, vm in azurerm_windows_virtual_machine.vm : key => {
      name       = vm.name
      private_ip = azurerm_network_interface.vm[key].private_ip_address
      public_ip  = azurerm_public_ip.vm[key].ip_address
      vm_size    = vm.size
    }
  }
}

output "dc01_private_ip" {
  value = azurerm_network_interface.vm["dc01"].private_ip_address
}

output "dc01_public_ip" {
  value = azurerm_public_ip.vm["dc01"].ip_address
}

output "client_private_ip" {
  value = try(
    azurerm_network_interface.vm["client01"].private_ip_address,
    null
  )
}

output "client_public_ip" {
  value = try(
    azurerm_public_ip.vm["client01"].ip_address,
    null
  )
}
