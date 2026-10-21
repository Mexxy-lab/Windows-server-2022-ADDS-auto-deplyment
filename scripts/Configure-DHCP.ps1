
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Configures DHCP on the Windows Server 2022 Active Directory server.

.DESCRIPTION
    - Installs the DHCP Server role and management tools.
    - Verifies the server's internal static IPv4 address.
    - Authorizes the DHCP server in Active Directory.
    - Creates and activates the internal IPv4 scope.
    - Configures DNS, domain name, and default gateway options.
    - Enables DNS dynamic updates.
    - Validates the final DHCP configuration.

.NOTES
    Run after AD DS promotion and DNS configuration.
    The internal network must be 10.20.0.0/24.
#>

[CmdletBinding()]
param(
    [string]$DomainName = "pumejlab.com",

    [string]$ServerIP = "10.20.0.1",

    [string]$ScopeNetwork = "10.20.0.0",

    [string]$StartRange = "10.20.0.50",

    [string]$EndRange = "10.20.0.200",

    [string]$SubnetMask = "255.255.255.0",

    [string]$DefaultGateway = "10.20.0.1",

    [string]$DnsServer = "10.20.0.1",

    [string]$ScopeName = "AD-Lab-Internal"
)

$ErrorActionPreference = "Stop"

Write-Output "============================================"
Write-Output " Windows Server DHCP Configuration"
Write-Output " Domain: $DomainName"
Write-Output " Server IP: $ServerIP"
Write-Output " DHCP scope: $ScopeNetwork"
Write-Output "============================================"

# --------------------------------------------------
# 1. Validate IP addresses and subnet configuration
# --------------------------------------------------

$parsedServerIP = $null
$parsedScopeNetwork = $null
$parsedStartRange = $null
$parsedEndRange = $null
$parsedSubnetMask = $null

foreach ($entry in @(
    @{ Name = "ServerIP"; Value = $ServerIP; Target = "server" },
    @{ Name = "ScopeNetwork"; Value = $ScopeNetwork; Target = "network" },
    @{ Name = "StartRange"; Value = $StartRange; Target = "start" },
    @{ Name = "EndRange"; Value = $EndRange; Target = "end" },
    @{ Name = "SubnetMask"; Value = $SubnetMask; Target = "mask" }
)) {
    $parsed = $null

    if (-not [System.Net.IPAddress]::TryParse(
        $entry.Value,
        [ref]$parsed
    )) {
        throw "Invalid IPv4 address for $($entry.Name): $($entry.Value)"
    }

    if ($parsed.AddressFamily -ne
        [System.Net.Sockets.AddressFamily]::InterNetwork) {
        throw "$($entry.Name) must be an IPv4 address."
    }

    switch ($entry.Target) {
        "server"  { $parsedServerIP = $parsed }
        "network" { $parsedScopeNetwork = $parsed }
        "start"   { $parsedStartRange = $parsed }
        "end"     { $parsedEndRange = $parsed }
        "mask"    { $parsedSubnetMask = $parsed }
    }
}

if ($parsedStartRange.Address -gt $parsedEndRange.Address) {
    throw "StartRange must not be greater than EndRange."
}

if ($ServerIP -eq $StartRange -or $ServerIP -eq $EndRange) {
    throw "The DHCP server address must not be a leased address."
}

if ($parsedSubnetMask.ToString() -ne "255.255.255.0") {
    throw "This lab script expects a /24 subnet mask."
}

if ($ScopeNetwork -ne "10.20.0.0") {
    throw "This lab script expects ScopeNetwork 10.20.0.0."
}

if ($ServerIP -ne $DnsServer) {
    Write-Warning "DHCP clients will use $DnsServer for DNS, not $ServerIP."
}

# --------------------------------------------------
# 2. Verify Active Directory domain membership
# --------------------------------------------------

$computerSystem = Get-CimInstance Win32_ComputerSystem

if (-not $computerSystem.PartOfDomain) {
    throw "This server is not domain joined. Configure AD DS first."
}

if ($computerSystem.Domain -ine $DomainName) {
    throw "Server domain '$($computerSystem.Domain)' does not match '$DomainName'."
}

$serverFqdn = "$env:COMPUTERNAME.$DomainName"

Write-Output "Domain membership verified: $serverFqdn"

# --------------------------------------------------
# 3. Verify the internal interface has a static IP
# --------------------------------------------------

