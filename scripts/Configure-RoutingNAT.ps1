$ErrorActionPreference = "Stop"

$internalPrefix = "10.20.0.0/24"
$internalAddress = "10.20.0.1"

# Enable IPv4 forwarding on the internal interface.
$internalInterface = Get-NetIPAddress `
    -AddressFamily IPv4 `
    -IPAddress $internalAddress

Set-NetIPInterface `
    -InterfaceIndex $internalInterface.InterfaceIndex `
    -Forwarding Enabled

# Create the NAT rule if it does not already exist.
$existingNat = Get-NetNat -Name "ADLabNAT" `
    -ErrorAction SilentlyContinue

if (-not $existingNat) {
    New-NetNat `
        -Name "ADLabNAT" `
        -InternalIPInterfaceAddressPrefix $internalPrefix
}

Get-NetNat -Name "ADLabNAT"