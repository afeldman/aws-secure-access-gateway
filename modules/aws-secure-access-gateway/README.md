# AWS Secure Access Gateway Terraform Module

## Overview

This Terraform module deploys a secure access gateway for accessing private services within an AWS EKS cluster. It is designed with a zero-trust security model, prioritizing mTLS as the primary method of authentication and using AWS Systems Manager (SSM) Session Manager for connectivity. This approach ensures that no public ports are exposed to the internet.

This module is the first building block of the `aws-secure-access-gateway` solution.

## Features

- **Zero-Trust Access**: No public inbound ports. Access is established via AWS SSM Session Manager.
- **mTLS Authentication**: Enforces mutual TLS for secure communication between the developer and the gateway.
- **Dynamic Credential Management**: Fetches mTLS certificates at runtime from AWS SSM Parameter Store.
- **Honeytrap Decoy (Optional)**: Deployable honeypot sidecar for deception and detection with CloudWatch logging.
- **Private EKS Access**: Designed to provide access to services running in private EKS clusters.
- **Least Privilege IAM Roles**: The gateway instance runs with a minimal set of permissions.
- **Locked-down Egress**: Security group egress is restricted to the VPC CIDR, DNS, and required SSM endpoints only.

## Architecture (Phase 1)

This initial phase deploys a single EC2 instance into a private subnet. This instance is bootstrapped with the following components:
- **Envoy Proxy**: Acts as the mTLS termination point. It validates client certificates and forwards traffic. Envoy is run inside a Docker container for consistency.
- **`kubectl`**: Pre-installed for interacting with the EKS cluster.
- **Bootstrap Script**: A `user-data` script that fetches credentials and configures the instance on startup.

## Prerequisites

- Terraform >= 1.3.0
- An existing VPC and private subnets.
- An existing EKS cluster.
- mTLS certificates (CA, cert, key) stored in AWS SSM Parameter Store under the path `/${var.service_name}/secrets/mtls/*`.

## Usage

To use this module, include it in your Terraform configuration as follows:

```hcl
module "access_gateway" {
  source = "./modules/aws-secure-access-gateway"

  eks_cluster_name   = "my-private-eks-cluster"
  vpc_id             = "vpc-0123456789abcdef0"
  private_subnet_ids = ["subnet-0123456789abcdef0"]
  region             = "eu-central-1"
  instance_type      = "t3.small"
  root_volume_size   = 30

  service_name = "secure-gateway"
  environment  = "dev"

  tags = {
    "squad" = "platform-engineering"
    "client" = "internal"
  }
}
```

### Access modes and honeytrap
- Default mTLS: leave `access_mode` empty or set to `"mtls"` (legacy `enable_mtls` remains for compatibility).
- SSH fallback: set `access_mode = "ssh"` and ensure SSH keys are provided at runtime; this disables mTLS for the instance.
- Twingate: set `access_mode = "twingate"` to start the connector; tokens are fetched via SSM/1Password.
- Honeytrap: set `enable_honeytrap = true` to run the decoy listeners on `honeytrap_ports`; logs ship to the dedicated CloudWatch log group when enabled.
- Trusted forwarder: populate `trusted_forwarder_cidr` to restrict listener exposure to the central forwarder.

## Inputs

