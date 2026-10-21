# Configure-ADDS.ps1
param(
    [string]$DomainName = "pumejlab.com",
    [string]$DomainNetBIOSName = "PUMEJLAB",
    [string]$DSRMPassword
)

$ErrorActionPreference = "Stop"
$existingDomain = Get-CimInstance Win32_ComputerSystem
if ($existingDomain.Domain -eq $DomainName -and
    $existingDomain.PartOfDomain) {
    Write-Host "$DomainName already exists on this server."
    exit 0
}
if ($existingDomain.PartOfDomain) {
    throw "Server belongs to another domain. Refusing to promote."
}
if ([string]::IsNullOrWhiteSpace($DSRMPassword)) {
    $secureDSRM = Read-Host "Enter the DSRM password" -AsSecureString
} else {
    $secureDSRM = ConvertTo-SecureString `
        $DSRMPassword -AsPlainText -Force
}
Install-WindowsFeature AD-Domain-Services `
    -IncludeManagementTools
Import-Module ADDSDeployment
Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetBIOSName $DomainNetBIOSName `
    -InstallDNS `
    -SafeModeAdministratorPassword $secureDSRM `
    -NoRebootOnCompletion:$true `
    -Force
Write-Host "Domain controller promotion completed."
Write-Host "A reboot is required."
Restart-Computer -Force