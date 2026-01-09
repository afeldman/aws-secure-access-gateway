variable "enable_mtls" {
  description = "Enable mTLS authentication. This is the primary access mode."
  type        = bool
  default     = true
}

variable "enable_ssh" {
  description = "Enable SSH fallback access. Only used if mTLS is disabled."
  type        = bool
  default     = false
}

variable "enable_twingate" {
  description = "Enable Twingate integration."
  type        = bool
  default     = false
}

variable "enable_kubectl_access" {
  description = "Attach EKS cluster policy to allow kubectl access from the gateway."
  type        = bool
  default     = false
}

variable "credential_source" {
  description = "The source for fetching credentials. Can be 'ssm' or '1password'."
  type        = string
  default     = "ssm"
  validation {
    condition     = contains(["ssm", "1password"], var.credential_source)
    error_message = "Valid values for credential_source are \"ssm\" or \"1password\"."
  }
}

variable "onepassword_vault" {
  description = "Name of the 1Password vault when credential_source is '1password'."
  type        = string
  default     = ""
}

variable "onepassword_item_prefix" {
  description = "Prefix applied to 1Password item names (slashes in keys are replaced with dashes)."
  type        = string
  default     = ""
}

variable "onepassword_connect_host" {
  description = "1Password Connect host URL (e.g., https://connect.example.com)."
  type        = string
  default     = ""
}

variable "onepassword_connect_token_param" {
  description = "SSM Parameter Store path that holds the 1Password Connect token (WithDecryption)."
  type        = string
  default     = ""
}

variable "mtls_proxy_type" {
  description = "The proxy to use for mTLS. Can be 'envoy', 'nginx', or 'caddy'."
  type        = string
  default     = "envoy"
  validation {
    condition     = contains(["envoy", "nginx", "caddy"], var.mtls_proxy_type)
    error_message = "Valid values for mtls_proxy_type are \"envoy\", \"nginx\", or \"caddy\"."
  }
}

variable "eks_cluster_name" {
  description = "The name of the EKS cluster to provide access to."
  type        = string
}

variable "vpc_id" {
  description = "The ID of the VPC where the EKS cluster resides."
  type        = string
}

variable "private_subnet_ids" {
  description = "A list of private subnet IDs where the gateway instance will be deployed."
  type        = list(string)
}

variable "region" {
  description = "AWS region used for API calls and resource configuration."
  type        = string
  default     = "eu-central-1"
}

variable "instance_type" {
  description = "EC2 instance type for the gateway host."
  type        = string
  default     = "t3.micro"
}

variable "root_volume_size" {
  description = "Root volume size in GiB for the gateway instance."
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

variable "tags" {
  description = "A map of tags to apply to all resources."
  type        = map(string)
  default     = {}
}
