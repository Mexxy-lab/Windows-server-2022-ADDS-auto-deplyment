#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

if [[ -f "$PROJECT_DIR/versions.tf" && -f "$PROJECT_DIR/main.tf" ]]; then
    TERRAFORM_DIR="$PROJECT_DIR"
elif [[ -f "$PROJECT_DIR/aws-ad-lab-terraform/versions.tf" &&
        -f "$PROJECT_DIR/aws-ad-lab-terraform/main.tf" ]]; then
    TERRAFORM_DIR="$PROJECT_DIR/aws-ad-lab-terraform"
else
    echo "[ERROR] Could not locate Terraform configuration."
    exit 1
fi

LOG_DIR="$PROJECT_DIR/logs"
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
LOG_FILE="$LOG_DIR/startupadds-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

ANSIBLE_INVENTORY=""
TFPLAN_FILE=""
VAULT_PLAIN_FILE=""
BOOTSTRAP_SECRET_FILE=""
SSM_SCRIPT_FILE=""
SSM_PARAMS_FILE=""

cleanup() {
    [[ -z "$ANSIBLE_INVENTORY" ]] || rm -f -- "$ANSIBLE_INVENTORY"
    [[ -z "$TFPLAN_FILE" ]] || rm -f -- "$TFPLAN_FILE"
    [[ -z "$VAULT_PLAIN_FILE" ]] || rm -f -- "$VAULT_PLAIN_FILE"
    [[ -z "$BOOTSTRAP_SECRET_FILE" ]] || rm -f -- "$BOOTSTRAP_SECRET_FILE"
    [[ -z "$SSM_SCRIPT_FILE" ]] || rm -f -- "$SSM_SCRIPT_FILE"
    [[ -z "$SSM_PARAMS_FILE" ]] || rm -f -- "$SSM_PARAMS_FILE"
}
trap cleanup EXIT
# shellcheck disable=SC2154
trap 'rc=$?; echo "[ERROR] Failed at line $LINENO (exit $rc). Check $LOG_FILE."; exit "$rc"' ERR

echo "=================================================="
echo " Windows Server 2022 Active Directory DEPLOYMENT - AWS"
echo " Started: $(date)"
echo " Repository: $PROJECT_DIR"
echo " Terraform: $TERRAFORM_DIR"
echo "=================================================="

# 1. Required commands and local configuration
for cmd in terraform aws ansible-playbook ansible ansible-inventory ansible-vault python3; do
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
    playbooks/domain_users.yml playbooks/network_services.yml \
    playbooks/domain_client.yml
do
    [[ -f "$PROJECT_DIR/$file" ]] || {
        echo "[ERROR] Required file missing: $file"
        exit 1
    }
done

# Use the Jenkins-provided vault password file when available.
# Otherwise, retain the existing local workstation behavior.
VAULT_PASS_FILE="${ANSIBLE_VAULT_PASSWORD_FILE:-$HOME/.ansible_vault_pass}"
[[ -r "$VAULT_PASS_FILE" ]] || {
    echo "[ERROR] Missing vault password file: $VAULT_PASS_FILE"
    exit 1
}

ansible-vault view "$PROJECT_DIR/group_vars/vault.yml" \
    --vault-password-file "$VAULT_PASS_FILE" >/dev/null
echo "[OK] Ansible Vault decryption check passed."

# Validate the Windows Administrator password before creating AWS resources.
python3 - "$PROJECT_DIR/group_vars/vault.yml" "$VAULT_PASS_FILE" <<'PY'
import subprocess
import sys
import string
import yaml

vault_file, vault_pass_file = sys.argv[1:3]

result = subprocess.run(
    [
        "ansible-vault", "view", vault_file,
        "--vault-password-file", vault_pass_file,
    ],
    capture_output=True,
    text=True,
    check=True,
)

