data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lab_ssm" {
  name               = "${var.project_name}-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Project     = var.project_name
    Environment = "lab"
    ManagedBy   = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.lab_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "lab" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.lab_ssm.name

  tags = {
    Project     = var.project_name
    Environment = "lab"
    ManagedBy   = "Terraform"
  }
}

# Container only: the secret value is populated by the deployment script.
resource "aws_secretsmanager_secret" "bootstrap" {
  name                    = "${var.project_name}/bootstrap-password"
  description             = "Temporary bootstrap credential for the Windows AD lab"
  recovery_window_in_days = 0

  tags = {
    Project     = var.project_name
    Environment = "lab"
    ManagedBy   = "Terraform"
  }
}

# Permit the lab instances to retrieve only this specific secret.
data "aws_iam_policy_document" "bootstrap_secret_access" {
  statement {
    sid       = "ReadBootstrapSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.bootstrap.arn]
  }
}

resource "aws_iam_role_policy" "bootstrap_secret_access" {
  name   = "${var.project_name}-bootstrap-secret-read"
  role   = aws_iam_role.lab_ssm.id
  policy = data.aws_iam_policy_document.bootstrap_secret_access.json
}