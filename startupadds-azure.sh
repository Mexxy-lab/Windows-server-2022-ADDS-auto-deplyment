#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$PROJECT_DIR/azure-ad-lab-terraform"

if [[ ! -f "$TERRAFORM_DIR/versions.tf" ||
      ! -f "$TERRAFORM_DIR/main.tf" ]]; then
    echo "[ERROR] Azure Terraform configuration not found:"
    echo "        $TERRAFORM_DIR"
    exit 1
fi

LOG_DIR="$PROJECT_DIR/logs"
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

LOG_FILE="$LOG_DIR/startupadds-azure-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

TFPLAN_FILE=""
VAULT_PLAIN_FILE=""
BOOTSTRAP_SECRET_FILE=""
PS_SCRIPT_FILE=""
ANSIBLE_INVENTORY=""

cleanup() {
    for file in \
        "$TFPLAN_FILE" \
        "$VAULT_PLAIN_FILE" \
        "$BOOTSTRAP_SECRET_FILE" \
        "$PS_SCRIPT_FILE" \
        "$ANSIBLE_INVENTORY"
    do
        [[ -z "$file" ]] || rm -f -- "$file"
    done
}
trap cleanup EXIT
trap 'rc=$?; echo "[ERROR] Failed at line $LINENO (exit $rc). Check $LOG_FILE."; exit "$rc"' ERR

echo "=================================================="
echo " Windows Active Directory DEPLOYMENT - AZURE"
echo " Started: $(date)"
echo " Repository: $PROJECT_DIR"
echo " Terraform: $TERRAFORM_DIR"
echo "=================================================="

# 1. Check required commands and project files.
for cmd in terraform az ansible-playbook ansible ansible-inventory \
           ansible-vault python3; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[ERROR] Required command not found: $cmd"
        exit 1
    }
done

if [[ -f "$PROJECT_DIR/.venv/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "$PROJECT_DIR/.venv/bin/activate"
fi

for file in \
    ansible.cfg requirements.yml inventory/hosts.ini \
    group_vars/windows.yml group_vars/vault.yml \
    playbooks/connection_test.yml playbooks/domain_controller.yml \
    playbooks/domain_users.yml playbooks/domain_client.yml \
    playbooks/validate_deployment.yml
do
    [[ -f "$PROJECT_DIR/$file" ]] || {
        echo "[ERROR] Required file missing: $file"
        exit 1
    }
done

VAULT_PASS_FILE="$HOME/.ansible_vault_pass"
[[ -r "$VAULT_PASS_FILE" ]] || {
    echo "[ERROR] Missing Ansible Vault password file: $VAULT_PASS_FILE"
    exit 1
}

ansible-vault view "$PROJECT_DIR/group_vars/vault.yml" \
    --vault-password-file "$VAULT_PASS_FILE" >/dev/null

echo "[OK] Ansible Vault decryption check passed."

# 2. Read required credentials from Ansible Vault.
# bootstrap_password is used by Terraform for the initial local VM account.
# domain_admin_password is used for the Administrator account and AD tasks.
VAULT_PLAIN_FILE="$(mktemp)"
chmod 600 "$VAULT_PLAIN_FILE"

ansible-vault view "$PROJECT_DIR/group_vars/vault.yml" \
    --vault-password-file "$VAULT_PASS_FILE" > "$VAULT_PLAIN_FILE"

python3 - "$VAULT_PLAIN_FILE" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    vault = yaml.safe_load(stream)

if not isinstance(vault, dict):
    raise SystemExit("Vault file must contain a YAML mapping.")

for key in ("bootstrap_password", "domain_admin_password", "dsrm_password"):
    value = vault.get(key)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"Required Vault variable is missing: {key}")

if "\n" in vault["domain_admin_password"] or "\r" in vault["domain_admin_password"]:
    raise SystemExit("domain_admin_password contains a newline.")
PY

# Validate the Windows domain administrator password before provisioning.
python3 - "$VAULT_PLAIN_FILE" <<'PY'
import string
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    vault = yaml.safe_load(stream)

password = vault["domain_admin_password"]

checks = {
    "length": 20 <= len(password) <= 64,
    "uppercase": any(c.isupper() for c in password),
    "lowercase": any(c.islower() for c in password),
    "digit": any(c.isdigit() for c in password),
    "symbol": any(c in string.punctuation for c in password),
    "no_whitespace": password == password.strip()
        and not any(c.isspace() for c in password),
    "ascii_only": password.isascii(),
    "no_account_or_domain_terms": not any(
        term in password.casefold()
        for term in ("administrator", "admin", "pumej", "pumejlab", "password")
    ),
}

failed = [name for name, passed in checks.items() if not passed]
if failed:
    raise SystemExit(
        "Windows password preflight failed: " + ", ".join(failed)
    )

print("[OK] Windows domain administrator password preflight passed.")
PY

# Do not export the VM password globally. It will be supplied only to the
# Terraform plan command below, using bootstrap_password from Ansible Vault.

# 3. Verify Azure CLI authentication and select the configured subscription.
echo "[INFO] Checking Azure authentication..."
az account show --output table

AZURE_SUBSCRIPTION_ID="$(
    python3 - "$TERRAFORM_DIR/terraform.tfvars" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])