vault = yaml.safe_load(result.stdout)
password = vault.get("domain_admin_password", "") if isinstance(vault, dict) else ""

checks = {
    "length": 20 <= len(password) <= 64,
    "uppercase": any(c.isupper() for c in password),
    "lowercase": any(c.islower() for c in password),
    "digit": any(c.isdigit() for c in password),
    "symbol": any(c in string.punctuation for c in password),
    "no_whitespace": bool(password) and password == password.strip()
        and not any(c.isspace() for c in password),
    "no_account_or_domain_terms": not any(
        term in password.casefold()
        for term in ("administrator", "admin", "pumej", "pumejlab", "password")
    ),
    "ascii_only": password.isascii(),
}

failed = [name for name, passed in checks.items() if not passed]

if failed:
    print("ERROR: Windows password preflight failed: " + ", ".join(failed))
    print("No AWS resources have been created by this run yet.")
    sys.exit(1)

print("Windows password preflight passed.")
PY

# 2. Check AWS credentials and validate Terraform
echo "[INFO] Checking AWS identity..."
aws sts get-caller-identity

# 2. Check AWS credentials and validate Terraform
echo "[INFO] Checking AWS identity..."
aws sts get-caller-identity

cd "$TERRAFORM_DIR"
terraform init
terraform fmt -check -recursive
terraform validate

TFPLAN_FILE="$(mktemp "$TERRAFORM_DIR/tfplan.XXXXXX")"
terraform plan -out="$TFPLAN_FILE"

echo
echo "[WARNING] Terraform may create billable AWS resources."

# Jenkins handles approval through its pipeline input step.
# Local executions retain the original interactive confirmation.
if [[ "${JENKINS_AUTO_APPROVE:-false}" == "true" ]]; then
    echo "[INFO] Jenkins deployment approval received."
    CONFIRM="YES"
else
    read -r -p "Apply this plan? Type YES to continue: " CONFIRM
fi

if [[ "$CONFIRM" != "YES" ]]; then
    echo "[INFO] Cancelled before Terraform apply."
    exit 0
fi

# Apply the exact Terraform plan generated earlier.
terraform apply "$TFPLAN_FILE"
rm -f -- "$TFPLAN_FILE"
TFPLAN_FILE=""

# 3. Read Terraform outputs
DC_PRIVATE_IP="$(terraform output -raw dc01_private_ip)"
DC_PUBLIC_IP="$(terraform output -raw dc01_public_ip)"
DC_INSTANCE_ID="$(terraform output -raw dc01_instance_id)"
SECRET_ARN="$(terraform output -raw bootstrap_secret_arn)"
AWS_REGION="$(terraform output -raw aws_region)"
DOMAIN_NAME="$(terraform output -raw domain_name)"
NETWORK_STRATEGY="$(terraform output -raw network_strategy)"

CLIENT_PRIVATE_IP="$(terraform output -raw windows_client_private_ip)"
CLIENT_PUBLIC_IP="$(terraform output -raw windows_client_public_ip)"
CLIENT_INSTANCE_ID="$(terraform output -raw windows_client_instance_id)"

[[ "$CLIENT_PRIVATE_IP" == "null" ]] && CLIENT_PRIVATE_IP=""
[[ "$CLIENT_PUBLIC_IP" == "null" ]] && CLIENT_PUBLIC_IP=""
[[ "$CLIENT_INSTANCE_ID" == "null" ]] && CLIENT_INSTANCE_ID=""

echo "[OK] DC01 private IP: $DC_PRIVATE_IP"
echo "[OK] DC01 public IP:  $DC_PUBLIC_IP"
echo "[OK] DC01 instance ID: $DC_INSTANCE_ID"
if [[ -n "$CLIENT_INSTANCE_ID" ]]; then
    echo "[OK] Windows client instance ID: $CLIENT_INSTANCE_ID"
else
    echo "[INFO] Optional Windows client is not deployed."
fi

