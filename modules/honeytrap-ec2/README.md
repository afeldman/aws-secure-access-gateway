# Honeytrap EC2 Submodule

This Terraform submodule deploys **Honeytrap** as a standalone EC2 instance for **deception and attack detection only**.

## ⚠️ Critical Security Notes

- **Honeytrap is NOT an access path** to the Secure Access Gateway.
- It serves **only to detect and deceive** potential attackers with fake SSH/TCP services.
- All authentication attempts are logged and should trigger CloudWatch alarms.
- Network policies ensure Honeytrap cannot reach real application endpoints.
- If authentication is detected on Honeytrap, it is a critical security event.

## What This Provides

- **Standalone EC2 instance** running containerized Honeytrap.
- **Fake SSH/TCP honeypots** on configurable ports (default: 2223, 10023).
- **CloudWatch Logs integration** for structured logging and detection.
- **CloudWatch Alarms** on:
  - Any connection to honeypot ports (deception trigger).
  - Any successful authentication (critical security violation).
- **Minimal IAM permissions** (SSM + CloudWatch Logs/Metrics only).
- **Private deployment** (no public IP, no ingress from Internet).
- **Anomaly detection** and heuristic analysis (Rust-based).

## Usage

### Basic Deployment

```hcl
module "honeytrap" {
  source = "./modules/honeytrap-ec2"
  
  enable_honeytrap      = true
  vpc_id                = "vpc-0123456789abcdef0"
  private_subnet_ids    = ["subnet-aaa", "subnet-bbb"]
  region                = "eu-central-1"
  
  honeypot_ports        = [2223, 10023, 8080]
  trusted_source_cidr   = []  # Restrict access for testing only
  
  service_name          = "internal-app"
  environment           = "prod"
  
  # Alerting
  alert_sns_topic_arn   = "arn:aws:sns:eu-central-1:123456789012:security-alerts"
  alarm_threshold       = 1  # Alert on any connection
  
  tags = {
    environment = "prod"
    squad       = "platform"
  }
}
```

### With Custom Honeytrap Configuration

If you need custom Honeytrap configuration, store it in SSM Parameter Store (SecureString):

```bash
aws ssm put-parameter \
  --name "/${SERVICE_NAME}/secrets/honeytrap/config" \
  --value "$(cat custom-config.toml)" \
  --type SecureString \
  --region eu-central-1
```

Then reference it:

```hcl
module "honeytrap" {
  # ... other variables ...
  
  honeytrap_config_param = "/${SERVICE_NAME}/secrets/honeytrap/config"
}
```

## Honeytrap Configuration

The default configuration is minimal:

```toml
[network]
bind_addr = "0.0.0.0:2223"
timeout = 300

[logging]
level = "info"
format = "json"
file = "/var/log/honeytrap/honeytrap.log"

[auth]
enabled = false  # Critical: no real authentication

[[honeypots]]
port = 2223
service_type = "ssh"
interaction_level = "minimal"
banner = "OpenSSH_7.4 (fake - honeypot)"

[[honeypots]]
port = 10023
service_type = "tcp"
interaction_level = "minimal"
```

**Key points:**
- `[auth].enabled = false` ensures attackers cannot authenticate.
- Fake service banners (e.g., "OpenSSH_7.4") are intentionally outdated to appear vulnerable.
- All connections are logged for analysis.

## Logging & Monitoring

### CloudWatch Logs

Logs are delivered to a dedicated log group (default: `/aws/honeytrap/{service}/{environment}`):

- **honeytrap.log:** Structured JSON logs of all activity (connections, attempts).
- **alerts.log:** High-severity events (authentication attempts, anomalies).
- **bootstrap:** Instance startup logs.

### CloudWatch Alarms

Two alarms are automatically created:

1. **Honeytrap Activity Alarm** (`honeytrap-activity`)
   - Triggers on any connection to honeypot ports.
   - Indicates deception was triggered.

