# AWS Secure Access Gateway

Zero-trust access path to private EKS workloads. No public ports, mTLS by default, SSH only as an explicit fallback, optional Twingate connector, optional Honeytrap deception/detection component, and SSM Session Manager for every hop.

## What this provides
- **Gateway host (Terraform):** EC2 in private subnets, SSM-managed, mTLS Envoy proxy, optional SSH-only mode, optional Twingate connector. IAM least privilege, IMDSv2, encrypted root volume, locked-down egress. See [modules/aws-secure-access-gateway](modules/aws-secure-access-gateway).
- **In-cluster components (Helm):** Conditional sidecars (Envoy/SSH/Twingate), optional Honeytrap honeypots, ExternalSecret wiring, NetworkPolicy (with Honeytrap isolation), PDB, minimal RBAC. See [charts/access-gateway](charts/access-gateway).
- **Optional Honeytrap deception (Terraform submodule):** Standalone EC2 instance with fake SSH/TCP services, anomaly detection, CloudWatch Logs/Alarms integration. See [modules/honeytrap-ec2](modules/honeytrap-ec2).
- **Developer entrypoint:** [connect.sh](connect.sh) starts an SSM port-forwarding session to the gateway and exposes the listener locally (mTLS default, SSH fallback).

## Prerequisites
- AWS CLI + `session-manager-plugin` installed locally.
- Terraform >= 1.3 and Helm 3.x available in CI/GitOps.
- Existing private EKS cluster and VPC with private subnets; SSM endpoints reachable (via VPC endpoints or NAT).
- mTLS materials (CA, cert, key) stored in SSM Parameter Store under `/${service_name}/secrets/mtls/{ca,cert,key}` or in 1Password (if `credential_source = "1password"`).
- For SSH fallback: `/${service_name}/secrets/ssh/authorized_keys` (or equivalent in 1Password).
- For Twingate (optional): access/refresh tokens in SSM or 1Password and a network name.
- WAF/ALB: upstream applications can still sit behind WAF/ALB; the gateway does not open public ports. Traffic reaches the cluster via private networking, SSM session, and Envoy on the gateway.

## Deploy the gateway host (Terraform)
Example minimal configuration:
```hcl
module "access_gateway" {
	source             = "./modules/aws-secure-access-gateway"
	eks_cluster_name   = "prod-eks"
	vpc_id             = "vpc-0123456789abcdef0"
	private_subnet_ids = ["subnet-aaa", "subnet-bbb"]
	region             = "eu-central-1"

	# Security defaults
	enable_mtls   = true
	enable_ssh    = false
	enable_twingate = false

	# Optional: 1Password Connect
	# credential_source = "1password"
	# onepassword_vault = "platform"

	tags = {
		client      = "internal"
		environment = "prod"
		service     = "access-gateway"
		squad       = "platform"
	}
}
```
After `terraform apply`, note outputs:
- `gateway_instance_id` – used by `connect.sh`.
- `connection_command` – SSM start-session example.
- `kubeconfig_command` – run on the gateway to configure kubectl.
- `cloudwatch_log_group_name` – gateway logs/metrics.

## Deploy in-cluster components (Helm / GitOps)
Set values in your GitOps repo, for example:
```yaml
mtls:
	enabled: true
	proxy:
		port: 10000
		adminPort: 9901
	certSecretName: mtls-certs

externalSecrets:
	enabled: true
	backendType: awsParameterStore
	path: /access-gateway/secrets
	mtls:
		enabled: true
		secretName: mtls-certs
		keys:
			ca: ca.crt
			cert: tls.crt
			key: tls.key

pdb:
	enabled: true

networkPolicy:
	enabled: true
```
Apply via your GitOps controller (FluxCD/ArgoCD) or directly: `helm upgrade --install access-gateway charts/access-gateway -n access-gateway -f values.yaml`.