# 4. Extract the final Administrator password from the encrypted vault.
# Temporary files are restricted and removed on exit. The password is not
# included in command arguments or printed to the log.
VAULT_PLAIN_FILE="$(mktemp)"
BOOTSTRAP_SECRET_FILE="$(mktemp)"
chmod 600 "$VAULT_PLAIN_FILE" "$BOOTSTRAP_SECRET_FILE"

ansible-vault view "$PROJECT_DIR/group_vars/vault.yml" \
    --vault-password-file "$VAULT_PASS_FILE" > "$VAULT_PLAIN_FILE"

python3 - "$VAULT_PLAIN_FILE" "$BOOTSTRAP_SECRET_FILE" <<'PY'
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    raise SystemExit("PyYAML is required in the active Python environment.")

vault = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
password = vault.get("domain_admin_password") if isinstance(vault, dict) else None

if not isinstance(password, str) or not password or "\n" in password or "\r" in password:
    raise SystemExit("domain_admin_password is missing or invalid in the encrypted vault.")

Path(sys.argv[2]).write_text(password, encoding="utf-8")
os.chmod(sys.argv[2], 0o600)
PY

echo "[INFO] Updating the Secrets Manager bootstrap secret..."
aws secretsmanager put-secret-value \
    --region "$AWS_REGION" \
    --secret-id "$SECRET_ARN" \
    --secret-string "file://$BOOTSTRAP_SECRET_FILE" >/dev/null

rm -f -- "$VAULT_PLAIN_FILE" "$BOOTSTRAP_SECRET_FILE"
VAULT_PLAIN_FILE=""
BOOTSTRAP_SECRET_FILE=""
echo "[OK] Bootstrap secret populated."

# 5. Wait for an EC2 instance to register with Systems Manager.
wait_for_ssm() {
    local instance_id="$1"
    local label="$2"
    local attempt
    local status

    echo "[INFO] Waiting for SSM Online: $label ($instance_id)"
    for attempt in $(seq 1 60); do
        status="$(aws ssm describe-instance-information \
            --region "$AWS_REGION" \
            --filters "Key=InstanceIds,Values=$instance_id" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text 2>/dev/null || true)"

        if [[ "$status" == "Online" ]]; then
            echo "[OK] $label is Online in SSM."
            return 0
        fi

        echo "[INFO] $label SSM status: ${status:-unknown} ($attempt/60)"
        sleep 10
    done

    echo "[ERROR] $label did not register with SSM."
    echo "[ERROR] Check its instance profile, SSM Agent, IAM permissions, and outbound HTTPS."
    return 1
}

