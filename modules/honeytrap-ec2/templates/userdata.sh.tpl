#!/bin/bash
# Honeytrap EC2 instance bootstrap script
# This instance runs a Rust-based deception/detection component
# WARNING: This is NOT an access path. It only serves to detect and deceive attackers.

set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "[honeytrap] bootstrap starting"

# Variables from Terraform
HONEYTRAP_IMAGE="${HONEYTRAP_IMAGE}"
HONEYTRAP_PORTS="${HONEYTRAP_PORTS}"
HONEYTRAP_CONFIG_PARAM="${HONEYTRAP_CONFIG_PARAM}"
HONEYTRAP_LOG_GROUP_NAME="${HONEYTRAP_LOG_GROUP_NAME}"
SERVICE_NAME="${SERVICE_NAME}"
ENVIRONMENT="${ENVIRONMENT}"
AWS_REGION="${REGION}"
ENABLE_ANOMALY_DETECTION="${ENABLE_ANOMALY_DETECTION}"
CLOUDWATCH_NAMESPACE="${CLOUDWATCH_NAMESPACE}"
ALERT_SNS_TOPIC_ARN="${ALERT_SNS_TOPIC_ARN}"

export AWS_DEFAULT_REGION="${AWS_REGION}"

# Security validation: ensure this is not treated as an access path
echo "[honeytrap] SECURITY: This instance is ONLY for deception/detection. Not for access."
echo "[honeytrap] SECURITY: All authentication attempts will be logged and alerted."

# Install dependencies
echo "[honeytrap] installing dependencies"
dnf update -y
dnf install -y docker unzip jq amazon-cloudwatch-agent

# Ensure Docker runs
systemctl enable docker
systemctl start docker

# Create directories
mkdir -p /etc/honeytrap /var/log/honeytrap

# Fetch Honeytrap configuration (if specified) or use defaults
if [ -n "${HONEYTRAP_CONFIG_PARAM}" ]; then
  echo "[honeytrap] fetching configuration from SSM Parameter Store: ${HONEYTRAP_CONFIG_PARAM}"
  aws ssm get-parameter \
    --name "${HONEYTRAP_CONFIG_PARAM}" \
    --with-decryption \
    --query Parameter.Value \
    --output text \
    --region "${AWS_REGION}" > /etc/honeytrap/config.toml
else
  echo "[honeytrap] using default configuration"
  cat > /etc/honeytrap/config.toml <<'EOF'
# Honeytrap Configuration
# WARNING: This is a deception/detection component, not an access path

[network]
bind_addr = "0.0.0.0:2223"
timeout = 300

[logging]
level = "info"
format = "json"
# Log file for structured output
file = "/var/log/honeytrap/honeytrap.log"

# Disable any real authentication mechanisms
[auth]
enabled = false

# SSH honeypot on 2223 (deception)
[[honeypots]]
port = 2223
service_type = "ssh"
interaction_level = "minimal"
banner = "OpenSSH_7.4 (fake - honeypot)"

# TCP honeypot on 10023 (deception)
[[honeypots]]
port = 10023
service_type = "tcp"
interaction_level = "minimal"

# Anomaly detection (if enabled)
{{- if ENABLE_ANOMALY_DETECTION == "true" }}
[detection]
enabled = true
heuristics = ["port_scan", "credential_enumeration", "version_probing"]
{{- end }}

# Security validation: log all attempts
[alerts]
enabled = true
target = "/var/log/honeytrap/alerts.log"
EOF
fi

# Setup CloudWatch Logs agent
if [ -n "${HONEYTRAP_LOG_GROUP_NAME}" ]; then
  echo "[honeytrap] configuring CloudWatch Logs agent"
  
  CW_AGENT_CONFIG=$(cat <<EOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/honeytrap/honeytrap.log",
            "log_group_name": "${HONEYTRAP_LOG_GROUP_NAME}",
            "log_stream_name": "{instance_id}/honeytrap",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S.%f"
          },
          {
            "file_path": "/var/log/honeytrap/alerts.log",
            "log_group_name": "${HONEYTRAP_LOG_GROUP_NAME}",
            "log_stream_name": "{instance_id}/alerts",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S.%f"
          },
          {
            "file_path": "/var/log/user-data.log",
            "log_group_name": "${HONEYTRAP_LOG_GROUP_NAME}",
            "log_stream_name": "{instance_id}/bootstrap"
          }
        ]
      }
    },
    "log_group_retention_in_days": 30
  }
}
EOF
)
  
  echo "${CW_AGENT_CONFIG}" | tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json >/dev/null
  systemctl enable amazon-cloudwatch-agent
  systemctl start amazon-cloudwatch-agent
fi

# Start Honeytrap container
echo "[honeytrap] starting Honeytrap container"
DOCKER_CMD="docker run -d --name honeytrap --restart unless-stopped"

# Mount configuration
DOCKER_CMD="${DOCKER_CMD} -v /etc/honeytrap/config.toml:/etc/honeytrap/config.toml:ro"
DOCKER_CMD="${DOCKER_CMD} -v /var/log/honeytrap:/var/log/honeytrap"

# Network configuration
DOCKER_CMD="${DOCKER_CMD} --net=host"

# Environment variables
DOCKER_CMD="${DOCKER_CMD} -e HONEYTRAP_CONFIG=/etc/honeytrap/config.toml"
DOCKER_CMD="${DOCKER_CMD} -e HONEYTRAP_LOG_LEVEL=info"
DOCKER_CMD="${DOCKER_CMD} -e RUST_LOG=info"

# CloudWatch Logs driver (if configured)
if [ -n "${HONEYTRAP_LOG_GROUP_NAME}" ]; then
  DOCKER_CMD="${DOCKER_CMD} --log-driver awslogs"
  DOCKER_CMD="${DOCKER_CMD} --log-opt awslogs-region=${AWS_REGION}"
  DOCKER_CMD="${DOCKER_CMD} --log-opt awslogs-group=${HONEYTRAP_LOG_GROUP_NAME}"
  DOCKER_CMD="${DOCKER_CMD} --log-opt awslogs-stream={instance_id}/container"
fi

# Add the image
DOCKER_CMD="${DOCKER_CMD} ${HONEYTRAP_IMAGE}"

eval "${DOCKER_CMD}"

echo "[honeytrap] waiting for Honeytrap to be ready"
sleep 5

# Verify Honeytrap is running
if docker ps | grep -q honeytrap; then
  echo "[honeytrap] Honeytrap container is running"
else
  echo "[honeytrap] ERROR: Honeytrap container failed to start" >&2
  docker logs honeytrap
  exit 1
fi

# Send initial metric to CloudWatch (optional)
if [ -n "${CLOUDWATCH_NAMESPACE}" ]; then
  echo "[honeytrap] sending startup metric to CloudWatch"
  aws cloudwatch put-metric-data \
    --namespace "${CLOUDWATCH_NAMESPACE}" \
    --metric-name HoneytrapStartup \
    --value 1 \
    --region "${AWS_REGION}" || true
fi

echo "[honeytrap] bootstrap completed successfully"
echo "[honeytrap] WARNING: This instance is NOT an access path. All attempts are logged."