Modes in the chart (mutually exclusive):
- mTLS (default): Envoy sidecar with certificates from `mtls-certs` secret.
- SSH fallback: enable `ssh.enabled=true` and disable mTLS.
- Twingate: enable `twingate.enabled=true` with token secrets; disable mTLS/SSH in the chart.

## Secrets layout (SSM Parameter Store)
- mTLS: `/${service_name}/secrets/mtls/ca`, `/cert`, `/key` (SecureString).
- SSH: `/${service_name}/secrets/ssh/authorized_keys` (SecureString, newline-separated keys).
- Twingate (optional): `/${service_name}/secrets/twingate/access_token`, `/refresh_token`.
If using 1Password, store corresponding items and set `credential_source = "1password"` plus vault/prefix variables.

## Connect from your laptop (mTLS default)
1) Export the gateway instance ID (from Terraform output):
```bash
export GATEWAY_INSTANCE_ID=i-0123456789abcdef0
```
2) Start the SSM port forward (mTLS listener 10000 locally):
```bash
./connect.sh --service internal-app --local-port 10000
```
3) Point your client or port-forwarder at `https://localhost:10000` with your mTLS client certs. Envoy on the gateway validates the client cert and forwards to the configured upstream.

### Using SSH fallback (only when mTLS disabled)
```bash
./connect.sh --mode ssh --target "$GATEWAY_INSTANCE_ID" --local-port 2222 --remote-port 2222
ssh -p 2222 ssm-user@localhost
```
SSH is locked to localhost on the gateway and key-only; all transport is still inside the SSM tunnel.

### Accessing the EKS API via the gateway
On the gateway host (after connecting via SSM):
```bash
aws eks --region eu-central-1 update-kubeconfig --name prod-eks
kubectl get nodes
```
If you need kubectl from your laptop, port-forward the EKS API through Envoy or run kubectl on the gateway via SSM `session-manager-plugin` interactive shell.

## AWS integration notes
- **No public ingress:** The EC2 gateway has no public IP; all access is via SSM Session Manager.
- **WAF/ALB:** Keep existing WAF/ALB protections for app endpoints. The gateway is an additional private hop, not a replacement for WAF policies.
- **SSM endpoints:** Ensure VPC interface endpoints for `ssm`, `ssmmessages`, and `ec2messages` (or NAT access) so the gateway can register and maintain sessions.
- **CloudWatch:** Logs and metrics ship to the configured log group; adjust `log_retention_days` as required by policy.

## Security defaults
- IMDSv2 required, no public IP, SG egress restricted to VPC and AWS endpoints.
- mTLS is default; SSH and Twingate are opt-in and mutually exclusive with mTLS in the chart.
- Secrets are fetched at runtime (SSM or 1Password); no secrets in images or Git.

## Optional: Deploy Honeytrap for deception & detection

**What is Honeytrap?**
Honeytrap is a Rust-based **deception and detection component** that sits alongside your gateway. It exposes fake SSH/TCP services ("honeypots") to detect and analyze attack attempts. It is **NOT an access path** to your applications; it only serves to deceive attackers and trigger alerts.

### Deploy as standalone EC2 (recommended for production)

Create a Terraform submodule call:

```hcl
module "honeytrap" {
  source              = "./modules/honeytrap-ec2"
  
  enable_honeytrap    = true
  vpc_id              = "vpc-0123456789abcdef0"
  private_subnet_ids  = ["subnet-aaa", "subnet-bbb"]
  region              = "eu-central-1"
  
  # Configure honeypot ports (fake services)
  honeypot_ports      = [2223, 10023]  # Fake SSH, fake TCP
  
  # Restrict access to Honeytrap honeypots (for testing/deception)
  # Leave empty to disable external access entirely
  trusted_source_cidr = []
  
  # Alerting on suspicious activity
  alert_sns_topic_arn = "arn:aws:sns:eu-central-1:123456789012:security-alerts"
  
  service_name  = "internal-app"
  environment   = "prod"
  
  tags = {
    environment = "prod"
    squad       = "platform"
  }
}
```