# 6. Bootstrap Windows through SSM. The command contains the secret ARN,
# not the password. Windows retrieves the password using its EC2 instance role.
bootstrap_instance() {
    local instance_id="$1"
    local label="$2"
    local command_id
    local status
    local attempt

    wait_for_ssm "$instance_id" "$label"

    SSM_SCRIPT_FILE="$(mktemp)"
    SSM_PARAMS_FILE="$(mktemp)"
    chmod 600 "$SSM_SCRIPT_FILE" "$SSM_PARAMS_FILE"

    python3 - "$SSM_SCRIPT_FILE" "$SECRET_ARN" "$AWS_REGION" <<'PY'
import sys
from pathlib import Path

out_path, secret_arn, region = sys.argv[1:4]

script = r'''
$ErrorActionPreference = "Stop"
$secretArn = '__SECRET_ARN__'
$region = '__AWS_REGION__'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$aws = Join-Path $env:ProgramFiles 'Amazon\AWSCLIV2\aws.exe'
if (-not (Test-Path $aws)) {
    $msi = Join-Path $env:TEMP 'AWSCLIV2.msi'
    Invoke-WebRequest -Uri 'https://awscli.amazonaws.com/AWSCLIV2.msi' -OutFile $msi
    $installer = Start-Process -FilePath 'msiexec.exe' `
        -ArgumentList @('/i', $msi, '/qn', '/norestart') -Wait -PassThru
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    if ($installer.ExitCode -notin @(0, 3010)) {
        throw 'AWS CLI installation failed.'
    }
    if (-not (Test-Path $aws)) {
        throw 'AWS CLI was not found after installation.'
    }
}

$env:AWS_DEFAULT_REGION = $region
$password = & $aws secretsmanager get-secret-value `
    --secret-id $secretArn --query SecretString --output text
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($password)) {
    throw 'Could not retrieve the bootstrap secret from Secrets Manager.'
}

$securePassword = ConvertTo-SecureString $password -AsPlainText -Force
Set-LocalUser -Name 'Administrator' -Password $securePassword
Enable-LocalUser -Name 'Administrator'
$password = $null
$securePassword = $null

Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Service -Name WinRM -StartupType Automatic
Start-Service -Name WinRM
Set-Item WSMan:\localhost\Service\Auth\Basic $false
Set-Item WSMan:\localhost\Service\Auth\Negotiate $true
Set-Item WSMan:\localhost\Service\AllowUnencrypted $false

$listener = Get-WSManInstance -ResourceURI winrm/config/Listener -Enumerate |
    Where-Object { $_.Transport -eq 'HTTPS' -and $_.Address -eq '*' } |
    Select-Object -First 1

if (-not $listener) {
    $cert = New-SelfSignedCertificate `
        -DnsName $env:COMPUTERNAME `
        -CertStoreLocation 'Cert:\LocalMachine\My' `
        -KeyAlgorithm RSA -KeyLength 2048 `
        -NotAfter (Get-Date).AddYears(2)

    New-WSManInstance -ResourceURI winrm/config/Listener `
        -SelectorSet @{ Address='*'; Transport='HTTPS' } `
        -ValueSet @{
            Hostname = $env:COMPUTERNAME
            CertificateThumbprint = $cert.Thumbprint
        } | Out-Null
}

if (-not (Get-NetFirewallRule -Name 'WinRM-HTTPS-In-TCP' -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name 'WinRM-HTTPS-In-TCP' `
        -DisplayName 'Windows Remote Management (HTTPS-In)' `
        -Enabled True -Direction Inbound -Protocol TCP -LocalPort 5986 `
        -Action Allow -Profile Any | Out-Null
}

Write-Output 'WinRM HTTPS bootstrap completed.'
'''

script = script.replace('__SECRET_ARN__', secret_arn).replace('__AWS_REGION__', region)
Path(out_path).write_text(script, encoding="utf-8")
PY

    python3 - "$SSM_SCRIPT_FILE" "$SSM_PARAMS_FILE" <<'PY'
import json
import sys
from pathlib import Path

script = Path(sys.argv[1]).read_text(encoding="utf-8")
Path(sys.argv[2]).write_text(
    json.dumps({"commands": [script]}),
    encoding="utf-8"
)
PY

    echo "[INFO] Sending WinRM HTTPS bootstrap to $label..."
    command_id="$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunPowerShellScript" \
        --comment "Bootstrap Windows AD lab WinRM HTTPS" \
        --timeout-seconds 900 \
        --parameters "file://$SSM_PARAMS_FILE" \
        --query 'Command.CommandId' \
        --output text)"

    rm -f -- "$SSM_SCRIPT_FILE" "$SSM_PARAMS_FILE"
    SSM_SCRIPT_FILE=""
    SSM_PARAMS_FILE=""

    for attempt in $(seq 1 90); do
        status="$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --query Status --output text 2>/dev/null || true)"

        case "$status" in
            Success)
                echo "[OK] SSM bootstrap succeeded on $label."
                return 0
                ;;
            Failed|Cancelled|TimedOut|Cancelling)
                echo "[ERROR] SSM bootstrap status: $status on $label."
                aws ssm get-command-invocation \
                    --region "$AWS_REGION" \
                    --command-id "$command_id" \
                    --instance-id "$instance_id" \
                    --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}' \
                    --output json || true
                return 1
                ;;
            *)
                echo "[INFO] Bootstrap status for $label: ${status:-Pending} ($attempt/90)"
                sleep 10
                ;;
        esac
    done

    echo "[ERROR] Timed out waiting for bootstrap on $label."
    return 1
}

