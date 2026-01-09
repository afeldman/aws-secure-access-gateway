# Honeytrap Integration Guide

This guide explains how to integrate Honeytrap as an optional defensive component into the AWS Secure Access Gateway.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Deployment Options](#deployment-options)
3. [Step-by-Step Deployment](#step-by-step-deployment)
4. [Configuration](#configuration)
5. [Monitoring & Alerting](#monitoring--alerting)
6. [Security Validation](#security-validation)
7. [Troubleshooting](#troubleshooting)

## Architecture Overview

### Components

```
┌─────────────────────────────────────────────────────────────────┐
│                     AWS Region                                   │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                   VPC (Private)                           │  │
│  │                                                           │  │
│  │  ┌──────────────────────┐    ┌──────────────────────┐  │  │
│  │  │  Secure Access       │    │  Honeytrap (Opt.)    │  │  │
│  │  │  Gateway EC2         │    │  EC2 Instance        │  │  │
│  │  │                      │    │                      │  │  │
│  │  │ ├─ mTLS Envoy       │    │ ├─ Fake SSH (2223)  │  │  │
│  │  │ ├─ SSH Fallback     │    │ ├─ Fake TCP (10023) │  │  │
│  │  │ └─ IAM (least priv) │    │ └─ Anomaly Detection│  │  │
│  │  │                      │    │                      │  │  │
│  │  └──────────────────────┘    └──────────────────────┘  │  │
│  │                                                           │  │
│  │  ┌──────────────────────────────────────────────────┐  │  │
│  │  │     EKS Cluster (Kubernetes)                     │  │  │
│  │  │                                                  │  │  │
│  │  │  ┌──────────────────┐  ┌──────────────────┐   │  │  │
│  │  │  │  Real Workloads  │  │ Honeytrap Pod    │   │  │  │
│  │  │  │  (Apps)          │  │ (K8s, optional)  │   │  │  │
│  │  │  │                  │  │                  │   │  │  │
│  │  │  └──────────────────┘  └──────────────────┘   │  │  │
│  │  │  NetworkPolicy:        NetworkPolicy:         │  │  │
│  │  │  ├─ Ingress allowed    ├─ Only honeypot     │  │  │
│  │  │  │  from gateway       │   ports allowed     │  │  │
│  │  │  ├─ Egress to services ├─ DNS only egress   │  │  │
│  │  │  └─ Deny honeytrap     └─ Cannot reach apps │  │  │
│  │  │                                              │  │  │
│  │  └──────────────────────────────────────────────┘  │  │
│  │                                                           │  │
│  │  ┌──────────────────────────────────────────────────┐  │  │
│  │  │  CloudWatch Logs & Alarms                        │  │  │
│  │  │                                                  │  │  │
│  │  │  ├─ /aws/access-gateway/...     (Gateway logs) │  │  │
│  │  │  ├─ /aws/honeytrap/...          (Honeytrap)   │  │  │
│  │  │  └─ Alarms:                                    │  │  │
│  │  │    ├─ HoneytrapActivity         (Deception)   │  │  │
│  │  │    └─ HoneytrapAuthSuccess      (CRITICAL)    │  │  │
│  │  │                                                  │  │  │
│  │  └──────────────────────────────────────────────────┘  │  │
│  │                                                           │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

External:
        SSM Session Manager ◄─────────► Developer's Laptop
        (only access method)            (mTLS client)
```

## Deployment Options

### Option 1: EC2 Only (Production Recommended)

Deploy Honeytrap as a **standalone EC2 instance** in the same VPC.

**Pros:**
- Isolated from Kubernetes
- Lower latency
- Separate incident scope
- Easier to manage and update

**Cons:**
- Additional infrastructure cost
- Separate log streams

**Module:** `./modules/honeytrap-ec2`

### Option 2: Kubernetes Only

Deploy Honeytrap as a **Kubernetes Deployment** in the same cluster as the gateway.

**Pros:**
- Single infrastructure management point
- Shared logging pipeline
- Easier multi-tenancy

**Cons:**
- Shares cluster resources
- NetworkPolicy must be strict to isolate

**Configuration:** `charts/access-gateway/values.yaml` → `honeytrap.enabled: true`

### Option 3: Both (Hybrid)

Deploy **both EC2 and Kubernetes** instances for redundancy and deception depth.

## Step-by-Step Deployment

### Prerequisites

1. **AWS Account & Credentials**
   ```bash
   aws configure
   export AWS_REGION=eu-central-1
   ```

2. **Terraform & Helm**
   ```bash
   terraform version  # >= 1.3
   helm version       # >= 3.0
   kubectl version    # >= 1.24
   ```

3. **VPC & EKS Cluster**
   ```bash
   # Ensure cluster exists
   aws eks describe-cluster --name prod-eks --region eu-central-1
   ```

4. **SNS Topic for Alerts** (optional but recommended)
   ```bash
   aws sns create-topic --name security-alerts --region eu-central-1
   ```

### Step 1: Deploy Gateway (if not already deployed)

```hcl
# main.tf
module "access_gateway" {
  source = "./modules/aws-secure-access-gateway"
  
  eks_cluster_name   = "prod-eks"
  vpc_id             = "vpc-0123456789abcdef0"
  private_subnet_ids = ["subnet-aaa", "subnet-bbb"]
  region             = "eu-central-1"
  
  enable_mtls = true
  enable_ssh  = false
  
  service_name = "internal-app"
  environment  = "prod"
}
```

Deploy:
```bash
terraform init
terraform plan
terraform apply -auto-approve
```

### Step 2: Deploy Honeytrap (EC2)

```hcl
# main.tf
module "honeytrap" {
  source = "./modules/honeytrap-ec2"
  
  enable_honeytrap    = true
  vpc_id              = "vpc-0123456789abcdef0"
  private_subnet_ids  = ["subnet-aaa", "subnet-bbb"]
  region              = "eu-central-1"
  
  honeypot_ports      = [2223, 10023]
  trusted_source_cidr = []  # Deny all external access
  
  alert_sns_topic_arn = "arn:aws:sns:eu-central-1:123456789012:security-alerts"
  
  service_name = "internal-app"
  environment  = "prod"
}
```

Deploy:
```bash
terraform apply -auto-approve
```

Verify:
```bash
# Check instance is running
HONEYTRAP_ID=$(terraform output -raw honeytrap_instance_id)
aws ec2 describe-instances --instance-ids "$HONEYTRAP_ID"

# Check CloudWatch logs exist
aws logs describe-log-groups --log-group-name-prefix "honeytrap"
```

### Step 3: Deploy Honeytrap in Kubernetes (Optional)

Update Helm values:
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
```

Deploy:
```bash
helm upgrade --install access-gateway ./charts/access-gateway \
  -n access-gateway \
  -f values.yaml
```

Verify:
```bash
# Check pod is running
kubectl get pods -n access-gateway -l app.kubernetes.io/component=honeytrap

# Check NetworkPolicy
kubectl get networkpolicy -n access-gateway
```

## Configuration

### Honeytrap Configuration File

Create custom config in SSM Parameter Store:

```toml
# Save to: /internal-app/prod/honeytrap/config.toml
[network]
bind_addr = "0.0.0.0:2223"
timeout = 300

[logging]
level = "info"
format = "json"

[auth]
enabled = false  # CRITICAL: Never enable

[[honeypots]]
port = 2223
service_type = "ssh"
banner = "OpenSSH_7.4"
interaction_level = "minimal"

[[honeypots]]
port = 10023
service_type = "tcp"
interaction_level = "minimal"

[detection]
enabled = true
heuristics = ["port_scan", "credential_enumeration"]
```

Upload to SSM:
```bash
aws ssm put-parameter \
  --name "/internal-app/prod/honeytrap/config" \
  --type "SecureString" \
  --value "$(cat honeytrap-config.toml)" \
  --region eu-central-1
```

Reference in Terraform:
```hcl
module "honeytrap" {
  # ...
  honeytrap_config_param = "/internal-app/prod/honeytrap/config"
}
```

### Environment Variables

Set in Honeytrap pod/container:

| Variable | Default | Purpose |
|----------|---------|---------|
| `HONEYTRAP_CONFIG` | `/etc/honeytrap/config.toml` | Config file path |
| `RUST_LOG` | `info` | Log level |
| `HONEYTRAP_LOG_LEVEL` | `info` | Honeytrap-specific log level |
| `HONEYTRAP_ROLE` | `deception-only` | Role identifier |
| `HONEYTRAP_ALERT_ON_AUTH` | `true` | Alert if auth succeeds |

## Monitoring & Alerting

### CloudWatch Logs

**Log Groups:**
- **EC2 Honeytrap:** `/aws/honeytrap/{service}/{environment}`
- **Kubernetes Honeytrap:** Container logs in same namespace

**Example Queries:**

Find all connections to honeypots:
```
fields @timestamp, remote_ip, port, event_type
| filter @message like /connection/
| stats count() by remote_ip, port
```

Find anomaly detections:
```
fields @timestamp, anomaly_type, severity
| filter @message like /anomaly|detection/
| stats count() by anomaly_type
```

Check for authentication attempts:
```
fields @timestamp, @message
| filter @message like /auth_attempt/
```

### CloudWatch Alarms

**Alarms Created Automatically:**

1. **HoneytrapActivityDetected**
   - Metric: `HoneytrapConnectionCount`
   - Threshold: >= 1 connection in 60 seconds
   - Action: SNS notification (if topic ARN provided)

2. **HoneytrapAuthenticationSuccess** (CRITICAL)
   - Metric: `HoneytrapAuthenticationSuccess`
   - Threshold: >= 1 successful auth
   - Action: **Immediate SNS notification + page on-call**

**Check Alarm Status:**
```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "honeytrap" \
  --region eu-central-1 \
  --query 'MetricAlarms[*].[AlarmName,StateValue,StateReason]'
```

### Custom Metrics

Honeytrap publishes metrics to CloudWatch:

```bash
# View Honeytrap metrics
aws cloudwatch list-metrics \
  --namespace "Honeytrap" \
  --region eu-central-1
```

**Available Metrics:**
- `HoneytrapConnectionCount` – Number of connections to honeypots
- `HoneytrapAuthenticationSuccess` – Successful authentications (should be 0)
- `HoneytrapAnomalyCount` – Number of anomalies detected

## Security Validation

### Pre-Deployment Checklist

- [ ] NetworkPolicy enabled in EKS cluster
- [ ] VPC has no Internet gateway for private subnets
- [ ] mTLS certificates stored in SSM Parameter Store (SecureString)
- [ ] SNS topic created for alerts
- [ ] CloudWatch log retention policy meets compliance
- [ ] IAM roles reviewed for least privilege
- [ ] Security groups restrict egress

### Post-Deployment Validation

```bash
# Run security validation script
export GATEWAY_INSTANCE_ID=i-xxxxxxx
export HONEYTRAP_INSTANCE_ID=i-yyyyyyy
export SERVICE_NAME=internal-app
export ENVIRONMENT=prod

./scripts/validate-security.sh
```

**Expected Output:**
```
[PASS] Gateway has no public IP
[PASS] Gateway security group restricts egress correctly
[PASS] Gateway requires IMDSv2
[PASS] Honeytrap has no public IP
[PASS] Honeytrap security group restricts egress
[PASS] Honeytrap authentication is disabled
[PASS] Honeytrap has recorded zero successful authentications
```

### Manual Verification

**1. Test Honeytrap Isolation:**

```bash
# Connect to gateway
aws ssm start-session --target $GATEWAY_INSTANCE_ID

# Try to reach Honeytrap honeypot from gateway (should work if traffic is allowed)
nc -zv <honeytrap-private-ip> 2223

# Test from Honeytrap: should NOT reach real apps
aws ssm start-session --target $HONEYTRAP_INSTANCE_ID
curl -v http://app.default.svc.cluster.local:8080  # Should timeout
```

**2. Verify Authentication is Disabled:**

```bash
# Connect to Honeytrap
aws ssm start-session --target $HONEYTRAP_INSTANCE_ID

# Try to SSH (should not authenticate)
ssh -v localhost -p 2223
# Expected: Connection refused or timeout, NOT successful auth
```

**3. Check CloudWatch Logs:**

```bash
# Should see connections but NO successful authentications
aws logs filter-log-events \
  --log-group-name "/aws/honeytrap/prod" \
  --filter-pattern "authentication_success" \
  --region eu-central-1
# Expected: No results
```

## Troubleshooting

### Honeytrap Container Not Starting

**Symptoms:** Pod/Container is not running, CrashLoopBackOff in Kubernetes.

**Debug:**

```bash
# For Kubernetes
kubectl logs <honeytrap-pod> -n access-gateway
kubectl describe pod <honeytrap-pod> -n access-gateway

# For EC2
aws ssm start-session --target $HONEYTRAP_INSTANCE_ID
docker logs honeytrap
cat /var/log/user-data.log
```

**Common Issues:**

1. **Image pull failed:**
   ```bash
   docker pull ghcr.io/afeldman/honeytrap:latest
   ```

2. **Port already in use:**
   ```bash
   # Check if port is already bound
   ss -tlnp | grep 2223
   # Kill the process and restart
   docker restart honeytrap
   ```

3. **Configuration file missing:**
   ```bash
   # Verify config file exists
   cat /etc/honeytrap/config.toml
   # Check syntax
   cat /etc/honeytrap/config.toml | grep -A 10 "\[network\]"
   ```

### Logs Not Appearing in CloudWatch

**Symptoms:** CloudWatch Logs group exists but no log streams.

**Debug:**

```bash
# Check CloudWatch agent status
systemctl status amazon-cloudwatch-agent

# Check agent config
cat /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# View agent logs
journalctl -u amazon-cloudwatch-agent -n 50

# For Kubernetes: check container logs driver
kubectl describe pod <honeytrap-pod> | grep -A 10 "Containers:"
```

### Alarms Not Firing

**Symptoms:** Honeytrap connections are logged but alarms don't trigger.

**Debug:**

```bash
# Check alarm configuration
aws cloudwatch describe-alarms --alarm-names "honeytrap-activity"

# Manually publish test metric
aws cloudwatch put-metric-data \
  --namespace "Honeytrap" \
  --metric-name "HoneytrapConnectionCount" \
  --value 5 \
  --region eu-central-1

# Check if alarm state changes
sleep 60
aws cloudwatch describe-alarms --alarm-names "honeytrap-activity"
```

### Authentication Succeeded (CRITICAL)

**Symptoms:** `HoneytrapAuthenticationSuccess` alarm fires.

**Immediate Actions:**

```bash
# 1. ISOLATE the instance
aws ec2 modify-instance-attribute \
  --instance-id $HONEYTRAP_INSTANCE_ID \
  --no-source-dest-check

# 2. Collect forensics
aws ssm start-session --target $HONEYTRAP_INSTANCE_ID
docker logs honeytrap > /tmp/honeytrap-forensics.log
cat /var/log/honeytrap/* >> /tmp/honeytrap-forensics.log

# 3. Escalate to security team
# (Create incident, page on-call security)

# 4. Review: How did auth succeed if disabled in config?
# Possible causes:
# - Config file was modified
# - Honeytrap image has vulnerability
# - Compromised instance
```

## References

- [Honeytrap GitHub](https://github.com/afeldman/honeytrap)
- [AWS CloudWatch Alarms](https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/WhatIsCloudWatchEvents.html)
- [Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [AWS Deception & Detection](https://aws.amazon.com/security/deception/)
