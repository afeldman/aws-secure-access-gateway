#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "[userdata] bootstrap starting"

# --- Variables from Terraform ---
CREDENTIAL_SOURCE="${CREDENTIAL_SOURCE}"
ACCESS_MODE="${ACCESS_MODE}"
ENABLE_MTLS="${ENABLE_MTLS}"
ENABLE_SSH="${ENABLE_SSH}"
ENABLE_TWINGATE="${ENABLE_TWINGATE}"
ENABLE_HONEYTRAP="${ENABLE_HONEYTRAP}"
TRUSTED_FORWARDER_CIDR="${TRUSTED_FORWARDER_CIDR}"
TWINGATE_NETWORK="${TWINGATE_NETWORK}"
TWINGATE_ACCESS_PARAM="${TWINGATE_ACCESS_TOKEN_PARAM}"
TWINGATE_REFRESH_PARAM="${TWINGATE_REFRESH_TOKEN_PARAM}"
HONEYTRAP_IMAGE="${HONEYTRAP_IMAGE}"
HONEYTRAP_PORTS="${HONEYTRAP_PORTS}"
HONEYTRAP_CONFIG_PARAM="${HONEYTRAP_CONFIG_PARAM}"
HONEYTRAP_LOG_GROUP="${HONEYTRAP_LOG_GROUP_NAME}"
SERVICE_NAME="${SERVICE_NAME}"
ENVIRONMENT="${ENVIRONMENT}"
AWS_REGION="${REGION}"
ONEPASSWORD_VAULT="${ONEPASSWORD_VAULT}"
ONEPASSWORD_ITEM_PREFIX="${ONEPASSWORD_ITEM_PREFIX}"
ONEPASSWORD_CONNECT_HOST="${ONEPASSWORD_CONNECT_HOST}"
ONEPASSWORD_CONNECT_TOKEN_PARAM="${ONEPASSWORD_CONNECT_TOKEN_PARAM}"
LOG_GROUP_NAME="${LOG_GROUP_NAME}"
ENABLE_CW_LOGS="${ENABLE_CW_LOGS}"
ENABLE_CW_METRICS="${ENABLE_CW_METRICS}"
CW_NAMESPACE="${CW_NAMESPACE}"

export AWS_DEFAULT_REGION="${REGION}"

enabled_modes=0
enabled_labels=()

if [ "${ENABLE_MTLS}" = "true" ]; then
  enabled_modes=$((enabled_modes + 1))
  enabled_labels+=("mTLS")
fi

if [ "${ENABLE_SSH}" = "true" ]; then
  enabled_modes=$((enabled_modes + 1))
  enabled_labels+=("SSH")
fi

if [ "${ENABLE_TWINGATE}" = "true" ]; then
  enabled_modes=$((enabled_modes + 1))
  enabled_labels+=("Twingate")
fi

if [ "${enabled_modes}" -gt 1 ]; then
  echo "[userdata] ERROR: enable_mtls, enable_ssh, and enable_twingate are mutually exclusive (found: ${enabled_labels[*]})" >&2
  exit 1
fi

if [ -n "${TRUSTED_FORWARDER_CIDR}" ]; then
  echo "[userdata] trusted forwarder CIDRs: ${TRUSTED_FORWARDER_CIDR}"
fi

echo "[userdata] access_mode=${ACCESS_MODE} honeytrap=${ENABLE_HONEYTRAP}"

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
      item_name=$(echo "${ONEPASSWORD_ITEM_PREFIX}${key}" | sed 's/\//-/g')
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
if [ "${ENABLE_CW_LOGS}" = "true" ] && [ "${LOG_GROUP_NAME}" != "" ]; then
  echo "[userdata] configuring CloudWatch Logs"
  sudo mkdir -p /var/log/envoy
  
  CW_AGENT_CONFIG="{\"logs\": {\"logs_collected\": {\"files\": {\"collect_list\": [{\"file_path\": \"/var/log/user-data.log\", \"log_group_name\": \"${LOG_GROUP_NAME}\", \"log_stream_name\": \"{instance_id}/user-data\", \"timestamp_format\": \"%Y-%m-%d %H:%M:%S\"}, {\"file_path\": \"/var/log/envoy/envoy.log\", \"log_group_name\": \"${LOG_GROUP_NAME}\", \"log_stream_name\": \"{instance_id}/envoy\", \"timestamp_format\": \"%Y-%m-%d %H:%M:%S\"}, {\"file_path\": \"/var/log/secure\", \"log_group_name\": \"${LOG_GROUP_NAME}\", \"log_stream_name\": \"{instance_id}/secure\"}, {\"file_path\": \"/var/log/messages\", \"log_group_name\": \"${LOG_GROUP_NAME}\", \"log_stream_name\": \"{instance_id}/messages\"}]}}}"
  
  if [ "${ENABLE_CW_METRICS}" = "true" ]; then
    CW_AGENT_CONFIG="{\"logs\": {\"logs_collected\": {\"files\": {\"collect_list\": [{\"file_path\": \"/var/log/user-data.log\", \"log_group_name\": \"${LOG_GROUP_NAME}\", \"log_stream_name\": \"{instance_id}/user-data\", \"timestamp_format\": \"%Y-%m-%d %H:%M:%S\"}, {\"file_path\": \"/var/log/envoy/envoy.log\", \"log_group_name\": \"${LOG_GROUP_NAME}\", \"log_stream_name\": \"{instance_id}/envoy\", \"timestamp_format\": \"%Y-%m-%d %H:%M:%S\"}, {\"file_path\": \"/var/log/secure\", \"log_group_name\": \"${LOG_GROUP_NAME}\", \"log_stream_name\": \"{instance_id}/secure\"}, {\"file_path\": \"/var/log/messages\", \"log_group_name\": \"${LOG_GROUP_NAME}\", \"log_stream_name\": \"{instance_id}/messages\"}]}}, \"metrics\": {\"namespace\": \"${CW_NAMESPACE}\", \"append_dimensions\": {\"InstanceId\": \"$${aws:InstanceId}\", \"AutoScalingGroupName\": \"$${aws:AutoScalingGroupName}\"}, \"metrics_collected\": {\"mem\": {\"measurement\": [\"mem_used_percent\"], \"metrics_collection_interval\": 60}, \"swap\": {\"measurement\": [\"swap_used_percent\"], \"metrics_collection_interval\": 60}, \"disk\": {\"measurement\": [\"disk_used_percent\"], \"resources\": [\"/\"], \"metrics_collection_interval\": 60}, \"netstat\": {\"metrics_collection_interval\": 60}, \"cpu\": {\"measurement\": [\"cpu_usage_active\"], \"metrics_collection_interval\": 60}}}}"
  fi

  echo "${CW_AGENT_CONFIG}" | sudo tee /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json >/dev/null
  sudo systemctl enable amazon-cloudwatch-agent
  sudo systemctl start amazon-cloudwatch-agent