bootstrap_instance "$DC_INSTANCE_ID" "DC01"
if [[ -n "$CLIENT_INSTANCE_ID" ]]; then
    bootstrap_instance "$CLIENT_INSTANCE_ID" "Windows client"
fi

# 7. Generate temporary AWS inventory. Passwords are provided by vault-aware
# playbooks and are not written to this inventory.
ANSIBLE_INVENTORY="$(mktemp)"
chmod 600 "$ANSIBLE_INVENTORY"

cat > "$ANSIBLE_INVENTORY" <<EOF
[domain_controller]
dc01 ansible_host=$DC_PUBLIC_IP

[windows_clients]
EOF

if [[ -n "$CLIENT_PUBLIC_IP" ]]; then
    echo "windowsclient_01 ansible_host=$CLIENT_PUBLIC_IP" >> "$ANSIBLE_INVENTORY"
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
echo "[INFO] Installing Ansible collections..."
ansible-galaxy collection install -r requirements.yml
inventory_graph="$(ansible-inventory -i "$ANSIBLE_INVENTORY" --graph 2>&1)" || {
    echo "[ERROR] Ansible could not parse the generated AWS inventory."
    echo "$inventory_graph"
    exit 1
}
echo "$inventory_graph"

if ! grep -Eq 'dc01' <<< "$inventory_graph"; then
    echo "[ERROR] Generated inventory does not contain dc01."
    exit 1
fi

if [[ -n "$CLIENT_INSTANCE_ID" ]] &&
   ! grep -Eq 'windowsclient_01' <<< "$inventory_graph"; then
    echo "[ERROR] A client instance exists, but the inventory has no windowsclient_01."
    exit 1
fi

echo "[OK] Generated AWS inventory contains the expected hosts."

# 8. Wait for HTTPS WinRM TCP port.
wait_for_winrm() {
    local host="$1"
    local label="$2"
    local attempt

    echo "[INFO] Waiting for WinRM HTTPS on ${host}:5986 ($label)..."
    for attempt in $(seq 1 60); do
        if python3 - "$host" 5986 <<'PY'
import socket
import sys

try:
    with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=5):
        raise SystemExit(0)
except OSError:
    raise SystemExit(1)
PY
        then
            echo "[OK] TCP 5986 reachable for $label."
            return 0
        fi

        echo "[INFO] $label port 5986 not ready ($attempt/60)"
        sleep 10
    done

    echo "[ERROR] WinRM HTTPS did not become reachable for $label."
    return 1
}

wait_for_winrm "$DC_PUBLIC_IP" "DC01"
if [[ -n "$CLIENT_PUBLIC_IP" ]]; then
    wait_for_winrm "$CLIENT_PUBLIC_IP" "Windows client"
fi

# 9. Test authenticated Ansible access before changing AD.
echo "[INFO] Testing authenticated WinRM connectivity..."
ansible-playbook -i "$ANSIBLE_INVENTORY" \
    playbooks/connection_test.yml \
    --vault-password-file "$VAULT_PASS_FILE"

# 10. Promote DC01 without rebooting through WinRM.
echo "[INFO] Configuring Active Directory Domain Services..."
ansible-playbook -i "$ANSIBLE_INVENTORY" \
    playbooks/domain_controller.yml \
    --vault-password-file "$VAULT_PASS_FILE"

