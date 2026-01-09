# AWS Secure Access Gateway

Zero-trust access path to private EKS workloads. No public ports, mTLS by default, SSH only as an explicit fallback, optional Twingate connector, and SSM Session Manager for every hop.

## What this provides
- **Gateway host (Terraform):** EC2 in private subnets, SSM-managed, mTLS Envoy proxy, optional SSH-only mode, optional Twingate connector. IAM least privilege, IMDSv2, encrypted root volume, locked-down egress. See [modules/aws-secure-access-gateway](modules/aws-secure-access-gateway).
- **In-cluster components (Helm):** Conditional sidecars (Envoy/SSH/Twingate), ExternalSecret wiring, NetworkPolicy, PDB, minimal RBAC. See [charts/access-gateway](charts/access-gateway).
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

## Troubleshooting
- SSM session fails: verify VPC endpoints for SSM/SSMMessages/EC2Messages and instance profile `AmazonSSMManagedInstanceCore` attached.
- mTLS handshake fails: confirm client cert chain matches CA in `mtls-certs` and server key/cert paths in SSM/1Password.
- Envoy health: check CloudWatch log stream `{instance_id}/envoy` or `docker logs envoy` via SSM shell.
