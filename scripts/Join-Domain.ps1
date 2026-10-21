[CmdletBinding()]
param(
    [string]$DomainName = "pumejlab.com",
    [string]$DomainAdminUser = "PUMEJLAB\Administrator",
    [Parameter(Mandatory = $true)]
    [string]$DomainAdminPassword,
    [string]$DnsServer = "10.20.0.1",
    [string]$InternalNetworkPrefix = "10.20.0."
)

$ErrorActionPreference = "Stop"

# Find the adapter connected to the internal lab network.
$internalIP = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object {
        $_.IPAddress.StartsWith($InternalNetworkPrefix) -and
        $_.IPAddress -notlike "127.*"
    } |
    Select-Object -First 1

if (-not $internalIP) {
    throw "No IPv4 address found on the internal lab network ($InternalNetworkPrefix*). Check the VM network adapter and DHCP configuration."
}

$adapter = Get-NetAdapter -InterfaceIndex $internalIP.InterfaceIndex

Write-Output "Internal adapter: $($adapter.Name)"
Write-Output "Internal address: $($internalIP.IPAddress)"

# The client must use the AD DNS server to locate the domain.
Set-DnsClientServerAddress `
    -InterfaceIndex $internalIP.InterfaceIndex `
    -ServerAddresses $DnsServer

Clear-DnsClientCache

# Verify that the domain can be discovered before attempting the join.
$domainInfo = Get-ADDomain -Server $DnsServer -ErrorAction SilentlyContinue

# Get-ADDomain may not be available on a Windows client without RSAT,
# so use DNS SRV discovery as the primary domain discovery check.
$domainControllerRecords = Resolve-DnsName `
    -Name "_ldap._tcp.dc._msdcs.$DomainName" `
    -Type SRV `
    -Server $DnsServer `
    -ErrorAction SilentlyContinue

if (-not $domainControllerRecords) {
    throw "Cannot locate domain controllers for $DomainName through DNS server $DnsServer. Verify AD DS and DNS on the domain controller."
}

$computerSystem = Get-CimInstance Win32_ComputerSystem

if ($computerSystem.PartOfDomain -and
    $computerSystem.Domain -ieq $DomainName) {
    Write-Output "Computer is already joined to $DomainName."
    $Ansible.Changed = $false
    return
}

$securePassword = ConvertTo-SecureString `
    $DomainAdminPassword -AsPlainText -Force

$credential = [System.Management.Automation.PSCredential]::new(
    $DomainAdminUser,
    $securePassword
)

Add-Computer `
    -DomainName $DomainName `
    -Credential $credential `
    -ErrorAction Stop

$Ansible.Changed = $true
Write-Output "Domain join initiated for $DomainName. Ansible should reboot the client."