| Name                 | Description                                                               | Type           | Default     | Required |
| -------------------- | ------------------------------------------------------------------------- | -------------- | ----------- | :------: |
| `enable_mtls`        | Enable mTLS authentication.                                               | `bool`         | `true`      |    no    |
| `enable_ssh`         | Enable SSH fallback access. Only used if mTLS is disabled.                | `bool`         | `false`     |    no    |
| `enable_twingate`    | Enable Twingate integration.                                              | `bool`         | `false`     |    no    |
| `twingate_network`   | Twingate network name used by the connector.                               | `string`       | `""`       |    no    |
| `twingate_access_token_param` | SSM parameter path for the Twingate access token.                 | `string`       | `""`       |    no    |
| `twingate_refresh_token_param` | SSM parameter path for the Twingate refresh token.               | `string`       | `""`       |    no    |
| `enable_kubectl_access` | Attach AmazonEKSClusterPolicy for kubectl access from the gateway.     | `bool`         | `false`     |    no    |
| `credential_source`  | The source for fetching credentials. Can be 'ssm' or '1password'.         | `string`       | `"ssm"`     |    no    |
| `access_mode`        | Unified access mode selector: mtls (default), ssh, or twingate. Empty defers to legacy flags. | `string` | `""` | no |
| `enable_honeytrap`   | Enable Honeytrap deception service alongside the selected access mode.      | `bool`         | `false`      |    no    |
| `honeytrap_image`    | Honeytrap container image.                                                  | `string`       | `"ghcr.io/afeldman/honeytrap:latest"` | no |
| `honeytrap_ports`    | Honeytrap listener ports (decoy only).                                      | `list(number)` | `[2223,10023]` | no |
| `honeytrap_config_param` | Credential key/parameter for Honeytrap config payload.                  | `string`       | `""`        |    no    |
| `honeytrap_log_group_name` | CloudWatch log group for Honeytrap (defaults to gateway/honeytrap).   | `string`       | `""`        |    no    |
| `honeytrap_log_retention_days` | Retention for Honeytrap log group.                                | `number`       | `30`         |    no    |
| `trusted_forwarder_cidr` | List of trusted forwarder CIDRs allowed to hit listeners.               | `list(string)` | `[]`         |    no    |
| *Note* | Prefer `access_mode` for new deployments; legacy `enable_*` flags remain for backward compatibility. | - | - | - |
| `onepassword_vault`  | Vault name when using 1Password Connect.                                   | `string`       | `""`        |    no    |
| `onepassword_item_prefix` | Prefix to prepend to 1Password item names (slashes in keys become dashes). | `string`   | `""`        |    no    |
| `onepassword_connect_host` | 1Password Connect host URL.                                          | `string`       | `""`        |    no    |
| `onepassword_connect_token_param` | SSM parameter path containing the 1Password Connect token.    | `string`       | `""`        |    no    |
| `mtls_proxy_type`    | The proxy to use for mTLS. Can be 'envoy', 'nginx', or 'caddy'.           | `string`       | `"envoy"`   |    no    |
| `eks_cluster_name`   | The name of the EKS cluster to provide access to.                         | `string`       | -           |   yes    |
| `vpc_id`             | The ID of the VPC where the EKS cluster resides.                          | `string`       | -           |   yes    |
| `private_subnet_ids` | A list of private subnet IDs where the gateway instance will be deployed. | `list(string)` | -           |   yes    |
| `service_name`       | The name of this service, used for tagging and resource naming.           | `string`       | `"access-gateway"` | no    |
| `environment`        | The environment name (e.g., 'dev', 'staging', 'prod').                    | `string`       | `"dev"`     |    no    |
| `region`             | AWS region used for API calls and SSM prefix list selection.              | `string`       | `"eu-central-1"` | no |
| `enable_cloudwatch_logs` | Enable CloudWatch log shipping from the gateway.                      | `bool`         | `true`      |    no    |
| `log_group_name`     | CloudWatch Logs group for gateway logs (defaults to /aws/access-gateway/<service>/<env>). | `string` | `""` | no |
| `log_retention_days` | Retention in days for CloudWatch Logs.                                    | `number`       | `30`        |    no    |
| `enable_cloudwatch_metrics` | Enable CloudWatch agent metrics collection.                         | `bool`         | `true`      |    no    |
| `cloudwatch_namespace` | Namespace for host metrics published by the CloudWatch agent.          | `string`       | `"AccessGateway"` | no |
| `cloudwatch_log_group_name (output)` | Name of the CloudWatch log group receiving gateway logs.   | output         | -           |   -      |
| `instance_type`      | EC2 instance type for the gateway host.                                   | `string`       | `"t3.micro"` |    no    |
| `root_volume_size`   | Root volume size in GiB for the gateway instance.                         | `number`       | `20`         |    no    |
| `tags`               | A map of tags to apply to all resources.                                  | `map(string)`  | `{}`        |    no    |

## Outputs

| Name                 | Description                                                                    |
| -------------------- | ------------------------------------------------------------------------------ |
| `gateway_instance_id`| The ID of the EC2 instance running the access gateway.                         |
| `connection_command` | Example command to start an SSM session to the gateway instance.               |
| `kubeconfig_command` | Instructions on how to configure kubectl on the gateway instance.              |
| `service_endpoint`   | The local endpoint on the gateway that developers connect to for mTLS.         |
| `audit_logs_url`     | A pre-configured URL to view the audit logs for this gateway in CloudWatch.    |