if not path.is_file():
    raise SystemExit(f"[ERROR] Missing Terraform variables file: {path}")

content = path.read_text()

match = re.search(
    r'(?m)^\s*subscription_id\s*=\s*"([^"]+)"\s*(?:#.*)?$',
    content,
)

if not match or not match.group(1).strip():
    raise SystemExit("[ERROR] subscription_id is missing or empty in terraform.tfvars")

print(match.group(1).strip())
PY
)"

if [[ -z "$AZURE_SUBSCRIPTION_ID" ]]; then
    echo "[ERROR] Could not read subscription_id from Terraform variables."
    echo "[ERROR] Ensure terraform.tfvars contains subscription_id."
    exit 1
fi

az account set --subscription "$AZURE_SUBSCRIPTION_ID"
az account show --query '{name:name,id:id,tenantId:tenantId}' --output table

# 4. Initialize, validate and plan Terraform.
cd "$TERRAFORM_DIR"

terraform init
terraform fmt -check -recursive
terraform validate

TFPLAN_FILE="$(mktemp "$TERRAFORM_DIR/tfplan.XXXXXX")"

# Read bootstrap_password into a non-exported shell variable, then pass it
# to Terraform only for the plan command. It is not hardcoded in this script
# or stored in terraform.tfvars. Protect the saved plan and Terraform state.
BOOTSTRAP_PASSWORD="$(
    python3 - "$VAULT_PLAIN_FILE" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    vault = yaml.safe_load(stream)

password = vault.get("bootstrap_password") if isinstance(vault, dict) else None
if not isinstance(password, str) or not password:
    raise SystemExit("ERROR: bootstrap_password is missing or empty in Ansible Vault.")
sys.stdout.write(password)
PY
)"

if [[ -z "$BOOTSTRAP_PASSWORD" ]]; then
    echo "[ERROR] bootstrap_password is empty; refusing to run Terraform plan."
    exit 1
fi

TF_VAR_admin_password="$BOOTSTRAP_PASSWORD" terraform plan -out="$TFPLAN_FILE"
unset BOOTSTRAP_PASSWORD

echo
echo "[WARNING] This plan may create billable Azure resources."
read -r -p "Apply this Azure plan? Type YES to continue: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
    echo "[INFO] Cancelled before Terraform apply."
    exit 0
fi

terraform apply "$TFPLAN_FILE"
rm -f -- "$TFPLAN_FILE"
TFPLAN_FILE=""

# 5. Read Azure Terraform outputs.
RESOURCE_GROUP="$(terraform output -raw resource_group_name)"
DC_PRIVATE_IP="$(terraform output -raw dc01_private_ip)"
DC_PUBLIC_IP="$(terraform output -raw dc01_public_ip)"
CLIENT_PRIVATE_IP="$(terraform output -raw client_private_ip)"
CLIENT_PUBLIC_IP="$(terraform output -raw client_public_ip)"

[[ "$CLIENT_PRIVATE_IP" == "null" ]] && CLIENT_PRIVATE_IP=""
[[ "$CLIENT_PUBLIC_IP" == "null" ]] && CLIENT_PUBLIC_IP=""

DOMAIN_NAME="$(terraform output -raw domain_name)"
NETBIOS_NAME="$(terraform output -raw netbios_name)"

echo "[OK] Azure resource group: $RESOURCE_GROUP"
echo "[OK] Domain: $DOMAIN_NAME"
echo "[OK] NetBIOS name: $NETBIOS_NAME"
echo "[OK] DC01 private IP: $DC_PRIVATE_IP"
echo "[OK] DC01 public IP:  $DC_PUBLIC_IP"