# Reboot through SSM so the WinRM session does not have to survive it.
reboot_via_ssm() {
    local instance_id="$1"
    local label="$2"
    local params_file command_id status attempt
    local command_completed=0

    params_file="$(mktemp)"
    chmod 600 "$params_file"

    python3 - "$params_file" <<'PYTHON'
import json
import sys
from pathlib import Path
Path(sys.argv[1]).write_text(
    json.dumps({"commands": ["shutdown.exe /r /t 30 /f"]}),
    encoding="utf-8",
)
PYTHON

    echo "[INFO] Requesting reboot of $label through SSM..."
    command_id="$(aws ssm send-command         --region "$AWS_REGION"         --instance-ids "$instance_id"         --document-name "AWS-RunPowerShellScript"         --comment "Reboot domain controller after AD DS promotion"         --timeout-seconds 180         --parameters "file://$params_file"         --query 'Command.CommandId'         --output text)"
    rm -f -- "$params_file"

    for attempt in $(seq 1 60); do
        status="$(aws ssm get-command-invocation             --region "$AWS_REGION"             --command-id "$command_id"             --instance-id "$instance_id"             --query Status --output text 2>/dev/null || true)"

        case "$status" in
            Success)
                command_completed=1
                echo "[OK] SSM reboot command completed for $label."
                break
                ;;
            Failed|Cancelled|TimedOut|DeliveryTimedOut|ExecutionTimedOut|Undeliverable)
                echo "[ERROR] Reboot command status for $label: $status"
                aws ssm get-command-invocation                     --region "$AWS_REGION"                     --command-id "$command_id"                     --instance-id "$instance_id"                     --query '{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}'                     --output json || true
                return 1
                ;;
            *)
                echo "[INFO] Reboot command status: ${status:-Pending} ($attempt/60)"
                sleep 5
                ;;
        esac
    done

    if [[ "$command_completed" -ne 1 ]]; then
        echo "[ERROR] Timed out waiting for the SSM reboot command."
        return 1
    fi

    # SSM may not expose an Offline transition for every reboot.
    # Wait for management connectivity to be available again instead.
    echo "[INFO] Waiting for $label to become available in SSM after reboot..."
    wait_for_ssm "$instance_id" "$label"
}

