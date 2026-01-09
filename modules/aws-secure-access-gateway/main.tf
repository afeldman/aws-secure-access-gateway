# Terraform module for the AWS Secure Access Gateway
# Phase 1: Core infrastructure with mTLS via Envoy and SSM for credentials.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

locals {
  resource_name = "${var.service_name}-${var.environment}-access-gateway"
  log_group_name = var.log_group_name != "" ? var.log_group_name : "/aws/access-gateway/${var.service_name}/${var.environment}"
  tags = merge(
    var.tags,
    {
      "service"     = var.service_name,
      "environment" = var.environment
    }
  )
}

# Use the latest Amazon Linux 2023 AMI for the gateway instance
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_caller_identity" "current" {}

# IAM Role for the EC2 Instance
# Allows SSM access and fetching credentials from Parameter Store
resource "aws_iam_role" "gateway_instance" {
  name = "${local.resource_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.gateway_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# IAM policy to fetch secrets from SSM Parameter Store
resource "aws_iam_policy" "ssm_credential_access" {
  name        = "${local.resource_name}-ssm-credential-access"
  description = "Allows access to SSM Parameter Store for credentials"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = flatten([
      [
        {
          Action = [
            "ssm:GetParameter",
            "ssm:GetParameters"
          ],
          Effect   = "Allow",
          Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${var.service_name}/secrets/*"
        }
      ],
      var.onepassword_connect_token_param != "" ? [
        {
          Action = [
            "ssm:GetParameter",
            "ssm:GetParameters"
          ],
          Effect   = "Allow",
          Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.onepassword_connect_token_param}"
        }
      ] : [],
      var.twingate_access_token_param != "" ? [
        {
          Action = ["ssm:GetParameter", "ssm:GetParameters"],
          Effect = "Allow",
          Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.twingate_access_token_param}"
        }
      ] : [],
      var.twingate_refresh_token_param != "" ? [
        {
          Action = ["ssm:GetParameter", "ssm:GetParameters"],
          Effect = "Allow",
          Resource = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.twingate_refresh_token_param}"
        }
      ] : []
    ])
  })
  tags = local.tags
}

resource "aws_cloudwatch_log_group" "gateway" {
  count             = var.enable_cloudwatch_logs ? 1 : 0
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_iam_policy" "cloudwatch_logging" {
  count       = var.enable_cloudwatch_logs ? 1 : 0
  name        = "${local.resource_name}-cw-logs"
  description = "Allow gateway to publish logs to CloudWatch Logs"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "${aws_cloudwatch_log_group.gateway[0].arn}:*"
      },
      {
        Effect = "Allow",
        Action = ["logs:CreateLogGroup"],
        Resource = "${aws_cloudwatch_log_group.gateway[0].arn}"
      }
    ]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm_credential_access" {
  role       = aws_iam_role.gateway_instance.name
  policy_arn = aws_iam_policy.ssm_credential_access.arn
}

resource "aws_iam_role_policy_attachment" "cloudwatch_logging" {
  count      = var.enable_cloudwatch_logs ? 1 : 0
  role       = aws_iam_role.gateway_instance.name
  policy_arn = aws_iam_policy.cloudwatch_logging[0].arn
}

resource "aws_iam_instance_profile" "gateway_instance" {
  name = "${local.resource_name}-instance-profile"
  role = aws_iam_role.gateway_instance.name
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  count      = var.enable_kubectl_access ? 1 : 0
  role       = aws_iam_role.gateway_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Security group for the gateway instance
# No ingress from the internet. Egress is limited for security.
resource "aws_security_group" "gateway" {
  name        = "${local.resource_name}-sg"
  description = "Security group for the secure access gateway instance"
  vpc_id      = var.vpc_id

  # No ingress rules are needed as access is via SSM Session Manager.

  dynamic "ingress" {
    for_each = length(var.trusted_forwarder_cidr) > 0 && var.enable_mtls ? [1] : []
    content {
      description = "Trusted forwarder mTLS access"
      from_port   = 10000
      to_port     = 10000
      protocol    = "tcp"
      cidr_blocks = var.trusted_forwarder_cidr
    }
  }

  dynamic "ingress" {
    for_each = length(var.trusted_forwarder_cidr) > 0 && var.enable_ssh ? [1] : []
    content {
      description = "Trusted forwarder SSH access"
      from_port   = 2222
      to_port     = 2222
      protocol    = "tcp"
      cidr_blocks = var.trusted_forwarder_cidr
    }
  }

  # Egress Rules
  # Allow HTTPS to VPC resources (EKS API/private endpoints) and AWS SSM endpoints.
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  # Allow DNS within the VPC for service discovery.
  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  # Required for SSM Session Manager.
  egress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [
      data.aws_prefix_list.ssm.id,
      data.aws_prefix_list.ssmmessages.id,
      data.aws_prefix_list.ec2messages.id
    ]
  }

  tags = local.tags
}

data "aws_prefix_list" "ssm" {
  name = "com.amazonaws.${var.region}.ssm"
}

data "aws_prefix_list" "ssmmessages" {
  name = "com.amazonaws.${var.region}.ssmmessages"
}

data "aws_prefix_list" "ec2messages" {
  name = "com.amazonaws.${var.region}.ec2messages"
}

# The EC2 instance acting as the secure access gateway
resource "aws_instance" "gateway" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  subnet_id = var.private_subnet_ids[0] # Start with one subnet, can be expanded for HA

  associate_public_ip_address = false

  iam_instance_profile = aws_iam_instance_profile.gateway_instance.name
  vpc_security_group_ids = [aws_security_group.gateway.id]

  user_data_base64 = base64encode(templatefile("${path.module}/templates/userdata.sh.tpl", {
    credential_source = var.credential_source
    enable_mtls       = var.enable_mtls
    enable_ssh        = var.enable_ssh
    enable_twingate   = var.enable_twingate
    trusted_forwarder_cidr = var.trusted_forwarder_cidr
    twingate_network  = var.twingate_network
    twingate_access_token_param = var.twingate_access_token_param
    twingate_refresh_token_param = var.twingate_refresh_token_param
    service_name      = var.service_name
    environment       = var.environment
    region            = var.region
    onepassword_vault = var.onepassword_vault
    onepassword_item_prefix = var.onepassword_item_prefix
    onepassword_connect_host = var.onepassword_connect_host
    onepassword_connect_token_param = var.onepassword_connect_token_param
    log_group_name    = local.log_group_name
    enable_cloudwatch_metrics = var.enable_cloudwatch_metrics
    cloudwatch_namespace      = var.cloudwatch_namespace
    envoy_config      = templatefile("${path.module}/templates/envoy-config.yaml.tpl", {
      listener_port = 10000
      upstream_host = "localhost"
      upstream_port = 8080
    })
  }))

    metadata_options {
      http_tokens   = "required"   # Enforce IMDSv2
      http_endpoint = "enabled"
    }

    root_block_device {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }

  tags = merge(local.tags, {
    "Name" = local.resource_name
  })
}
