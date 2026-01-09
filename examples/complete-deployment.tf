# Example: AWS Secure Access Gateway with Honeytrap Integration
# This shows how to deploy both the main gateway and optional Honeytrap deception component

terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

# =========================================================================
# VPC and Networking (example - use your existing VPC)
# =========================================================================

data "aws_vpc" "main" {
  default = true  # Use default VPC; replace with your VPC ID
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.main.id]
  }
}

# =========================================================================
# Main: Secure Access Gateway
# =========================================================================

module "access_gateway" {
  source = "./modules/aws-secure-access-gateway"

  # Cluster and network configuration
  eks_cluster_name   = "prod-eks"
  vpc_id             = data.aws_vpc.main.id
  private_subnet_ids = slice(data.aws_subnets.private.ids, 0, 2)
  region             = "eu-central-1"

  # Access mode (mutually exclusive)
  # Choose ONE: mTLS (default), SSH, or Twingate
  access_mode = "mtls"
  enable_mtls = true
  enable_ssh  = false
  enable_twingate = false

  # Optional: Enable Honeytrap honeypots in-cluster
  # (separate EC2 deployment is recommended for production)
  enable_honeytrap = false

  # Credentials: SSM Parameter Store (default) or 1Password
  credential_source = "ssm"
  # For 1Password:
  # credential_source = "1password"
  # onepassword_vault = "platform"
  # onepassword_item_prefix = "access-gateway/"
  # onepassword_connect_host = "https://connect.example.com"
  # onepassword_connect_token_param = "/platform/secrets/1password/connect-token"

  # Logging and metrics
  enable_cloudwatch_logs  = true
  enable_cloudwatch_metrics = true
  log_retention_days      = 30
  cloudwatch_namespace    = "AccessGateway"

  # Security configuration
  trusted_forwarder_cidr  = []  # Only SSM, no direct access
  enable_kubectl_access   = false  # Set to true if gateway needs kubectl

  # Resource sizing
  instance_type      = "t3.micro"
  root_volume_size   = 20

  # Tags
  service_name  = "internal-app"
  environment   = "prod"
  tags = {
    client      = "internal"
    environment = "prod"
    service     = "access-gateway"
    squad       = "platform"
    managed_by  = "terraform"
  }
}

# =========================================================================
# Optional: Standalone Honeytrap Deception Component (recommended for prod)
# =========================================================================

module "honeytrap" {
  source = "./modules/honeytrap-ec2"

  # Enable/disable the entire module
  # Set to false to skip Honeytrap deployment
  enable_honeytrap = true

  # Network configuration
  vpc_id             = data.aws_vpc.main.id
  private_subnet_ids = slice(data.aws_subnets.private.ids, 0, 2)
  region             = "eu-central-1"

  # Honeytrap ports (fake services for deception)
  honeypot_ports = [
    2223,   # Fake SSH (OpenSSH_7.4 banner)
    10023   # Fake generic TCP service
  ]

  # Restrict honeytrap access (for testing/red-team)
  # Leave empty [] to deny all external access (default/recommended)
  trusted_source_cidr = []

  # Optional: Custom Honeytrap configuration from SSM Parameter Store
  # Store as: aws ssm put-parameter --name "/internal-app/prod/honeytrap/config" --type SecureString --value "..."
  honeytrap_config_param = ""  # If empty, default config is used

  # CloudWatch integration
  log_retention_days     = 30
  enable_anomaly_detection = true
  cloudwatch_namespace   = "Honeytrap"

  # Alerting on suspicious activity
  # Create SNS topic first: aws sns create-topic --name security-alerts
  alert_sns_topic_arn = "arn:aws:sns:eu-central-1:123456789012:security-alerts"
  alarm_threshold     = 1  # Alert on ANY connection (indicates deception triggered)

  # Resource sizing
  instance_type    = "t3.micro"
  root_volume_size = 20

  # Tags
  service_name = "internal-app"
  environment  = "prod"
  tags = {
    client      = "internal"
    environment = "prod"
    service     = "honeytrap"
    squad       = "platform"
    managed_by  = "terraform"
    role        = "deception-only"
  }
}

# =========================================================================
# Outputs
# =========================================================================

output "gateway_instance_id" {
  description = "The ID of the EC2 instance running the Secure Access Gateway"
  value       = module.access_gateway.gateway_instance_id
}

output "gateway_connection_command" {
  description = "Command to connect to the gateway via SSM"
  value       = module.access_gateway.connection_command
}

output "gateway_kubeconfig_command" {
  description = "Command to configure kubectl on the gateway"
  value       = module.access_gateway.kubeconfig_command
}

output "gateway_cloudwatch_log_group" {
  description = "CloudWatch log group for gateway logs"
  value       = module.access_gateway.cloudwatch_log_group_name
}

output "honeytrap_instance_id" {
  description = "The ID of the EC2 instance running Honeytrap (if enabled)"
  value       = var.enable_honeytrap ? module.honeytrap[0].honeytrap_instance_id : null
}

output "honeytrap_cloudwatch_log_group" {
  description = "CloudWatch log group for Honeytrap logs (if enabled)"
  value       = var.enable_honeytrap ? module.honeytrap[0].cloudwatch_log_group_name : null
}

output "honeytrap_connection_command" {
  description = "Command to connect to Honeytrap instance via SSM (if enabled, for debugging)"
  value       = var.enable_honeytrap ? module.honeytrap[0].honeytrap_connection_command : null
}

output "honeytrap_alarm_activity_arn" {
  description = "ARN of the CloudWatch alarm for Honeytrap activity detection (if enabled)"
  value       = var.enable_honeytrap ? module.honeytrap[0].alarm_activity_arn : null
}

output "honeytrap_alarm_auth_success_arn" {
  description = "ARN of the CRITICAL CloudWatch alarm for Honeytrap auth success (if enabled)"
  value       = var.enable_honeytrap ? module.honeytrap[0].alarm_auth_success_arn : null
}

# =========================================================================
# Notes
# =========================================================================

# Prerequisites:
# 1. EKS cluster named "prod-eks" must exist
# 2. mTLS secrets in SSM:
#    - /internal-app/secrets/mtls/ca (CA certificate)
#    - /internal-app/secrets/mtls/cert (Server certificate)
#    - /internal-app/secrets/mtls/key (Server private key)
# 3. SSH secrets (if using SSH mode):
#    - /internal-app/secrets/ssh/authorized_keys (newline-separated keys)
# 4. CloudWatch log groups will be created automatically
# 5. SNS topic for alerts must exist (or set alert_sns_topic_arn to "")

# Deployment:
# terraform plan
# terraform apply

# Verify:
# 1. Check gateway logs: aws logs tail /aws/access-gateway/prod --follow
# 2. Check honeytrap logs: aws logs tail /aws/honeytrap/prod --follow
# 3. Connect to gateway: aws ssm start-session --target $(terraform output -raw gateway_instance_id)
# 4. Verify honeytrap is isolated: cannot reach app from honeytrap pod/instance