wait_for_ad_ready() (
    local instance_id="$1"
    local label="$2"
    local params_file command_id status attempt run
    local stdout stderr submit_output
    local max_runs=20

    params_file="$(mktemp)"
    chmod 600 "$params_file"

    # Ensure the temporary SSM parameters file is removed on every exit path.
    trap 'rm -f -- "$params_file"' RETURN

    python3 - "$params_file" "$DOMAIN_NAME" <<'PYTHON'
import json
import sys
from pathlib import Path

domain = sys.argv[2]
if "'" in domain or "\n" in domain or "\r" in domain:
    raise SystemExit("Unexpected characters in domain name.")

script = r"""
$ErrorActionPreference = 'Stop'
$domain = '__DOMAIN_NAME__'

try {
    $services = Get-Service -Name NTDS,DNS,ADWS -ErrorAction Stop
    $stopped = @($services | Where-Object { $_.Status -ne 'Running' })

    if ($stopped.Count -gt 0) {
        $details = (($stopped | ForEach-Object {
            $_.Name + '=' + $_.Status
        }) -join ', ')
        Write-Output "AD_NOT_READY: Services not running: $details"
        exit 0
    }

    Import-Module ActiveDirectory -ErrorAction Stop
    $null = Get-ADDomain -Identity $domain -ErrorAction Stop

    Write-Output "AD_READY: Domain $domain is ready."
    exit 0
} catch {
    Write-Output ("AD_NOT_READY: " + $_.Exception.ToString())
    exit 0
}
"""
script = script.replace("__DOMAIN_NAME__", domain)
Path(sys.argv[1]).write_text(
    json.dumps({"commands": [script]}),
    encoding="utf-8",
)
PYTHON

    echo "[INFO] Checking AD DS and DNS readiness on $label..."

    for run in $(seq 1 "$max_runs"); do
        echo "[INFO] SSM readiness attempt $run/$max_runs for $label..."

        if ! submit_output="$(aws ssm send-command \
            --region "$AWS_REGION" \
            --instance-ids "$instance_id" \
            --document-name "AWS-RunPowerShellScript" \
            --comment "Verify AD DS and DNS readiness" \
            --timeout-seconds 1000 \
            --parameters "file://$params_file" \
            --query 'Command.CommandId' \
            --output text 2>&1)"; then
            echo "[WARN] SSM command submission failed:"
            echo "$submit_output"

            if [[ "$run" -lt "$max_runs" ]]; then
                sleep 10
                continue
            fi

            echo "[ERROR] Could not submit the AD readiness command after $max_runs attempts."
            return 1
        fi

        command_id="$submit_output"

        if [[ -z "$command_id" || "$command_id" == "None" ]]; then
            echo "[WARN] SSM returned no command ID: $submit_output"

            if [[ "$run" -lt "$max_runs" ]]; then
                sleep 10
                continue
            fi

            echo "[ERROR] SSM did not return a valid command ID."
            return 1
        fi

        local retry_this_run=0

        for attempt in $(seq 1 15); do
            status="$(aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$command_id" \
                --instance-id "$instance_id" \
                --query Status --output text 2>/dev/null || true)"

            case "$status" in
                Success)
                    stdout="$(aws ssm get-command-invocation \
                        --region "$AWS_REGION" \
                        --command-id "$command_id" \
                        --instance-id "$instance_id" \
                        --query StandardOutputContent --output text 2>/dev/null || true)"

                    if grep -q 'AD_READY:' <<< "$stdout"; then
                        echo "[OK] AD DS and DNS are ready on $label."
                        echo "$stdout"
                        return 0
                    fi

                    echo "[INFO] AD readiness has not been reached yet:"
                    echo "${stdout:-<empty output>}"
                    retry_this_run=1
                    break
                    ;;
                Failed|Cancelled|TimedOut|DeliveryTimedOut|ExecutionTimedOut|Undeliverable)
                    stdout="$(aws ssm get-command-invocation \
                        --region "$AWS_REGION" \
                        --command-id "$command_id" \
                        --instance-id "$instance_id" \
                        --query StandardOutputContent --output text 2>/dev/null || true)"
                    stderr="$(aws ssm get-command-invocation \
                        --region "$AWS_REGION" \
                        --command-id "$command_id" \
                        --instance-id "$instance_id" \
                        --query StandardErrorContent --output text 2>/dev/null || true)"

                    echo "[ERROR] AD readiness command ended with status: $status"
                    echo "[ERROR] SSM stdout: ${stdout:-<empty>}"
                    echo "[ERROR] SSM stderr: ${stderr:-<empty>}"

                    # Retry delivery failures and generic SSM failures
                    # without actionable diagnostics. Stop on actual errors.
                    if [[ "$run" -lt "$max_runs" ]] && {
                        [[ "$status" == "DeliveryTimedOut" ||
                           "$status" == "Undeliverable" ]] ||
                        {
                            [[ "$status" == "Failed" ]] &&
                            {
                                [[ -z "$stdout" || "$stdout" == "None" ]] &&
                                {
                                    [[ -z "$stderr" || "$stderr" == "None" ]] ||
                                    [[ "$stderr" == *"failed to run commands: exit status 1"* ]]
                                }
                            }
                        }
                    }; then
                        echo "[WARN] Retrying a transient or non-diagnostic SSM failure."
                        retry_this_run=1
                    fi
                    break
                    ;;
                *)
                    echo "[INFO] AD readiness status: ${status:-Pending} ($attempt/15)"
                    sleep 2
                    ;;
            esac
        done

        if [[ "$retry_this_run" -eq 1 ]]; then
            sleep 10
            continue
        fi

        if [[ "$attempt" -eq 15 && "$status" != "Success" ]]; then
            echo "[WARN] SSM readiness command did not finish within 30 seconds (status: ${status:-unknown})."

            if [[ "$run" -lt "$max_runs" ]]; then
                sleep 10
                continue
            fi

            echo "[ERROR] SSM readiness command timed out after $max_runs attempts."
        fi

        return 1
    done

    echo "[ERROR] AD readiness check exhausted its retry attempts."
    return 1
)
echo "[INFO] Rebooting DC01 through SSM..."
reboot_via_ssm "$DC_INSTANCE_ID" "DC01"