if [[ -n "$CLIENT_PUBLIC_IP" ]]; then
    echo "[OK] Windows client private IP: $CLIENT_PRIVATE_IP"
    echo "[OK] Windows client public IP:  $CLIENT_PUBLIC_IP"
else
    echo "[INFO] Optional Windows client is not deployed."
fi

# The Terraform password was scoped to the plan command and was not exported.

# 6. Create a temporary PowerShell bootstrap script.
# Azure VM Run Command executes this script inside the target Windows VM.
# The domain administrator password is read from Vault and inserted into
# a protected temporary file. Never echo this script or its contents.
PS_SCRIPT_FILE="$(mktemp)"
chmod 600 "$PS_SCRIPT_FILE"

python3 - "$VAULT_PLAIN_FILE" "$PS_SCRIPT_FILE" <<'PY'
import json
import sys
from pathlib import Path
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    vault = yaml.safe_load(stream)

password = vault["domain_admin_password"]

# JSON serialization produces a valid PowerShell double-quoted string
# for ordinary passwords and escapes embedded quotes and control characters.
password_literal = json.dumps(password)

script = r'''
$ErrorActionPreference = 'Stop'
$password = __PASSWORD_LITERAL__

try {
    $securePassword = ConvertTo-SecureString $password -AsPlainText -Force

    # Set the local built-in Administrator password before AD promotion.
    Set-LocalUser -Name 'Administrator' -Password $securePassword
    Enable-LocalUser -Name 'Administrator'

    Enable-PSRemoting -Force -SkipNetworkProfileCheck
    Set-Service -Name WinRM -StartupType Automatic
    Start-Service -Name WinRM

    Set-Item WSMan:\localhost\Service\Auth\Basic $false
    Set-Item WSMan:\localhost\Service\Auth\Negotiate $true
    Set-Item WSMan:\localhost\Service\AllowUnencrypted $false

    $listener = Get-WSManInstance `
        -ResourceURI winrm/config/Listener -Enumerate |
        Where-Object {
            $_.Transport -eq 'HTTPS' -and $_.Address -eq '*'
        } |
        Select-Object -First 1

    if (-not $listener) {
        $cert = New-SelfSignedCertificate `
            -DnsName $env:COMPUTERNAME `
            -CertStoreLocation 'Cert:\LocalMachine\My' `
            -KeyAlgorithm RSA -KeyLength 2048 `
            -NotAfter (Get-Date).AddYears(2)

        New-WSManInstance `
            -ResourceURI winrm/config/Listener `
            -SelectorSet @{ Address='*'; Transport='HTTPS' } `
            -ValueSet @{
                Hostname = $env:COMPUTERNAME
                CertificateThumbprint = $cert.Thumbprint
            } | Out-Null
    }

    if (-not (Get-NetFirewallRule -Name 'WinRM-HTTPS-In-TCP' `
        -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule `
            -Name 'WinRM-HTTPS-In-TCP' `
            -DisplayName 'WinRM HTTPS inbound' `
            -Enabled True -Direction Inbound `
            -Protocol TCP -LocalPort 5986 `
            -Action Allow -Profile Any | Out-Null
    }

    $password = $null
    $securePassword = $null

    Write-Output 'AZURE_WINRM_BOOTSTRAP_OK'
} catch {
    Write-Error $_
    exit 1
}
'''

script = script.replace("__PASSWORD_LITERAL__", password_literal)
Path(sys.argv[2]).write_text(script, encoding="utf-8")
PY

# 7. Bootstrap a VM with Azure Run Command.
# Requires the authenticated Azure identity to have VM run-command permissions.
bootstrap_vm() {
    local vm_name="$1"
    local attempt
    local output_file
    local rc

    output_file="$(mktemp)"
    chmod 600 "$output_file"

    echo "[INFO] Configuring local Administrator and WinRM HTTPS on $vm_name..."

    # Azure CLI sends the script to the VM. The password is not printed to
    # this log, but the temporary script and CLI request still contain it.
    # Use a trusted machine and restrict access to Azure activity/command logs.
    if az vm run-command invoke \
        --resource-group "$RESOURCE_GROUP" \
        --name "$vm_name" \
        --command-id RunPowerShellScript \
        --scripts "$(cat "$PS_SCRIPT_FILE")" \
        --output json > "$output_file"; then

        if grep -q "AZURE_WINRM_BOOTSTRAP_OK" "$output_file"; then
            echo "[OK] WinRM bootstrap succeeded on $vm_name."
            rm -f -- "$output_file"
            return 0
        fi

        echo "[WARN] Bootstrap returned without the expected success marker."
        cat "$output_file"
    else
        rc=$?
        echo "[WARN] Azure Run Command failed on $vm_name (exit $rc)."
        cat "$output_file"
    fi

    rm -f -- "$output_file"
    return 1
}

