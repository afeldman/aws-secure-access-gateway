#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "[userdata] bootstrap starting"

if [ "${ENABLE_MTLS}" = "true" ] && [ "${ENABLE_SSH}" = "true" ]; then
  echo "[userdata] ERROR: enable_mtls and enable_ssh cannot both be true" >&2
  exit 1
fi

# --- Variables from Terraform ---
CREDENTIAL_SOURCE="${credential_source}"
ENABLE_MTLS="${enable_mtls}"
ENABLE_SSH="${enable_ssh}"
ENABLE_TWINGATE="${enable_twingate}"
twingate_network="${twingate_network}"
twingate_access_param="${twingate_access_token_param}"
twingate_refresh_param="${twingate_refresh_token_param}"
SERVICE_NAME="${service_name}"
ENVIRONMENT="${environment}"
AWS_REGION="${region}"
ONEPASSWORD_VAULT="${onepassword_vault}"
ONEPASSWORD_ITEM_PREFIX="${onepassword_item_prefix}"
ONEPASSWORD_CONNECT_HOST="${onepassword_connect_host}"
ONEPASSWORD_CONNECT_TOKEN_PARAM="${onepassword_connect_token_param}"
LOG_GROUP_NAME="${log_group_name}"
ENABLE_CW_METRICS="${enable_cloudwatch_metrics}"
CW_NAMESPACE="${cloudwatch_namespace}"

export AWS_DEFAULT_REGION="${region}"

## Install core dependencies
echo "[userdata] installing dependencies (docker, kubectl)"
sudo dnf upgrade -y
sudo dnf install -y docker unzip jq amazon-cloudwatch-agent

# Install kubectl (EKS v1.28 compatible)
curl -sSf -o /usr/local/bin/kubectl "https://s3.us-west-2.amazonaws.com/amazon-eks/1.28.5/2024-01-04/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

sudo systemctl enable docker
sudo systemctl start docker

install_op_cli() {
  if command -v op >/dev/null 2>&1; then
    return
  fi
  echo "[userdata] installing 1Password CLI"
  curl -sSLo /tmp/op.zip https://cache.agilebits.com/dist/1P/op2/pkg/v2.25.0/op_linux_amd64_v2.25.0.zip
  unzip -o /tmp/op.zip -d /tmp/op-bin
  sudo mv /tmp/op-bin/op /usr/local/bin/op
  sudo chmod 755 /usr/local/bin/op
}

ensure_op_env() {
  if [ -n "${ONEPASSWORD_CONNECT_HOST}" ]; then
    export OP_CONNECT_HOST="${ONEPASSWORD_CONNECT_HOST}"
  fi
  if [ -n "${ONEPASSWORD_CONNECT_TOKEN_PARAM}" ]; then
    OP_CONNECT_TOKEN=$(aws ssm get-parameter --name "${ONEPASSWORD_CONNECT_TOKEN_PARAM}" --with-decryption --query Parameter.Value --output text --region "${AWS_REGION}")
    export OP_CONNECT_TOKEN
  fi
}

## Credential Fetching Logic
fetch_credential() {
  local key="$1"
  case "$CREDENTIAL_SOURCE" in
    "ssm")
      aws ssm get-parameter \
        --name "/${SERVICE_NAME}/secrets/${key}" \
        --with-decryption \
        --query Parameter.Value \
        --output text \
        --region "${AWS_REGION}"
      ;;
    "1password")
      install_op_cli
      ensure_op_env
      if [ -z "${ONEPASSWORD_VAULT}" ]; then
        echo "[userdata] ERROR: ONEPASSWORD_VAULT not set" >&2
        exit 1
      fi
      local item_name
      item_name="${ONEPASSWORD_ITEM_PREFIX}${key//\//-}"
      op read "op://${ONEPASSWORD_VAULT}/${item_name}"
      ;;
    *)
      echo "[userdata] ERROR: unknown credential source '${CREDENTIAL_SOURCE}'" >&2
      exit 1
      ;;
  esac
}

## mTLS Setup with Envoy
if [ "${ENABLE_MTLS}" = "true" ]; then
  echo "[userdata] mTLS enabled; fetching certificates"
  sudo mkdir -p /etc/ssl/envoy
  fetch_credential "mtls/ca" > /etc/ssl/envoy/ca.crt
  fetch_credential "mtls/cert" > /etc/ssl/envoy/tls.crt
  fetch_credential "mtls/key" > /etc/ssl/envoy/tls.key
  sudo chmod 600 /etc/ssl/envoy/tls.key

  echo "[userdata] writing Envoy configuration"
  sudo mkdir -p /etc/envoy
  cat <<'EOF' | sudo tee /etc/envoy/envoy.yaml >/dev/null
${envoy_config}
EOF

  echo "[userdata] starting Envoy via Docker"
  sudo docker run -d --name envoy --restart unless-stopped \
    -v /etc/envoy/envoy.yaml:/etc/envoy/envoy.yaml:ro \
    -v /etc/ssl/envoy:/etc/ssl/envoy:ro \
    --net=host \
    envoyproxy/envoy:v1.28.0 \
    -c /etc/envoy/envoy.yaml \
    --log-path /var/log/envoy/envoy.log
fi