fi

## Honeytrap decoy
if [ "${ENABLE_HONEYTRAP}" = "true" ]; then
  echo "[userdata] configuring Honeytrap decoy"
  sudo mkdir -p /etc/honeytrap /var/log/honeytrap
  HONEYTRAP_CONFIG_FILE="/etc/honeytrap/config.toml"

  if [ -n "${HONEYTRAP_PORTS}" ]; then
    # Split space-separated ports into array
    for port in ${HONEYTRAP_PORTS}; do
      HONEYTRAP_PORT_LIST+=( "$port" )
    done
  else
    HONEYTRAP_PORT_LIST=(2223 10023)
  fi

  if [ -n "${HONEYTRAP_CONFIG_PARAM}" ]; then
    echo "[userdata] fetching Honeytrap config from ${HONEYTRAP_CONFIG_PARAM}"
    fetch_credential "${HONEYTRAP_CONFIG_PARAM}" | sudo tee "${HONEYTRAP_CONFIG_FILE}" >/dev/null
  else
    echo "[userdata] writing default Honeytrap config"
    HONEYTRAP_CONFIG=$(cat <<'CFGEOF'
[network]
bind_addr = "0.0.0.0:2223"

[logging]
level = "info"

[[honeypots]]
port = 2223
service_type = "ssh"
interaction_level = "minimal"

[[honeypots]]
port = 10023
service_type = "ssh"
interaction_level = "minimal"
CFGEOF
)
    echo "${HONEYTRAP_CONFIG}" | sudo tee "${HONEYTRAP_CONFIG_FILE}" >/dev/null
  fi

  HONEYTRAP_DOCKER_CMD="sudo docker run -d --name honeytrap --restart unless-stopped -v ${HONEYTRAP_CONFIG_FILE}:${HONEYTRAP_CONFIG_FILE}:ro --net=host --env HONEYTRAP_CONFIG=${HONEYTRAP_CONFIG_FILE}"
  
  if [ "${ENABLE_CW_LOGS}" = "true" ] && [ -n "${HONEYTRAP_LOG_GROUP}" ]; then
    HONEYTRAP_DOCKER_CMD="${HONEYTRAP_DOCKER_CMD} --log-driver awslogs --log-opt awslogs-region=${AWS_REGION} --log-opt awslogs-group=${HONEYTRAP_LOG_GROUP} --log-opt awslogs-stream={instance_id}/honeytrap"
  fi
  
  HONEYTRAP_DOCKER_CMD="${HONEYTRAP_DOCKER_CMD} ${HONEYTRAP_IMAGE}"
  eval "${HONEYTRAP_DOCKER_CMD}"
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
          install_op_cli; ensure_op_env; param_item=$(echo "${ONEPASSWORD_ITEM_PREFIX}${param_override}" | sed 's/\//-/g'); op read "op://${ONEPASSWORD_VAULT}/${param_item}" ;;
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

  DOCKER_CMD="sudo docker run -d --name twingate-connector --restart unless-stopped --env-file /etc/twingate/env --net=host"
  if [ "${ENABLE_CW_LOGS}" = "true" ] && [ "${LOG_GROUP_NAME}" != "" ]; then
    DOCKER_CMD="${DOCKER_CMD} --log-driver awslogs --log-opt awslogs-region=${AWS_REGION} --log-opt awslogs-group=${LOG_GROUP_NAME} --log-opt awslogs-stream={instance_id}/twingate"
  fi
  DOCKER_CMD="${DOCKER_CMD} twingate/connector:latest"
  
  eval "${DOCKER_CMD}"
fi

echo "[userdata] bootstrap completed"
