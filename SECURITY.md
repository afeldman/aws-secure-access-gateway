# Security Architecture & Validation Guide

This document describes the security design of AWS Secure Access Gateway with optional Honeytrap deception/detection component.

## Table of Contents

1. [Zero-Trust Architecture](#zero-trust-architecture)
2. [Honeytrap Integration](#honeytrap-integration)
3. [Security Validation Checklist](#security-validation-checklist)
4. [Incident Response](#incident-response)
5. [Compliance Considerations](#compliance-considerations)

## Zero-Trust Architecture

### Access Control Model

```
External Request
     │
     ├─→ [Internet] (NO PUBLIC PORTS) ────┐
     │                                      │
     ├─→ [VPC Private Subnet]               │ DENIED
     │    ├─ SSM Endpoint (Private Link)   │
     │    └─ VPC Interface Endpoints       │
     │         │                            │
     │         ▼                            │
     │    [SSM Session Manager]             │
     │         │                            │
     │         ▼                            │
     │    [Gateway EC2 Instance]            │
     │    ├─ IAM Role (least privilege)    │
     │    ├─ mTLS Envoy Proxy              │
     │    ├─ SSH Fallback (key-only)       │
     │    └─ NetworkPolicy (K8s)           │
     │         │                            │
     └─────────▶ [Private EKS Cluster]     │ ALLOWED (mTLS or SSH verified)
               ├─ Ingress via Gateway       │
               └─ Pod NetworkPolicy         │
```

### Security Layers

| Layer | Component | Validation | Enforcement |
|-------|-----------|-----------|--------------|
| **1. Network** | AWS VPC, SG | No public IPs, egress restricted | iptables, SG rules |
| **2. Transport** | SSM Session Manager | User AWS credentials | IAM policies |
| **3. Authentication** | mTLS (TLS 1.3) | Client cert + CA validation | Envoy |
| **4. Encryption** | TLS in transit, encrypted root volume | AES-256 | AWS KMS (root) |
| **5. Identity** | IAM + RBAC | Role-based access | AWS IAM, K8s RBAC |
| **6. Detection** | CloudWatch Logs/Alarms | Audit trail, anomalies | Honeytrap (optional) |

## Honeytrap Integration

### Honeytrap Security Design

Honeytrap is a **detection and deception component**, not an access path. Its role is to:

1. **Deceive:** Expose fake SSH/TCP services to attract attackers.
2. **Detect:** Log all connection attempts for analysis.
3. **Alert:** Trigger CloudWatch alarms on suspicious patterns.
4. **Isolate:** Be completely isolated from real access paths via NetworkPolicy.

### Network Isolation (Kubernetes)

**Honeytrap-specific NetworkPolicy:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: access-gateway-honeytrap-isolation
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/component: honeytrap
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow traffic ONLY to honeypot ports from within namespace
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: default
      ports:
        - protocol: TCP
          port: 2223  # Fake SSH
        - protocol: TCP
          port: 10023 # Fake TCP
  egress:
    # Allow DNS ONLY (no other network access)
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
```

**Key Points:**
- Honeytrap can receive connections on honeypot ports only.
- No egress to other services, namespaces, or the Internet.
- Cannot reach EKS API, application endpoints, or gateway.

### Network Isolation (EC2)

**Security Group Rules:**

```
Ingress:
  - Honeypot ports (2223, 10023) from trusted_source_cidr (if testing)
  - Default: No ingress (access via SSM Session Manager only)

Egress:
  - 443 (HTTPS) to VPC CIDR (CloudWatch, SSM endpoints only)
  - 53 (DNS) to VPC CIDR (service discovery)
  - NO access to Internet, other VPCs, or peered networks
```

### IAM Policy Isolation

**Honeytrap EC2 Instance IAM Role:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SSM",
      "Effect": "Allow",
      "Action": ["ssm:GetParameter", "ssm:GetParameters"],
      "Resource": "arn:aws:ssm:region:account:parameter/honeytrap/*"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:CreateLogGroup"
      ],
      "Resource": "arn:aws:logs:region:account:log-group:/aws/honeytrap/*"
    },
    {
      "Sid": "CloudWatchMetrics",
      "Effect": "Allow",
      "Action": ["cloudwatch:PutMetricData"],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "cloudwatch:namespace": "Honeytrap"
        }
      }
    }
  ]
}
```

**Critically Denied:**
- Access to EC2 API (no TerminateInstances, RunInstances, etc.)
- Access to EKS API (no DescribeClusters, GetClusterAuth, etc.)
- Access to S3, DynamoDB, or other data services
- Cross-account access or assume-role permissions

### Authentication Disabled

Honeytrap configuration **explicitly disables all authentication**:

```toml
[auth]
enabled = false

[alerts]
alert_on_auth_attempt = "CRITICAL"
```

**Validation:** If any `authentication_success` metric is recorded, it's a critical security violation and requires immediate investigation.

## Security Validation Checklist

### Pre-Deployment

- [ ] **IAM Policies:** Review all IAM policies for least privilege (deny everything by default).
- [ ] **Network Policies:** Ensure NetworkPolicy is enabled in EKS cluster.
- [ ] **VPC Configuration:** Verify private subnets, VPC endpoints (SSM, etc.), and no Internet gateway.
- [ ] **Secrets:** Store mTLS certs, SSH keys, and Honeytrap config in SSM Parameter Store (SecureString) or 1Password.
- [ ] **Root Volume Encryption:** Verify EBS encryption enabled for gateway and Honeytrap instances.
- [ ] **Security Group Rules:** Validate egress restrictions and no public ingress.

### Post-Deployment

**Gateway Health:**
```bash
# Check gateway logs
aws logs tail /aws/access-gateway/prod --follow

# Verify Envoy is running
aws ssm start-session --target i-gateway-id
docker ps | grep envoy
docker logs envoy

# Check mTLS handshakes (should see successful connections)
grep "upstream_cx_connect_success" /var/log/envoy/envoy.log
```

**Honeytrap Validation:**
```bash
# Check honeytrap logs (should be empty or show decoy attempts)
aws logs tail /aws/honeytrap/prod --follow

# Query for authentication attempts (should be ZERO)
aws logs filter-log-events \
  --log-group-name "/aws/honeytrap/prod" \
  --filter-pattern "authentication_success" \
  --query 'events[*].[timestamp,message]'

# Check CloudWatch alarms
aws cloudwatch describe-alarms \
  --alarm-names "prod-honeytrap-auth-success-alert" \
  --query 'MetricAlarms[*].[StateValue,StateReason]'

# Verify alarm has never fired
aws cloudwatch get-metric-statistics \
  --namespace "Honeytrap" \
  --metric-name "HoneytrapAuthenticationSuccess" \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-02T00:00:00Z \
  --period 3600 \
  --statistics Sum
```

**Network Isolation:**
```bash
# Verify SecurityGroup rules
aws ec2 describe-security-groups \
  --group-ids sg-honeytrap \
  --query 'SecurityGroups[*].[GroupId,IpPermissions,IpPermissionsEgress]'

# Test from gateway: should NOT reach app
aws ssm start-session --target i-gateway-id
curl -v http://app.default.svc.cluster.local:8080  # Should timeout

# Test from Honeytrap: should NOT reach app
aws ssm start-session --target i-honeytrap-id
curl -v http://app.default.svc.cluster.local:8080  # Should timeout
```

**Kubernetes NetworkPolicy:**
```bash
# Verify NetworkPolicy is in place
kubectl get networkpolicy -n access-gateway

# Test egress from Honeytrap pod
kubectl exec -it -n access-gateway <honeytrap-pod> -- \
  curl -v http://internal-app:8080  # Should timeout

# Test egress to DNS (should work)
kubectl exec -it -n access-gateway <honeytrap-pod> -- \
  nslookup kubernetes.default.svc.cluster.local
```

## Incident Response

### Scenario 1: Honeytrap Receives Connection

**Alert:** `HoneytrapActivityDetected` alarm fires.

**Investigation:**
```bash
# 1. Check who connected
aws logs filter-log-events \
  --log-group-name "/aws/honeytrap/prod" \
  --filter-pattern "connection" \
  --query 'events[*].message' | jq

# 2. Identify source IP
# Look for remote_ip in logs

# 3. Check if internal or external
aws ec2 describe-security-groups \
  --group-ids sg-honeytrap \
  --query 'SecurityGroups[*].IpPermissions'

# 4. Determine if red-team testing or real attack
# (Expected: red-team testing; Unexpected: real attack = escalate)
```

**Response:**
- [ ] Log all connection metadata for forensics.
- [ ] Determine if legitimate (red-team) or unauthorized (incident).
- [ ] If unauthorized:
  - Isolate the source (revoke IAM credentials, revoke SSH key, block CIDR).
  - Scan VPC for lateral movement.
  - Review CloudTrail for API anomalies.

### Scenario 2: Honeytrap Auth Succeeds (CRITICAL)

**Alert:** `HoneytrapAuthenticationSuccessAlert` alarm fires.

**This should NEVER happen. Immediate action required:**

```bash
# 1. ISOLATE Honeytrap instance immediately
aws ec2 modify-instance-attribute \
  --instance-id i-honeytrap \
  --no-source-dest-check  # Prevent further network activity

# 2. Capture memory dump and logs
aws ssm start-session --target i-honeytrap
docker logs honeytrap > honeytrap-logs.txt
sudo journalctl -xe > system-logs.txt
# (Save for forensics before termination)

# 3. Check for lateral movement
aws ec2 describe-security-group-references \
  --group-id sg-honeytrap
aws logs filter-log-events \
  --log-group-name "/aws/gateway/prod" \
  --filter-pattern "ERROR"

# 4. Escalate to incident response team
# Create PagerDuty alert, page security on-call
```

### Scenario 3: Gateway mTLS Handshake Failures

**Alert:** Repeated `mTLS handshake failures` in Envoy logs.

**Investigation:**
```bash
# Check client certificates
openssl x509 -in /path/to/client/cert -text -noout
openssl verify -CAfile /path/to/ca.crt /path/to/client/cert

# Check server certificates
openssl x509 -in /path/to/server/cert -text -noout

# Check Envoy logs
docker logs envoy | grep -i "ssl\|tls\|handshake"

# Verify certificate chain
aws ssm get-parameter --name "/${SERVICE}/secrets/mtls/ca" --query Parameter.Value
```

## Compliance Considerations

### Audit Trail

All access and security events are logged:

| Event | Location | Retention |
|-------|----------|-----------|
| Gateway access (mTLS/SSH) | CloudWatch Logs | 30 days (configurable) |
| Honeytrap connections | CloudWatch Logs | 30 days (configurable) |
| EC2 system logs | CloudWatch Logs | 30 days (configurable) |
| API calls | CloudTrail | 90 days (default) |
| Alarms | CloudWatch Alarms | Indefinite |

### Compliance Frameworks

**SOC 2 Type II:**
- ✅ Encryption in transit (mTLS) and at rest (KMS)
- ✅ Access logging and monitoring (CloudWatch)
- ✅ Incident detection (Honeytrap alarms)
- ✅ Change controls (Terraform state, Git history)

**PCI-DSS:**
- ✅ Network isolation (private VPC, no public IPs)
- ✅ Authentication (mTLS client certs, 2FA via SSM)
- ✅ Encryption (TLS 1.3, AES-256 volumes)
- ✅ Audit logging (CloudWatch, CloudTrail)

**ISO 27001:**
- ✅ Access control (IAM, RBAC, NetworkPolicy)
- ✅ Encryption (AES-256 volumes, TLS)
- ✅ Monitoring (CloudWatch, alarms)
- ✅ Incident management (response procedures)

### Data Minimization

**What Honeytrap logs:**
- Connection timestamp, source IP, port, protocol
- Attempted commands/payloads (for anomaly analysis)
- No credentials, no application data

**Data retention:**
- Default: 30 days (adjust via `log_retention_days`)
- Honeytrap logs don't contain sensitive application data

**Purging:**
```bash
# Delete old logs if needed
aws logs delete-log-group \
  --log-group-name "/aws/honeytrap/prod"
```

## References

- [AWS Well-Architected Security Pillar](https://docs.aws.amazon.com/wellarchitected/latest/security-pillar/)
- [Kubernetes Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)
- [Honeytrap GitHub](https://github.com/afeldman/honeytrap)