## CloudWatch Logs shipping
if [ "${LOG_GROUP_NAME}" != "" ]; then
  echo "[userdata] configuring CloudWatch Logs"
  sudo mkdir -p /var/log/envoy
  METRICS_BLOCK=""
  if [ "${ENABLE_CW_METRICS}" = "true" ]; then
    read -r -d '' METRICS_BLOCK <<'JSON' || true
    ,
    "metrics": {
      "namespace": "${CW_NAMESPACE}",
      "append_dimensions": {
        "InstanceId": "${aws:InstanceId}",
        "AutoScalingGroupName": "${aws:AutoScalingGroupName}"
      },
      "metrics_collected": {
        "mem": {"measurement": ["mem_used_percent"], "metrics_collection_interval": 60},
        "swap": {"measurement": ["swap_used_percent"], "metrics_collection_interval": 60},
        "disk": {"measurement": ["disk_used_percent"], "resources": ["/"], "metrics_collection_interval": 60},
        "netstat": {"metrics_collection_interval": 60},
        "cpu": {"measurement": ["cpu_usage_active"], "metrics_collection_interval": 60}
      }
    }
JSON
  fi

  cat <<EOF | sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json >/dev/null
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {"file_path": "/var/log/user-data.log", "log_group_name": "${LOG_GROUP_NAME}", "log_stream_name": "{instance_id}/user-data", "timestamp_format": "%Y-%m-%d %H:%M:%S"},
          {"file_path": "/var/log/envoy/envoy.log", "log_group_name": "${LOG_GROUP_NAME}", "log_stream_name": "{instance_id}/envoy", "timestamp_format": "%Y-%m-%d %H:%M:%S"},
          {"file_path": "/var/log/secure", "log_group_name": "${LOG_GROUP_NAME}", "log_stream_name": "{instance_id}/secure"},
          {"file_path": "/var/log/messages", "log_group_name": "${LOG_GROUP_NAME}", "log_stream_name": "{instance_id}/messages"}
        ]
      }
    }
  }${METRICS_BLOCK}
}
EOF
  sudo systemctl enable amazon-cloudwatch-agent
  sudo systemctl start amazon-cloudwatch-agent
fi

## SSH fallback hardening (only when mTLS disabled)
if [ "${ENABLE_SSH}" = "true" ] && [ "${ENABLE_MTLS}" != "true" ]; then
  echo "[userdata] configuring sshd for fallback"
  sudo mkdir -p /home/ssm-user/.ssh
  fetch_credential "ssh/authorized_keys" > /home/ssm-user/.ssh/authorized_keys
  chown ssm-user:ssm-user /home/ssm-user/.ssh/authorized_keys
  chmod 600 /home/ssm-user/.ssh/authorized_keys

  sudo mkdir -p /etc/ssh/sshd_config.d
  cat <<'EOF' | sudo tee /etc/ssh/sshd_config.d/access-gateway.conf >/dev/null
Port 2222
AddressFamily inet
ListenAddress 127.0.0.1
Protocol 2
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile /home/ssm-user/.ssh/authorized_keys
AllowUsers ssm-user
ClientAliveInterval 180
ClientAliveCountMax 3
X11Forwarding no
AllowTcpForwarding no
GatewayPorts no
UsePAM yes
EOF

  sudo systemctl enable sshd
  sudo systemctl restart sshd
  echo "[userdata] sshd configured on 127.0.0.1:2222 (SSM port-forward only)"
fi

## SSH authorized_keys (fallback mode only)
if [ "${ENABLE_SSH}" = "true" ] && [ "${ENABLE_MTLS}" != "true" ]; then
  echo "[userdata] fetching SSH authorized_keys"
  fetch_credential "ssh/authorized_keys" > /home/ssm-user/.ssh/authorized_keys
  chown ssm-user:ssm-user /home/ssm-user/.ssh/authorized_keys
  chmod 600 /home/ssm-user/.ssh/authorized_keys
fi

## Twingate token (placeholder)
if [ "${ENABLE_TWINGATE}" = "true" ]; then
  echo "[userdata] configuring Twingate connector"
  if [ -z "${twingate_network}" ]; then
    echo "[userdata] ERROR: twingate_network is required when enable_twingate=true" >&2
    exit 1
  fi
  mkdir -p /etc/twingate

  fetch_twingate_token() {
    local default_path="$1"
    local param_override="$2"
    if [ -n "$param_override" ]; then
      case "$CREDENTIAL_SOURCE" in
        "ssm")
          aws ssm get-parameter --name "$param_override" --with-decryption --query Parameter.Value --output text --region "${AWS_REGION}" ;;
        "1password")
          install_op_cli; ensure_op_env; op read "op://${ONEPASSWORD_VAULT}/${ONEPASSWORD_ITEM_PREFIX}${param_override//\//-}" ;;
        *) echo "[userdata] unsupported credential source" >&2; exit 1 ;;
      esac
    else
      fetch_credential "$default_path"
    fi
  }

  TWINGATE_ACCESS_TOKEN=$(fetch_twingate_token "twingate/access_token" "${twingate_access_param}")
  TWINGATE_REFRESH_TOKEN=$(fetch_twingate_token "twingate/refresh_token" "${twingate_refresh_param}")

  cat <<EOF | sudo tee /etc/twingate/env >/dev/null
TWINGATE_NETWORK=${twingate_network}
TWINGATE_ACCESS_TOKEN=${TWINGATE_ACCESS_TOKEN}
TWINGATE_REFRESH_TOKEN=${TWINGATE_REFRESH_TOKEN}
TWINGATE_LABEL_HOSTNAME=$(hostname)
EOF

  DOCKER_LOG_OPTS=()
  if [ "${LOG_GROUP_NAME}" != "" ]; then
    DOCKER_LOG_OPTS+=(--log-driver awslogs --log-opt awslogs-region=${AWS_REGION} --log-opt awslogs-group=${LOG_GROUP_NAME} --log-opt awslogs-stream=\{instance_id\}/twingate)
  fi

  sudo docker run -d --name twingate-connector --restart unless-stopped \
    --env-file /etc/twingate/env \
    --net=host \
    ${DOCKER_LOG_OPTS[@]} \
    twingate/connector:latest
fi

echo "[userdata] bootstrap completed"