$internalAddresses = @(
    Get-NetIPAddress `
        -AddressFamily IPv4 `
        -IPAddress $ServerIP `
        -ErrorAction SilentlyContinue
)

if ($internalAddresses.Count -eq 0) {
    throw "No interface has IP $ServerIP. Configure the internal NIC first."
}

if ($internalAddresses.Count -gt 1) {
    throw "Multiple interfaces have IP $ServerIP. Resolve the ambiguity."
}

$internalAddress = $internalAddresses[0]

if ($internalAddress.PrefixOrigin -ne "Manual") {
    Write-Warning "The internal address does not report a manual prefix origin. Confirm it is configured statically."
}

Write-Output "Internal interface verified: $ServerIP"

# --------------------------------------------------
# 4. Install the DHCP Server role
# --------------------------------------------------

$feature = Get-WindowsFeature -Name DHCP

if (-not $feature.Installed) {
    Write-Output "Installing DHCP Server role..."

    $installResult = Install-WindowsFeature `
        -Name DHCP `
        -IncludeManagementTools

    if (-not $installResult.Success) {
        throw "DHCP Server role installation failed."
    }

    if ($installResult.RestartNeeded -eq "Yes") {
        throw "A server restart is required before continuing. Reboot and rerun."
    }
} else {
    Write-Output "DHCP Server role is already installed."
}

Import-Module DHCPServer

# --------------------------------------------------
# 5. Authorize DHCP in Active Directory
# --------------------------------------------------

$authorizedServers = @(Get-DhcpServerInDC)

$authorized = $false

foreach ($authorizedServer in $authorizedServers) {
    $authorizedIP = $authorizedServer.IPAddress.IPAddressToString

    if ($authorizedIP -eq $ServerIP) {
        $authorized = $true
        break
    }
}

if (-not $authorized) {
    Write-Output "Authorizing DHCP server in Active Directory..."

    Add-DhcpServerInDC `
        -DnsName $serverFqdn `
        -IPAddress $ServerIP
} else {
    Write-Output "DHCP server is already authorized."
}

# --------------------------------------------------
# 6. Create or validate the DHCP scope
# --------------------------------------------------

$scope = Get-DhcpServerv4Scope `
    -ScopeId $ScopeNetwork `
    -ErrorAction SilentlyContinue

if (-not $scope) {
    Write-Output "Creating DHCP scope..."

    Add-DhcpServerv4Scope `
        -Name $ScopeName `
        -StartRange $StartRange `
        -EndRange $EndRange `
        -SubnetMask $SubnetMask `
        -State Active
} else {
    # Do not silently change an existing scope's address pool.
    $existingStart = $scope.StartRange.IPAddressToString
    $existingEnd = $scope.EndRange.IPAddressToString
    $existingMask = $scope.SubnetMask.IPAddressToString

    if (
        $existingStart -ne $StartRange -or
        $existingEnd -ne $EndRange -or
        $existingMask -ne $SubnetMask
    ) {
        throw "Existing DHCP scope has different range or mask. Review it manually."
    }

    Write-Output "Matching DHCP scope already exists."
}

Set-DhcpServerv4Scope `
    -ScopeId $ScopeNetwork `
    -State Active

# --------------------------------------------------
# 7. Configure DNS and gateway options
# --------------------------------------------------

Write-Output "Configuring DHCP client options..."

Set-DhcpServerv4OptionValue `
    -ScopeId $ScopeNetwork `
    -DnsServer $DnsServer `
    -DnsDomain $DomainName `
    -Router $DefaultGateway

# --------------------------------------------------
# 8. Configure dynamic DNS updates
# --------------------------------------------------

Set-DhcpServerv4DnsSetting `
    -DynamicUpdates Always `
    -DeleteDnsRRonLeaseExpiry $true

# --------------------------------------------------
# 9. Enable and start the DHCP service
# --------------------------------------------------

Set-Service -Name DHCPServer -StartupType Automatic

Start-Service -Name DHCPServer

$service = Get-Service -Name DHCPServer

if ($service.Status -ne "Running") {
    throw "DHCP Server service is not running."
}

# --------------------------------------------------
# 10. Validate and display configuration
# --------------------------------------------------

Write-Output ""
Write-Output "========== DHCP Scope =========="

Get-DhcpServerv4Scope -ScopeId $ScopeNetwork |
    Format-List ScopeId, Name, StartRange, EndRange,
                SubnetMask, State

Write-Output "========== DHCP Options =========="

Get-DhcpServerv4OptionValue -ScopeId $ScopeNetwork |
    Format-Table OptionId, Name, Value -AutoSize

Write-Output "========== DHCP Authorization =========="

Get-DhcpServerInDC |
    Where-Object {
        $_.IPAddress.IPAddressToString -eq $ServerIP
    } |
    Format-Table DnsName, IPAddress -AutoSize

Write-Output "========== DHCP Service =========="

Get-Service -Name DHCPServer |
    Format-Table Name, Status, StartType -AutoSize

Write-Output "DHCP configuration completed successfully."