wait_for_winrm() {
    local host="$1"
    local label="$2"
    local attempt

    echo "[INFO] Waiting for WinRM HTTPS at ${host}:5986 ($label)..."

    for attempt in $(seq 1 60); do
        if python3 - "$host" 5986 <<'PY'
import socket
import sys

try:
    with socket.create_connection(
        (sys.argv[1], int(sys.argv[2])), timeout=5
    ):
        raise SystemExit(0)
except OSError:
    raise SystemExit(1)
PY
        then
            echo "[OK] TCP 5986 reachable for $label."
            return 0
        fi

        echo "[INFO] $label WinRM not ready ($attempt/60)."
        sleep 10
    done

    echo "[ERROR] WinRM HTTPS did not become reachable for $label."
    return 1
}

bootstrap_vm "DC01"
if [[ -n "$CLIENT_PUBLIC_IP" ]]; then
    bootstrap_vm "WIN-CLIENT-01"
fi

rm -f -- "$PS_SCRIPT_FILE"
PS_SCRIPT_FILE=""

# 8. Generate a temporary Ansible inventory.
ANSIBLE_INVENTORY="$(mktemp)"
chmod 600 "$ANSIBLE_INVENTORY"

cat > "$ANSIBLE_INVENTORY" <<EOF
[domain_controller]
dc01 ansible_host=$DC_PUBLIC_IP

[windows_clients]
EOF

if [[ -n "$CLIENT_PUBLIC_IP" ]]; then
    echo "windowsclient_01 ansible_host=$CLIENT_PUBLIC_IP" \
        >> "$ANSIBLE_INVENTORY"
fi

cat >> "$ANSIBLE_INVENTORY" <<'EOF'

[windows:children]
domain_controller
windows_clients

[windows:vars]
ansible_connection=winrm
ansible_port=5986
ansible_winrm_transport=ntlm
ansible_winrm_server_cert_validation=ignore
ansible_user=Administrator
EOF

cd "$PROJECT_DIR"

echo "[INFO] Installing required Ansible collections..."
ansible-galaxy collection install -r requirements.yml

inventory_graph="$(
    ansible-inventory -i "$ANSIBLE_INVENTORY" --graph
)" || {
    echo "[ERROR] Could not parse the generated Azure inventory."
    exit 1
}

echo "$inventory_graph"

grep -Eq 'dc01' <<< "$inventory_graph" || {
    echo "[ERROR] Inventory does not contain dc01."
    exit 1
}

if [[ -n "$CLIENT_PUBLIC_IP" ]] &&
   ! grep -Eq 'windowsclient_01' <<< "$inventory_graph"; then
    echo "[ERROR] Inventory does not contain windowsclient_01."
    exit 1
fi

# 9. Verify WinRM and authenticated Ansible connectivity.
wait_for_winrm "$DC_PUBLIC_IP" "DC01"

if [[ -n "$CLIENT_PUBLIC_IP" ]]; then
    wait_for_winrm "$CLIENT_PUBLIC_IP" "Windows client"
fi

echo "[INFO] Testing authenticated WinRM connectivity..."
ansible-playbook -i "$ANSIBLE_INVENTORY" \
    playbooks/connection_test.yml \
    --vault-password-file "$VAULT_PASS_FILE"

# 10. Promote DC01 to a domain controller.
echo "[INFO] Configuring Active Directory Domain Services..."
ansible-playbook -i "$ANSIBLE_INVENTORY" \
    playbooks/domain_controller.yml \
    --vault-password-file "$VAULT_PASS_FILE"

# 11. Reboot DC01 through Azure and wait for it to return.
echo "[INFO] Restarting DC01 through Azure..."
az vm restart \
    --resource-group "$RESOURCE_GROUP" \
    --name "DC01"

echo "[INFO] Waiting for DC01 to return to the running state..."
vm_ready=0

for attempt in $(seq 1 60); do
    power_state="$(
        az vm get-instance-view \
            --resource-group "$RESOURCE_GROUP" \
            --name "DC01" \
            --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" \
            --output tsv 2>/dev/null || true
    )"

    if [[ "$power_state" == "VM running" ]]; then
        vm_ready=1
        echo "[OK] DC01 is running."
        break
    fi

    echo "[INFO] DC01 state: ${power_state:-unknown} ($attempt/60)."
    sleep 10
