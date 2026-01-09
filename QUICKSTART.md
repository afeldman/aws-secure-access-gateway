# Honeytrap Integration - Quick Reference

## Files Created/Modified

### New Terraform Module (`modules/honeytrap-ec2/`)
- [x] `main.tf` – EC2, IAM, Security Groups, CloudWatch integration
- [x] `variables.tf` – Configuration parameters with validation
- [x] `outputs.tf` – Instance details, log groups, alarms
- [x] `templates/userdata.sh.tpl` – Bootstrap with Docker orchestration
- [x] `README.md` – Comprehensive usage guide

### New Kubernetes Templates (`charts/access-gateway/templates/`)
- [x] `honeytrap-deployment.yaml` – Deployment, Service, PDB
- [x] `configmap-honeytrap.yaml` – Configuration with security warnings
- [x] `networkpolicy.yaml` – Updated with Honeytrap isolation

### Updated Core Files
- [x] `charts/access-gateway/values.yaml` – Added honeytrap section
- [x] `README.md` – Added Honeytrap overview and deployment section
- [x] Maintained backward compatibility (honeytrap.enabled = false by default)

### New Documentation
- [x] `SECURITY.md` – Security architecture and validation procedures
- [x] `IMPLEMENTATION.md` – Implementation summary and deployment guide
- [x] `docs/HONEYTRAP-INTEGRATION.md` – Detailed integration guide
- [x] `examples/complete-deployment.tf` – Full example configuration
- [x] `scripts/validate-security.sh` – Automated security validation

## Security Checklist

### Network Security
- [x] No public IPs on Honeytrap instances
- [x] Restricted security group egress (VPC only, DNS only for K8s)
- [x] NetworkPolicy isolation in Kubernetes
- [x] Cannot reach gateway or real applications
- [x] Cannot reach EKS API or Internet

### Identity & Access
- [x] Minimal IAM role (SSM, CloudWatch only)
- [x] No EC2, EKS, S3, IAM, or STS permissions
- [x] No cross-account or assume-role capabilities
- [x] Authentication disabled in configuration

### Encryption & Secrets
- [x] Root volume encrypted (EBS, AES-256)
- [x] Secrets in SSM Parameter Store (SecureString)
- [x] TLS 1.3 for internal communication
- [x] CloudWatch Logs over HTTPS

### Monitoring & Detection
- [x] CloudWatch Logs integration
- [x] Structured JSON logging
- [x] CloudWatch Alarms (deception + critical auth)
- [x] SNS notifications for incidents
- [x] CloudWatch Insights queries

### Compliance
- [x] Audit trail (logs, metrics, CloudTrail)
- [x] Data minimization (no credentials in logs)
- [x] Configurable log retention
- [x] Incident response procedures documented
- [x] SOC 2, PCI-DSS, ISO 27001 mapping provided

## Deployment Options

### Option 1: EC2 Only (Recommended for Prod)
```hcl
module "honeytrap" {
  source = "./modules/honeytrap-ec2"
  enable_honeytrap = true
  # ... configuration ...
}
```

### Option 2: Kubernetes Only
```yaml
honeytrap:
  enabled: true
  # ... configuration ...
```

### Option 3: Both (Hybrid)
Deploy EC2 module AND enable in Helm chart for redundancy

### Option 4: Disabled (Default)
```hcl
enable_honeytrap = false  # No Honeytrap deployment
```

## Quick Start

### 1. Prerequisites
```bash
# Verify AWS credentials
aws sts get-caller-identity

# Create SNS topic for alerts (optional)
aws sns create-topic --name security-alerts
```

### 2. Deploy Honeytrap EC2
```hcl
# Add to main.tf
module "honeytrap" {
  source = "./modules/honeytrap-ec2"
  
  enable_honeytrap    = true
  vpc_id              = "vpc-0123456789abcdef0"
  private_subnet_ids  = ["subnet-aaa", "subnet-bbb"]
  region              = "eu-central-1"
  
  honeypot_ports      = [2223, 10023]
  trusted_source_cidr = []
  alert_sns_topic_arn = "arn:aws:sns:eu-central-1:123456789012:security-alerts"
  
  service_name = "internal-app"
  environment  = "prod"
}
```

### 3. Deploy Honeytrap in Kubernetes
```bash
# Update values.yaml
honeytrap:
  enabled: true

# Deploy
helm upgrade --install access-gateway ./charts/access-gateway \
  -n access-gateway -f values.yaml
```

