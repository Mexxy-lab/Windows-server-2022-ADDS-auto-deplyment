Vagrant.configure("2") do |config|

  config.vm.synced_folder ".", "/vagrant", disabled: true
  config.vm.define "dc01" do |dc|
    dc.vm.box = "StefanScherer/windows_2019"
    dc.vm.hostname = "DC01"
    dc.vm.boot_timeout = 900

    # Management interface for Ansible and RDP
    dc.vm.network "private_network",
      ip: "192.168.56.10"

    # Isolated domain network
    dc.vm.network "private_network",
      ip: "10.20.0.1",
      virtualbox__intnet: true

    dc.vm.provider "virtualbox" do |vb|
      vb.name = "Windows-AD-DC01"
      vb.memory = 4096
      vb.cpus = 2
    end
  end

  config.vm.define "win10-01" do |client|
    client.vm.box = "gusztavvargadr/windows-10"
    client.vm.hostname = "WIN10-01"

    # Management interface for Ansible
    client.vm.network "private_network",
      ip: "192.168.56.11"

    # Same isolated internal network as DC01
    client.vm.network "private_network",
      ip: "10.20.0.50",
      virtualbox__intnet: true

    client.vm.provider "virtualbox" do |vb|
      vb.name = "Windows-AD-WIN10-01"
      vb.memory = 4096
      vb.cpus = 2
    end
  end
end