done

if [[ "$vm_ready" -ne 1 ]]; then
    echo "[ERROR] DC01 did not return to the running state."
    exit 1
fi

wait_for_winrm "$DC_PUBLIC_IP" "DC01 after reboot"

# Recheck AD readiness using Azure Run Command. The check is repeated because
# Windows services may take time to start after AD DS promotion.
echo "[INFO] Waiting for AD DS, DNS, and the domain to become ready..."

ad_ready=0

for attempt in $(seq 1 30); do
    readiness_script="$(cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'

try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $domain = Get-ADDomain -ErrorAction Stop
    $services = Get-Service -Name NTDS, DNS, ADWS -ErrorAction Stop
    $stopped = @($services | Where-Object { $_.Status -ne 'Running' })

    if ($stopped.Count -eq 0) {
        Write-Output 'AZURE_AD_READY'
    } else {
        Write-Output 'AZURE_AD_WAIT'
    }
} catch {
    Write-Output 'AZURE_AD_WAIT'
}
POWERSHELL
)"

    readiness_output="$(
        az vm run-command invoke \
            --resource-group "$RESOURCE_GROUP" \
            --name "DC01" \
            --command-id RunPowerShellScript \
            --scripts "$readiness_script" \
            --query "value[0].message" \
            --output tsv 2>/dev/null || true
    )"

    if grep -q "AZURE_AD_READY" <<< "$readiness_output"; then
        ad_ready=1
        echo "[OK] AD DS and DNS are ready."
        break
    fi

    echo "[INFO] AD services are not ready yet ($attempt/30)."
    sleep 15
done

if [[ "$ad_ready" -ne 1 ]]; then
    echo "[ERROR] AD DS readiness check failed."
    echo "[ERROR] Check Azure Run Command output and the DC01 Windows event logs."
    exit 1
fi

# 12. Verify domain credentials after promotion.
echo "[INFO] Rechecking authenticated domain administrator access..."

ansible_ok=0

for attempt in $(seq 1 12); do
    if ansible-playbook -i "$ANSIBLE_INVENTORY" \
        playbooks/connection_test.yml \
        --limit dc01 \
        -e "ansible_user=${NETBIOS_NAME}\\Administrator" \
        --vault-password-file "$VAULT_PASS_FILE"; then
        ansible_ok=1
        break
    fi

    echo "[WARN] Post-reboot WinRM check failed ($attempt/12); retrying."
    sleep 20
done

if [[ "$ansible_ok" -ne 1 ]]; then
    echo "[ERROR] Authenticated WinRM access to DC01 did not recover."
    exit 1
fi

# 13. Create OUs and import users from the existing CSV/playbook workflow.
echo "[INFO] Creating OUs and importing domain users..."
ansible-playbook -i "$ANSIBLE_INVENTORY" \
    playbooks/domain_users.yml \
    --vault-password-file "$VAULT_PASS_FILE"

# 14. Join the optional Windows client.
# The client must use the domain controller for DNS. Ensure the Azure
# Terraform/VM configuration or an Azure-specific task sets that DNS server
# before attempting the domain join.
if [[ -n "$CLIENT_PUBLIC_IP" ]]; then
    echo "[INFO] Joining the Windows client to the domain..."
    ansible-playbook -i "$ANSIBLE_INVENTORY" \
        playbooks/domain_client.yml \
        --vault-password-file "$VAULT_PASS_FILE"
else
    echo "[INFO] Skipping client join; no client VM was deployed."
fi

# 15. Run final AD validation.
echo "[INFO] Running final Active Directory validation..."
ansible-playbook -i "$ANSIBLE_INVENTORY" \
    playbooks/validate_deployment.yml \
    --vault-password-file "$VAULT_PASS_FILE"

echo "=================================================="
echo "[SUCCESS] Azure deployment stages completed."
echo "Domain: $DOMAIN_NAME"
echo "Domain Controller private IP: $DC_PRIVATE_IP"
echo "Domain Controller public IP:  $DC_PUBLIC_IP"
echo "Windows Client private IP:    ${CLIENT_PRIVATE_IP:-not deployed}"
echo "Windows Client public IP:     ${CLIENT_PUBLIC_IP:-not deployed}"
echo "Resource group: $RESOURCE_GROUP"
echo "Log file: $LOG_FILE"
echo "Completed: $(date)"
echo "=================================================="
