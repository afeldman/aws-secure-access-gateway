# Terraform module for optional Honeytrap deception/detection component
# Honeytrap is deployed as a standalone EC2 instance alongside the Secure Access Gateway
# It serves only to deceive and detect attacks, NOT as an access path

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

locals {
  resource_name = "${var.service_name}-${var.environment}-honeytrap"
  log_group_name = var.log_group_name != "" ? var.log_group_name : "/aws/honeytrap/${var.service_name}/${var.environment}"
  tags = merge(
    var.tags,
    {
      "service"     = var.service_name,
      "environment" = var.environment,
      "component"   = "honeytrap"
    }
  )
}

# Use the latest Amazon Linux 2023 AMI
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

# IAM Role for Honeytrap EC2 Instance
# Minimal permissions: only SSM access and CloudWatch Logs
resource "aws_iam_role" "honeytrap" {
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
  role       = aws_iam_role.honeytrap.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch Logs policy
resource "aws_iam_policy" "cloudwatch_logs" {
  name        = "${local.resource_name}-cw-logs"
  description = "Allow Honeytrap to publish logs to CloudWatch Logs"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:CreateLogGroup"
        ],
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${local.log_group_name}:*"
      }
    ]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_logs" {
  role       = aws_iam_role.honeytrap.name
  policy_arn = aws_iam_policy.cloudwatch_logs.arn
}

# CloudWatch Alarms policy (for Honeytrap to write metrics/alarms)
resource "aws_iam_policy" "cloudwatch_metrics" {
  name        = "${local.resource_name}-cw-metrics"
  description = "Allow Honeytrap to publish metrics to CloudWatch"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "cloudwatch:PutMetricData"
        ],
        Resource = "*",
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = var.cloudwatch_namespace
          }
        }
      }
    ]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_metrics" {
  role       = aws_iam_role.honeytrap.name
  policy_arn = aws_iam_policy.cloudwatch_metrics.arn
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "honeytrap" {
  name = "${local.resource_name}-instance-profile"
  role = aws_iam_role.honeytrap.name
}

# Security Group for Honeytrap
# Restricted ingress to only honeypot ports from trusted sources
resource "aws_security_group" "honeytrap" {
  name        = "${local.resource_name}-sg"
  description = "Security group for the Honeytrap deception component"
  vpc_id      = var.vpc_id

  # Allow SSH honeypot from trusted sources only (if specified)
  dynamic "ingress" {
    for_each = length(var.trusted_source_cidr) > 0 ? [1] : []
    content {
      description = "Honeytrap SSH honeypot (fake)"
      from_port   = 2223
      to_port     = 2223
      protocol    = "tcp"
      cidr_blocks = var.trusted_source_cidr
    }
  }

  # Allow additional honeypot ports from trusted sources
  dynamic "ingress" {
    for_each = length(var.trusted_source_cidr) > 0 ? var.honeypot_ports : []
    content {
      description = "Honeytrap port ${ingress.value} (fake service)"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = var.trusted_source_cidr
    }
  }

  # Egress: only to VPC (for CloudWatch, SSM)
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  # DNS within VPC
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

  # SSM endpoints
  egress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
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

# CloudWatch Log Group for Honeytrap
resource "aws_cloudwatch_log_group" "honeytrap" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

# EC2 Instance for Honeytrap
resource "aws_instance" "honeytrap" {
  ami           = data.aws_ami.amazon_linux_2023.id
  instance_type = var.instance_type

  subnet_id = var.private_subnet_ids[0]

  associate_public_ip_address = false

  iam_instance_profile   = aws_iam_instance_profile.honeytrap.name
  vpc_security_group_ids = [aws_security_group.honeytrap.id]

  user_data_base64 = base64encode(templatefile("${path.module}/templates/userdata.sh.tpl", {
    HONEYTRAP_IMAGE                = var.honeytrap_image
    HONEYTRAP_PORTS                = join(" ", var.honeypot_ports)
    HONEYTRAP_CONFIG_PARAM         = var.honeytrap_config_param
    HONEYTRAP_LOG_GROUP_NAME       = local.log_group_name
    SERVICE_NAME                   = var.service_name
    ENVIRONMENT                    = var.environment
    REGION                         = var.region
    ENABLE_ANOMALY_DETECTION       = var.enable_anomaly_detection ? "true" : "false"
    CLOUDWATCH_NAMESPACE           = var.cloudwatch_namespace
    ALERT_SNS_TOPIC_ARN            = var.alert_sns_topic_arn
  }))

  metadata_options {
    http_tokens   = "required" # Enforce IMDSv2
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

  depends_on = [aws_cloudwatch_log_group.honeytrap]
}

# CloudWatch Alarm for Honeytrap activity (detects connections to fake services)
resource "aws_cloudwatch_log_group_metric_filter" "honeytrap_connections" {
  name           = "${local.log_group_name}-metric-filter"
  log_group_name = aws_cloudwatch_log_group.honeytrap.name
  filter_pattern = "[time, request_id, event_type = \"connection\", ...]"

  metric_transformation {
    name      = "HoneytrapConnectionCount"
    namespace = var.cloudwatch_namespace
    value     = "1"
    default_value = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "honeytrap_activity" {
  alarm_name          = "${local.resource_name}-activity"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "HoneytrapConnectionCount"
  namespace           = var.cloudwatch_namespace
  period              = "60"
  statistic           = "Sum"
  threshold           = var.alarm_threshold
  alarm_description   = "Alert when suspicious activity is detected on Honeytrap honeypots"
  alarm_actions       = var.alert_sns_topic_arn != "" ? [var.alert_sns_topic_arn] : []
  treat_missing_data  = "notBreaching"

  tags = local.tags
}

# Validation: Ensure Honeytrap cannot be used as an access path
# This is enforced via network policy and security group rules above
resource "aws_cloudwatch_log_group_metric_filter" "security_validation" {
  name           = "${local.log_group_name}-security-validation"
  log_group_name = aws_cloudwatch_log_group.honeytrap.name
  filter_pattern = "[time, request_id, event_type = \"authentication_success\", ...]"

  metric_transformation {
    name      = "HoneytrapAuthenticationSuccess"
    namespace = var.cloudwatch_namespace
    value     = "1"
    default_value = 0
  }
}

# Alert on any successful authentication (should never happen on a honeypot)
resource "aws_cloudwatch_metric_alarm" "honeytrap_auth_success" {
  alarm_name          = "${local.resource_name}-auth-success-alert"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  metric_name         = "HoneytrapAuthenticationSuccess"
  namespace           = var.cloudwatch_namespace
  period              = "60"
  statistic           = "Sum"
  threshold           = "1"
  alarm_description   = "CRITICAL: Authentication succeeded on Honeytrap (should never happen)"
  alarm_actions       = var.alert_sns_topic_arn != "" ? [var.alert_sns_topic_arn] : []
  treat_missing_data  = "notBreaching"

  tags = local.tags
}
