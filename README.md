# Windows Server 2022 Active Directory service Deployment using AWS cloud platform

An automated Windows Active Directory lab built with **Terraform, AWS, Ansible, and PowerShell**. The project provisions Windows EC2 instances, configures a domain controller, creates organizational units and user accounts, and optionally joins a Windows client to the domain.

The lab is designed for learning, testing, and practicing Windows domain administration without needing a local virtual machine environment.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Technology Stack](#technology-stack)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Configuration](#configuration)
- [Secrets Management](#secrets-management)
- [Deployment](#deployment)
- [Validation and Testing](#validation-and-testing)
- [Connecting to the Windows Client](#connecting-to-the-windows-client)
- [Security Considerations](#security-considerations)
- [Troubleshooting](#troubleshooting)
- [Destroying the Environment](#destroying-the-environment)
- [Future Improvements](#future-improvements)

## Overview

The project automates the deployment and configuration of an AWS-hosted Windows Active Directory environment.

The automation covers:

1. Provisioning AWS infrastructure using Terraform.
2. Bootstrapping Windows instances using AWS Systems Manager (SSM).
3. Configuring WinRM over HTTPS for Ansible management.
4. Promoting a Windows Server instance to an Active Directory domain controller.
5. Configuring Active Directory DNS and domain services.
6. Creating organizational units (OUs) and importing user accounts from CSV.
7. Optionally joining a Windows client to the domain.
8. Running a final validation playbook to verify the domain, OUs, and expected user accounts.

## Architecture

The default lab configuration uses the following network and domain settings.

| Component | Configuration |
| --- | --- |
| AWS region | `us-east-1` |
| Active Directory domain | `pumejlab.com` |
| NetBIOS name | `PUMEJLAB` |
| VPC CIDR | `10.20.0.0/16` |
| Public subnet CIDR | `10.20.1.0/24` |
| Domain controller private IP | `10.20.1.10` |
| Windows client private IP | `10.20.1.20` |
| Network strategy | `shared_vpc` |
| Domain controller OS | Windows Server 2022 |
| Infrastructure as code | Terraform |
| Configuration management | Ansible |

### Logical architecture

```text
Administrator workstation
        |
        | Terraform / AWS CLI
        | Ansible over WinRM HTTPS
        v
      AWS
        |
        +-- VPC: 10.20.0.0/16
        |     |
        |     +-- Public subnet: 10.20.1.0/24
        |            |
        |            +-- DC01
        |            |     Windows Server 2022
        |            |     AD DS and DNS
        |            |     10.20.1.10
        |            |
        |            +-- WIN-CLIENT-01 (optional)
        |                  Windows client
        |                  10.20.1.20
        |
        +-- IAM instance profile and SSM
        |
        +-- Secrets Manager
```

The domain controller provides Active Directory Domain Services (AD DS) and DNS. The Windows client, when enabled, uses the domain controller for DNS and joins `pumejlab.com`.

**Current client image note:** The Terraform configuration currently uses the Windows Server 2022 AMI parameter for both the domain controller and client. A separate Windows 11 AMI has not yet been configured. See [Future Improvements](#future-improvements).

## Technology Stack

- **AWS EC2:** Hosts the Windows instances.
- **Amazon VPC:** Provides networking and subnet configuration.
- **AWS IAM:** Grants instances the permissions required for SSM and bootstrap operations.
- **AWS Systems Manager:** Supports instance management and bootstrap operations.
- **AWS Secrets Manager:** Stores the bootstrap secret.
- **Terraform:** Provisions and manages AWS infrastructure.
- **Ansible:** Automates Windows configuration and deployment orchestration.
- **WinRM over HTTPS:** Provides the secure Ansible management connection.
- **PowerShell:** Configures Windows Server, Active Directory, DNS, and user accounts.
- **Ansible Vault:** Encrypts sensitive configuration variables.

## Project Structure

The main project files are organized as follows. Some supporting filenames may vary as the project evolves.

```text
windows-ad-lab/
├── startupadds-aws.sh
├── README.md
├── .gitignore
├── aws-ad-lab-terraform/
│   ├── main.tf
│   ├── compute.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars
│   └── ...
├── playbooks/
│   ├── connection_test.yml
│   ├── domain_controller.yml
│   ├── domain_users.yml
│   ├── domain_client.yml
│   └── validate_deployment.yml
├── group_vars/
│   ├── windows.yml
│   └── vault.yml
├── files/
│   └── user_accounts_final.csv
├── scripts/
│   └── Create-DomainUsers.ps1
└── logs/
```

### Key files

| File | Purpose |
| --- | --- |
| `startupadds-aws.sh` | Coordinates the deployment workflow. |
| `aws-ad-lab-terraform/main.tf` | Defines shared AWS resources and data sources. |
| `aws-ad-lab-terraform/compute.tf` | Defines the domain controller and client EC2 instances. |
| `aws-ad-lab-terraform/variables.tf` | Declares Terraform configuration variables. |
| `aws-ad-lab-terraform/terraform.tfvars` | Supplies environment-specific Terraform values. |
| `playbooks/connection_test.yml` | Tests Ansible connectivity to Windows hosts. |
| `playbooks/domain_controller.yml` | Configures and promotes the domain controller. |
| `playbooks/domain_users.yml` | Copies the CSV and provisions OUs and users. |
| `playbooks/domain_client.yml` | Configures client DNS and joins the client to the domain. |
| `playbooks/validate_deployment.yml` | Performs final Active Directory validation. |
| `group_vars/windows.yml` | Holds non-secret Windows and Ansible settings. |
| `group_vars/vault.yml` | Holds encrypted credentials and sensitive variables. |
| `scripts/Create-DomainUsers.ps1` | Implements user and OU provisioning logic. |
| `files/user_accounts_final.csv` | Supplies the user-account data. |

## Prerequisites

Before deploying the lab, ensure the following tools and resources are available.

### Local workstation

- Linux or WSL environment.
- Bash.
- Python 3 and a project virtual environment.
- AWS CLI configured with appropriate permissions.
- Terraform.
- Ansible.
- Ansible Windows collection and its required dependencies.
- Network connectivity to AWS and the configured WinRM endpoint.

Example setup commands:

```bash
# Create and activate a virtual environment if needed
python3 -m venv .venv
source .venv/bin/activate

# Install Ansible if it is not already installed
python -m pip install ansible pywinrm

# Verify installed tools
aws --version
terraform version
ansible --version
```

Install any additional Ansible collections declared by the project. For example:

```bash
ansible-galaxy collection install ansible.windows
```

### AWS requirements

- An AWS account with permissions to create and manage the lab's resources.
- An AWS region supported by the selected Windows AMI.
- Appropriate EC2, VPC, IAM, SSM, and Secrets Manager permissions.
- A trusted administrator public IP for restricting management access.
- An existing Windows license entitlement where required by the chosen image.

## Configuration

Review the Terraform variables and Ansible variables before deployment.

### Terraform

The Terraform configuration controls the AWS region, networking, Windows instances, client deployment option, and administrator CIDR.

From the Terraform directory:

```bash
cd aws-ad-lab-terraform

# Review the configured values
grep -n -E 'variable |default|admin_cidr|network_strategy|deploy_windows_client|windows_client_ami_id' \
  variables.tf
```

Check `terraform.tfvars` for the intended deployment values. Do not commit account-specific credentials or sensitive values to source control.

### Ansible

Review:

```text
group_vars/windows.yml
group_vars/vault.yml
```

The regular variables file should contain non-secret settings. Credentials belong in Ansible Vault or another approved secrets-management mechanism.

### CSV user data

The user import CSV is:

```text
files/user_accounts_final.csv
```

The expected columns are:

- `DisplayName`
- `username`
- `email`
- `UPN`
- `OU`
- `password`
- `company`
- `department`

The current validation expects 119 account rows. If the CSV changes, update the validation logic accordingly.

Never print or commit CSV password values.

## Secrets Management

Sensitive credentials must not be stored in plaintext configuration files or committed to Git.

The project uses an Ansible Vault password file at:

```text
~/.ansible_vault_pass
```

Restrict its permissions:

```bash
chmod 600 "$HOME/.ansible_vault_pass"
```

Verify that the vault password can decrypt the encrypted variables file without displaying its contents:

```bash
ansible-vault view group_vars/vault.yml \
  --vault-password-file "$HOME/.ansible_vault_pass" \
  >/dev/null

echo "Vault decryption successful."
```

The vault password file must contain the correct password for `group_vars/vault.yml`.

The deployment also uses AWS Secrets Manager for bootstrap credentials. Keep the associated IAM permissions scoped to the required secret.

## Deployment

The main deployment entry point is:

```text
startupadds-aws.sh
```

The script orchestrates Terraform and Ansible operations. It can create or modify AWS resources, bootstrap Windows instances, configure Active Directory, import users, and optionally join the client to the domain.

### 1. Navigate to the project

```bash
cd ~/Projects/windows-ad-lab
source .venv/bin/activate
```

### 2. Confirm AWS credentials

```bash
aws sts get-caller-identity
aws configure get region
```

Confirm that the AWS account and region are the intended ones.

### 3. Validate Terraform

```bash
cd aws-ad-lab-terraform

terraform init
terraform fmt -check
terraform validate
terraform plan
```

Review the plan before applying any infrastructure changes.

Return to the project root:

```bash
cd ..
```

### 4. Run the deployment

**Warning:** The deployment script executes Terraform operations and can create, modify, or replace AWS resources. Review the script and plan before proceeding.

```bash
bash startupadds-aws.sh
```

Follow the output and allow each stage to finish. Do not launch a second deployment while the first is running.

### 5. Review the deployment log

The script writes a log under the project's `logs/` directory.

Locate recent logs:

```bash
ls -lt logs/
```

Review the relevant log if a deployment stage fails. Redact credentials, tokens, passwords, and other sensitive values before sharing logs.

## Validation and Testing

A successful deployment should finish with:

```text
[SUCCESS] Deployment stages completed.
```

The final validation playbook checks:

- The Active Directory domain exists.
- The six required organizational units exist:
  - `Admins`
  - `Management`
  - `IT`
  - `HR`
  - `Marketing`
  - `Sales`
- The CSV contains the expected number of user rows.
- The expected user accounts exist.
- User principal names match the CSV.
- User OU placement matches the CSV.

Run the final validator independently:

```bash
ansible-playbook \
  -i /path/to/your/ansible-inventory \
  playbooks/validate_deployment.yml \
  --vault-password-file "$HOME/.ansible_vault_pass"
```

Replace the inventory path with the actual inventory generated by your deployment workflow.

### Check AWS instance status

```bash
aws ec2 describe-instances \
  --region us-east-1 \
  --filters "Name=tag:Name,Values=*" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,PrivateIP:PrivateIpAddress}' \
  --output table
```

For more targeted checks, use the instance IDs or tags reported by Terraform.

### Verify the Windows client

When the client is enabled, confirm all of the following:

1. The client instance is running.
2. WinRM connectivity is available.
3. The client uses the domain controller for DNS.
4. The computer is joined to `pumejlab.com`.
5. The client reconnects after any required reboot.
6. Domain authentication works with a test account.

A successful domain-join task alone does not prove that post-reboot authentication works.

## Connecting to the Windows Client

If remote desktop access is configured, use the Windows Remote Desktop client (`mstsc.exe`) from your workstation.

Connect to the Windows client's public IP and sign in with an authorized account.

For a domain account, the username can be entered as:

```text
PUMEJLAB\username
```

Alternatively, use the account's user principal name if appropriate:

```text
username@pumejlab.com
```

RDP must be enabled and allowed by the security group. Restrict TCP port `3389` to your trusted public IP rather than exposing it to the entire internet.

If RDP is not enabled or permitted, use an approved access method such as AWS Systems Manager where supported.

## Security Considerations

This project is intended for a controlled lab environment. Apply the following precautions:

- Restrict management access to trusted source IP addresses.
- Use WinRM over HTTPS on TCP port `5986`.
- Do not expose WinRM or RDP to `0.0.0.0/0`.
- Keep Windows, Terraform, Ansible, and AWS tooling updated.
- Store secrets in Ansible Vault or AWS Secrets Manager.
- Do not commit `.ansible_vault_pass`, private keys, credentials, state backups, or password-containing CSV files.
- Keep Terraform state protected because it can contain sensitive values.
- Use least-privilege IAM policies.
- Review security-group ingress and egress rules.
- Stop or destroy lab resources when they are no longer needed.

## Troubleshooting

### Terraform reports unexpected changes

Run:

```bash
terraform plan
```

Inspect resource replacements, AMI changes, networking differences, and state drift before applying.

### Ansible cannot connect to Windows

Check that:

- The EC2 instance is running and has completed bootstrap.
- WinRM HTTPS is configured and listening on port `5986`.
- The security group allows WinRM from the trusted administrator IP.
- The inventory uses the correct host address and connection settings.
- The credentials decrypt successfully from Ansible Vault.

### User import fails

Check:

- The CSV exists at `files/user_accounts_final.csv`.
- The playbook copies the CSV to the expected Windows path.
- The CSV headers match the import script's expectations.
- The credentials used by the playbook are correct.
- The domain controller has AD DS and DNS ready.

Review the detailed import log on DC01:

```text
C:\Temp\ADLab\ADUserImportLog.txt
```

Do not expose passwords or other sensitive data when reviewing or sharing logs.

### Windows client cannot join the domain

Check that:

- The client can resolve the domain using the domain controller's DNS.
- The domain controller is reachable on the required network ports.
- The domain name and credentials are correct.
- The client has completed its restart.
- The client operating system and image are compatible with the provisioning process.

### Final validation fails

Run the validator independently and inspect the Ansible failure details. A successful deployment message should only be trusted when the required validation stages have passed.

## Destroying the Environment

Destroying the lab removes AWS resources managed by the Terraform configuration. This is destructive and can delete the domain controller, client, network resources, and associated lab configuration stored in AWS.

First, navigate to the Terraform directory:

```bash
cd ~/Projects/windows-ad-lab/aws-ad-lab-terraform
```

Create a destroy plan:

```bash
terraform plan -destroy -out=tfplan-destroy
terraform show -no-color tfplan-destroy
```

Carefully review the plan. Confirm that it targets only the intended lab resources and the correct AWS account.

If the plan is correct and you intend to delete the environment:

```bash
terraform apply tfplan-destroy
```

Afterward, inspect the AWS account for any lab-related resources not managed by Terraform. Resources such as separately created AMIs, snapshots, log groups, or other manually created artifacts may require separate cleanup.

Keep the Terraform state and project files until cleanup has been verified. Do not manually delete the state file as a substitute for destroying resources.

## Future Improvements

Potential improvements include:

- **Windows 11 client:** Configure a separate, supported Windows 11 AMI instead of reusing the Windows Server 2022 image parameter. Confirm image availability, licensing, and instance compatibility first.
- **Stronger client verification:** Add explicit post-reboot checks for domain membership, secure-channel health, and domain-user authentication.
- **Idempotency testing:** Run the deployment workflow again and verify that completed configuration steps do not create unnecessary changes.
- **Automated preflight checks:** Validate AWS identity, Terraform configuration, vault decryption, WinRM connectivity, and security-group restrictions before deployment.
- **Cost controls:** Add lifecycle documentation and checks for resources that could continue incurring charges.
- **CI validation:** Add automated Bash, Terraform, and Ansible syntax checks before deployment.

---

## License and Disclaimer

This project is intended for educational and lab use. You are responsible for AWS costs, access controls, operating-system licensing, and the security of the resources you deploy.

Review Microsoft and AWS licensing requirements before deploying Windows client images in EC2.