echo "[INFO] Waiting for Active Directory services after reboot..."
wait_for_ad_ready "$DC_INSTANCE_ID" "DC01"

echo "[INFO] Waiting for WinRM HTTPS after reboot..."
wait_for_winrm "$DC_PUBLIC_IP" "DC01"

echo "[INFO] Rechecking authenticated Ansible access after reboot..."
ansible_ok=0

for attempt in $(seq 1 12); do
    if ansible-playbook -i "$ANSIBLE_INVENTORY" \
        playbooks/connection_test.yml \
        --limit dc01 \
        -e 'ansible_user=PUMEJLAB\Administrator' \
        --vault-password-file "$VAULT_PASS_FILE"; then
        ansible_ok=1
        break
    fi

    echo "[WARN] Post-reboot WinRM check failed ($attempt/12); retrying in 30 seconds..."
    sleep 30
done

if [[ "$ansible_ok" -ne 1 ]]; then
    echo "[ERROR] Authenticated WinRM access to DC01 did not recover."
    exit 1
fi

# 11. Create OUs and import domain users.
echo "[INFO] Creating OUs and importing domain users..."
ansible-playbook -i "$ANSIBLE_INVENTORY" \
    playbooks/domain_users.yml \
    --vault-password-file "$VAULT_PASS_FILE"

# 12. Only configure DHCP/routing if routed strategy was selected.
if [[ "$NETWORK_STRATEGY" == "routed" ]]; then
    echo "[INFO] Configuring routed network services..."
    ansible-playbook -i "$ANSIBLE_INVENTORY" \
        playbooks/network_services.yml \
        --vault-password-file "$VAULT_PASS_FILE"
elif [[ "$NETWORK_STRATEGY" == "shared_vpc" ]]; then
    echo "[INFO] Skipping network_services.yml for shared_vpc."
else
    echo "[ERROR] Unsupported network strategy: $NETWORK_STRATEGY"
    exit 1
fi

# 13. Join the optional Windows client.
if [[ -n "$CLIENT_INSTANCE_ID" ]]; then
    echo "[INFO] Joining the Windows client to the domain..."
    ansible-playbook -i "$ANSIBLE_INVENTORY" \
        playbooks/domain_client.yml \
        --vault-password-file "$VAULT_PASS_FILE"
else
    echo "[INFO] Skipping client join; no Windows client was deployed."
fi

echo "=================================================="
echo "[INFO] Running final Active Directory validation..."
ansible-playbook -i "$ANSIBLE_INVENTORY" \
    playbooks/validate_deployment.yml \
    --vault-password-file "$VAULT_PASS_FILE"

echo "[SUCCESS] Deployment stages completed."
echo "Domain: $DOMAIN_NAME"
echo "Domain Controller private IP: $DC_PRIVATE_IP"
echo "Domain Controller public IP:  $DC_PUBLIC_IP"
echo "Windows Client private IP:    ${CLIENT_PRIVATE_IP:-not deployed}"
echo "Windows Client public IP:     ${CLIENT_PUBLIC_IP:-not deployed}"
echo "Network strategy: $NETWORK_STRATEGY"
echo "Log file: $LOG_FILE"
echo "Completed: $(date)"
echo "=================================================="