**Outputs:**
- `honeytrap_instance_id` – EC2 instance ID
- `cloudwatch_log_group_name` – Where to find Honeytrap logs
- `alarm_activity_arn` – Alert on deception triggered
- `alarm_auth_success_arn` – Critical alarm if auth succeeds (should never happen)

### Deploy in Kubernetes (optional, for in-cluster deception)

Enable in Helm values:

```yaml
honeytrap:
  enabled: true
  image: ghcr.io/afeldman/honeytrap:latest
  replicaCount: 1
  ports:
    - name: honeytrap-ssh
      port: 2223
      protocol: TCP
    - name: honeytrap-tcp
      port: 10023
      protocol: TCP
  logLevel: info
  probes:
    enabled: true
```

### Honeytrap Security Validation

1. **Network Isolation:**
   - Honeytrap NetworkPolicy restricts egress to DNS only.
   - Cannot reach real application endpoints or gateway.
   - Cannot be used as an access path.

2. **Authentication Disabled:**
   - Configuration explicitly disables all auth mechanisms.
   - Any successful auth attempt triggers a CRITICAL alarm.

3. **Logging & Alerting:**
   - All connections logged to CloudWatch Logs.
   - Structured JSON logs for easy analysis.
   - Real-time alarms on suspicious patterns.

4. **Validation Queries (CloudWatch Logs Insights):**
   
   Find all connection attempts:
   ```
   fields @timestamp, remote_ip, port
   | filter @message like /connection/
   | stats count() by remote_ip
   ```
   
   Find authentication attempts (should be 0):
   ```
   fields @timestamp, @message
   | filter @message like /auth_attempt|authentication_success/
   ```

### Honeytrap Architecture

```
┌─────────────────────────────────────┐
│ AWS Secure Access Gateway (real)    │
│ ├─ mTLS Envoy Proxy                 │
│ └─ Real access to EKS apps          │
└──────────────┬──────────────────────┘
               │ (SSM Session Manager)
               ▼
        [Developer's laptop]


┌─────────────────────────────────────┐
│ Honeytrap (deception only)          │
│ ├─ Fake SSH on 2223                 │
│ ├─ Fake TCP on 10023                │
│ └─ Anomaly detection                │
└──────────────┬──────────────────────┘
               │ (Exposed to tests/scanners)
               ▼
     [Attack detection lab]
```

### Honeytrap Best Practices

1. **Don't expose honeypots to the Internet directly.** Use them for:
   - Internal red-team testing
   - Lateral movement detection within VPC
   - Attacker profiling and analysis

2. **Monitor alarms closely.** Any connection to a honeypot indicates:
   - Scanning activity in your VPC
   - Compromised asset attempting lateral movement
   - Red-team exercise in progress

3. **Ensure authentication never succeeds.** If it does, it's a critical security event:
   ```bash
   # Check for auth successes (should be empty)
   aws logs filter-log-events \
     --log-group-name "/aws/honeytrap/prod" \
     --filter-pattern "authentication_success"
   ```

4. **Keep logs for forensics.** Default retention is 30 days; adjust as needed for compliance.

5. **Test regularly.** Use Terraform outputs to verify logs/alarms are working:
   ```bash
   # Check Honeytrap status
   aws ssm start-session --target $(terraform output -raw honeytrap_instance_id)
   docker logs honeytrap
   ```

See [modules/honeytrap-ec2/README.md](modules/honeytrap-ec2/README.md) for detailed configuration, troubleshooting, and security validation.

## Troubleshooting
- SSM session fails: verify VPC endpoints for SSM/SSMMessages/EC2Messages and instance profile `AmazonSSMManagedInstanceCore` attached.
- mTLS handshake fails: confirm client cert chain matches CA in `mtls-certs` and server key/cert paths in SSM/1Password.
- Envoy health: check CloudWatch log stream `{instance_id}/envoy` or `docker logs envoy` via SSM shell.

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.
