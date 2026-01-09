# AWS Secure Access Gateway

Zero-trust gateway for private EKS access (Terraform module + Helm chart + connect helper).

## Quick start
- Provision gateway with Terraform module in `modules/aws-secure-access-gateway`.
- Deploy in-cluster components with Helm chart in `charts/access-gateway` via GitOps.
- Connect via SSM port forwarding using `./connect.sh`.

## connect.sh
```bash
./connect.sh --target i-0123456789abcdef0 --service datalynq-alfa --local-port 8080
./connect.sh --mode ssh --target i-0123456789abcdef0 --local-port 2222
```
- Default mode: `mtls` on port 10000 (local and remote). SSH fallback uses port 2222 by default.
- Requires `aws` CLI and `session-manager-plugin` available locally.
- Uses SSM Session Manager; no public ports exposed.

## Components
- Terraform module: `modules/aws-secure-access-gateway` (EC2 gateway, IAM, SG, userdata for mTLS/SSH/Twingate).
- Helm chart: `charts/access-gateway` (conditional sidecars, ExternalSecret, PDB, NetworkPolicy).
- Script: `connect.sh` (developer entrypoint via SSM port forwarding).
