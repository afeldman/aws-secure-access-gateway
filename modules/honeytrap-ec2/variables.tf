variable "enable_honeytrap" {
  description = "Enable the Honeytrap deception component (defensive use only)."
  type        = bool
  default     = false
}

variable "vpc_id" {
  description = "The ID of the VPC where Honeytrap will be deployed."
  type        = string
}

variable "private_subnet_ids" {
  description = "A list of private subnet IDs where the Honeytrap instance will be deployed."
  type        = list(string)
}

variable "region" {
  description = "AWS region used for API calls and resource configuration."
  type        = string
  default     = "eu-central-1"
}

variable "honeytrap_image" {
  description = "Container image URI for Honeytrap (Rust-based deception/detection)."
  type        = string
  default     = "ghcr.io/afeldman/honeytrap:latest"
}

variable "honeypot_ports" {
  description = "List of TCP ports to expose for the Honeytrap honeypots (fake services). Default: [2223, 10023]."
  type        = list(number)
  default     = [2223, 10023]
  validation {
    condition = alltrue([
      for port in var.honeypot_ports : port > 1024 && port < 65536
    ])
    error_message = "All honeypot_ports must be between 1024 and 65535 (unprivileged range)."
  }
}

variable "trusted_source_cidr" {
  description = "List of CIDR blocks from which Honeytrap honeypots can be accessed (for deception/testing). Default: empty (no access)."
  type        = list(string)
  default     = []
}

variable "honeytrap_config_param" {
  description = "Optional SSM Parameter Store path for Honeytrap configuration (TOML format). If not provided, default minimal config is used."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for the Honeytrap host."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size" {
  description = "Root volume size in GiB for the Honeytrap instance."
  type        = number
  default     = 20
}

variable "service_name" {
  description = "The name of this service, used for tagging and resource naming."
  type        = string
  default     = "access-gateway"
}

variable "environment" {
  description = "The environment name (e.g., 'dev', 'staging', 'prod')."
  type        = string
  default     = "dev"
}

variable "enable_cloudwatch_logs" {
  description = "Enable CloudWatch log shipping from the Honeytrap instance."
  type        = bool
  default     = true
}

variable "log_group_name" {
  description = "CloudWatch Logs group for Honeytrap logs (defaults to /aws/honeytrap/<service>/<env>)."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  description = "Retention in days for CloudWatch Logs."
  type        = number
  default     = 30
}

variable "enable_anomaly_detection" {
  description = "Enable Honeytrap's built-in anomaly detection and heuristic analysis."
  type        = bool
  default     = true
}

variable "cloudwatch_namespace" {
  description = "CloudWatch metrics namespace for Honeytrap metrics."
  type        = string
  default     = "Honeytrap"
}

variable "alert_sns_topic_arn" {
  description = "SNS topic ARN to send Honeytrap alerts/alarms to. Leave empty to disable SNS notifications."
  type        = string
  default     = ""
}

variable "alarm_threshold" {
  description = "CloudWatch alarm threshold for Honeytrap connection count. Default: 1 (alert on any connection)."
  type        = number
  default     = 1
}

variable "tags" {
  description = "A map of tags to apply to all resources."
  type        = map(string)
  default     = {}
}
