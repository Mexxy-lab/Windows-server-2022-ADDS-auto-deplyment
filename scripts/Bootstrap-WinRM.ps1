
# # Bootstrap-WinRM.ps1
# # Run locally inside the Windows guest as Administrator.

# $ErrorActionPreference = "Stop"

# $principal = New-Object Security.Principal.WindowsPrincipal(
#     [Security.Principal.WindowsIdentity]::GetCurrent()
# )

# if (-not $principal.IsInRole(
#     [Security.Principal.WindowsBuiltInRole]::Administrator
# )) {
#     throw "Run this script as Administrator."
# }

# # Enable PowerShell remoting and the WinRM service.
# Enable-PSRemoting -Force -SkipNetworkProfileCheck

# Set-Service -Name WinRM -StartupType Automatic
# Start-Service -Name WinRM

# # Use Negotiate/NTLM authentication for the isolated lab.
# Set-Item WSMan:\localhost\Service\Auth\Basic $false
# Set-Item WSMan:\localhost\Service\Auth\Negotiate $true
# Set-Item WSMan:\localhost\Service\AllowUnencrypted $false

# # Ensure the standard HTTP listener exists.
# $listener = Get-WSManInstance `
#     -ResourceURI winrm/config/Listener `
#     -Enumerate |
#     Where-Object {
#         $_.Transport -eq "HTTP" -and $_.Address -eq "*"
#     }

# if (-not $listener) {
#     New-WSManInstance `
#         -ResourceURI winrm/config/Listener `
#         -SelectorSet @{
#             Address   = "*"
#             Transport = "HTTP"
#         } `
#         -ValueSet @{}
# }

# # Enable the Windows firewall rule for WinRM.
# Enable-NetFirewallRule -DisplayGroup "Windows Remote Management"

# Write-Host "WinRM bootstrap completed."
# Write-Host "Verify that TCP 5985 is reachable from the WSL host."

# Bootstrap-WinRM.ps1
# Run locally on the Windows instance as Administrator.
# The AWS deployment script performs the initial password setup separately
# through Systems Manager and Secrets Manager.

$ErrorActionPreference = "Stop"
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw "Run this script as Administrator."
}
#Enable remoting and ensure WinRM starts automatically.
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM

#Use Negotiate/NTLM over HTTPS. Do not permit Basic or unencrypted transport.

Set-Item WSMan:\localhost\Service\Auth\Basic $false
Set-Item WSMan:\localhost\Service\Auth\Negotiate $true
Set-Item WSMan:\localhost\Service\AllowUnencrypted $false

# Create the HTTPS listener if it does not already exist.
$listener = Get-WSManInstance     -ResourceURI winrm/config/Listener
-Enumerate |
Where-Object {
$.Transport -eq "HTTPS" -and $.Address -eq "*"
} |
Select-Object -First 1
if (-not $listener) {
    $cert = New-SelfSignedCertificate `
        -DnsName $env:COMPUTERNAME `
        -CertStoreLocation "Cert:\LocalMachine\My" `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -NotAfter (Get-Date).AddYears(2)
New-WSManInstance         -ResourceURI winrm/config/Listener
-SelectorSet @ `
-ValueSet @{
Hostname               = $env:COMPUTERNAME
CertificateThumbprint  = $cert.Thumbprint
} | Out-Null
}

#Explicitly allow inbound HTTPS WinRM in the Windows firewall.
if (-not (Get-NetFirewallRule     -Name "WinRM-HTTPS-In-TCP"
-ErrorAction SilentlyContinue)) {
New-NetFirewallRule `
        -Name "WinRM-HTTPS-In-TCP" `
        -DisplayName "Windows Remote Management (HTTPS-In)" `
        -Enabled True `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort 5986 `
        -Action Allow `
        -Profile Any | Out-Null
}
Write-Host "WinRM HTTPS configuration completed."
Write-Host "Ansible should connect using TCP port 5986."