2. **Authentication Success Alarm** (`honeytrap-auth-success-alert`) ⚠️ **CRITICAL**
   - Triggers if authentication ever succeeds.
   - Should trigger incident response (this should never happen).

### CloudWatch Logs Insights Query

Find all connection attempts:

```
fields @timestamp, @message, remote_ip, port
| filter @message like /connection/
| stats count() by remote_ip
```

Find all anomaly detections:

```
fields @timestamp, @message, anomaly_type
| filter @message like /anomaly|heuristic/
```

## Security Validation

### Network Policy Enforcement

- **Honeytrap SG ingress:** Only honeypot ports from `trusted_source_cidr`.
- **Honeytrap SG egress:** Only to VPC (CloudWatch, SSM, DNS).
- **No access to Secure Access Gateway endpoints.**

### IAM Policy Enforcement

Honeytrap role has **minimal permissions**:
- `logs:CreateLogStream`, `logs:PutLogEvents` → CloudWatch Logs only.
- `ssm:GetParameter` → Configuration retrieval (read-only).
- `cloudwatch:PutMetricData` → Metrics publishing only.

### Authentication Validation

If `authentication_success` metric > 0, it indicates a critical failure:

```bash
aws cloudwatch get-metric-statistics \
  --namespace "Honeytrap" \
  --metric-name "HoneytrapAuthenticationSuccess" \
  --start-time 2024-01-01T00:00:00Z \
  --end-time 2024-01-02T00:00:00Z \
  --period 3600 \
  --statistics Sum
```

## Outputs

| Output | Description |
|--------|-------------|
| `honeytrap_instance_id` | EC2 instance ID |
| `honeytrap_private_ip` | Private IP address |
| `cloudwatch_log_group_name` | Log group for Honeytrap logs |
| `alarm_activity_arn` | ARN of deception alarm |
| `alarm_auth_success_arn` | ARN of critical auth alarm |
| `honeytrap_connection_command` | SSM session command (debugging only) |

## Troubleshooting

### Honeytrap container not starting

Check user-data logs:

```bash
aws ssm start-session --target <instance-id>
cat /var/log/user-data.log
docker logs honeytrap
```

### Logs not appearing in CloudWatch

1. Verify IAM role has CloudWatch Logs permissions.
2. Check CloudWatch agent status:

```bash
systemctl status amazon-cloudwatch-agent
journalctl -u amazon-cloudwatch-agent
```

3. Verify log group exists:

```bash
aws logs describe-log-groups --log-group-name-prefix "honeytrap"
```

### False alarms on honeypot connections

If legitimate deception testing is occurring, adjust `alarm_threshold`:

```hcl
alarm_threshold = 100  # Alert only after 100 connections
```

## Integration with AWS Secure Access Gateway

Honeytrap complements the main gateway but is completely separate:

```
┌─────────────────────────────────────────────────┐
│ AWS Secure Access Gateway (Terraform module)    │
│ ├─ Envoy mTLS proxy (real access)               │
│ ├─ SSH fallback (optional)                       │
│ └─ Twingate connector (optional)                 │
└─────────────────────────────────────────────────┘
                        ▲
                        │ Real traffic (mTLS)
                        │
                   [SSM Session Manager]
                        │
                        ▼
                  [Developer's laptop]

┌─────────────────────────────────────────────────┐
│ Honeytrap (This submodule)                      │
│ ├─ Fake SSH on 2223                             │
│ ├─ Fake TCP on 10023                            │
│ └─ Anomaly detection                            │
└─────────────────────────────────────────────────┘
                        ▲
                        │ Attack/scanning traffic
                        │
              [Internet scanners, attackers]
```

## Cost Optimization

- Honeytrap typically runs on `t3.micro` (free tier eligible).
- CloudWatch Logs retention: 30 days (default, adjustable).
- Alarms: minimal cost (~$0.10/month).

## References

- Honeytrap GitHub: https://github.com/afeldman/honeytrap
- CloudWatch Logs: https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/
- AWS Security Best Practices: https://aws.amazon.com/security/security-best-practices/