### 4. Validate Security
```bash
export GATEWAY_INSTANCE_ID=i-xxxxxxx
export HONEYTRAP_INSTANCE_ID=i-yyyyyyy
export SERVICE_NAME=internal-app
export ENVIRONMENT=prod

./scripts/validate-security.sh
```

### 5. Verify Alarms
```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix honeytrap \
  --region eu-central-1
```

## Monitoring

### CloudWatch Logs

**Query for all connections:**
```
fields @timestamp, remote_ip, port, event_type
| filter @message like /connection/
| stats count() by remote_ip
```

**Query for authentication attempts:**
```
fields @timestamp, @message
| filter @message like /auth_attempt/
```

**Query for anomalies:**
```
fields @timestamp, anomaly_type
| filter @message like /detection|anomaly/
```

### CloudWatch Alarms

**Deception Alert:**
- Name: `honeytrap-activity`
- Metric: `HoneytrapConnectionCount`
- Threshold: >= 1 in 60 seconds
- Action: SNS notification

**Critical Alert:**
- Name: `honeytrap-auth-success-alert`
- Metric: `HoneytrapAuthenticationSuccess`
- Threshold: >= 1
- Action: **Page on-call immediately**

## Troubleshooting

### Check Logs
```bash
# EC2 logs
aws ssm start-session --target $HONEYTRAP_INSTANCE_ID
docker logs honeytrap
cat /var/log/user-data.log

# Kubernetes logs
kubectl logs -n access-gateway -l app.kubernetes.io/component=honeytrap
```

### Test Configuration
```bash
# Verify auth is disabled
aws ssm start-session --target $HONEYTRAP_INSTANCE_ID
grep "enabled = false" /etc/honeytrap/config.toml
```

### Check Isolation
```bash
# From honeytrap: should NOT reach app
curl -v http://app.default.svc.cluster.local:8080  # Should timeout

# From gateway: should reach honeytrap if testing
nc -zv <honeytrap-private-ip> 2223
```

## Security Validation Results

After deployment, run:
```bash
./scripts/validate-security.sh
```

Expected results:
```
[PASS] Gateway has no public IP
[PASS] Honeytrap has no public IP
[PASS] Security group restricts egress
[PASS] IAM role has minimal permissions
[PASS] Honeytrap authentication is disabled
[PASS] NetworkPolicy isolation configured

Validation Summary
Passed: 10
Failed: 0
```

## Key Outputs

```bash
# Gateway outputs
terraform output gateway_instance_id
terraform output gateway_cloudwatch_log_group

# Honeytrap outputs
terraform output honeytrap_instance_id
terraform output honeytrap_cloudwatch_log_group
terraform output honeytrap_alarm_activity_arn
terraform output honeytrap_alarm_auth_success_arn
```

## Important Security Properties

✅ **Honeytrap is NOT an access path**
- Cannot authenticate successfully
- Cannot reach real applications
- Cannot be used for lateral movement

✅ **Deception triggered on any connection**
- Logs all connection attempts
- Alerts on suspicious patterns
- Provides forensic data

✅ **Critical if authentication succeeds**
- Should NEVER happen (auth disabled)
- Immediate incident response required
- Indicates potential compromise

## Documentation

**Read First:**
1. [SECURITY.md](../SECURITY.md) – Security architecture
2. [docs/HONEYTRAP-INTEGRATION.md](../docs/HONEYTRAP-INTEGRATION.md) – Deployment guide
3. [modules/honeytrap-ec2/README.md](../modules/honeytrap-ec2/README.md) – EC2 submodule docs
4. [IMPLEMENTATION.md](../IMPLEMENTATION.md) – Implementation summary

**Reference:**
- [README.md](../README.md) – Main documentation
- [examples/complete-deployment.tf](../examples/complete-deployment.tf) – Full example
- [scripts/validate-security.sh](../scripts/validate-security.sh) – Validation script

## Support & Questions

**For architecture questions:**
- See [SECURITY.md](../SECURITY.md)

**For deployment issues:**
- See [docs/HONEYTRAP-INTEGRATION.md](../docs/HONEYTRAP-INTEGRATION.md#troubleshooting)

**For code issues:**
- See relevant README.md in the module directory
- Check `terraform plan` output for validation errors

## Compliance

Supports compliance with:
- ✅ SOC 2 Type II (encryption, logging, access control)
- ✅ PCI-DSS (isolation, encryption, audit)
- ✅ ISO 27001 (access control, monitoring, incident response)
- ✅ HIPAA (encryption, audit trails, access logging)
- ✅ GDPR (data minimization, encryption, deletion)

---

**Status:** ✅ Complete  
**Last Updated:** January 9, 2024  
**Maintainer:** Platform Security Team
