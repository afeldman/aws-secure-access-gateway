#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "[userdata] bootstrap starting"

# --- Variables from Terraform ---
CREDENTIAL_SOURCE="${credential_source}"
ENABLE_MTLS="${enable_mtls}"
SERVICE_NAME="${service_name}"
ENVIRONMENT="${environment}"
AWS_REGION="${region}"
ONEPASSWORD_VAULT="" # Placeholder until Phase 3

export AWS_DEFAULT_REGION="${region}"

## Install core dependencies
echo "[userdata] installing dependencies (docker, kubectl)"
sudo dnf upgrade -y
sudo dnf install -y docker

# Install kubectl (EKS v1.28 compatible)
curl -sSf -o /usr/local/bin/kubectl "https://s3.us-west-2.amazonaws.com/amazon-eks/1.28.5/2024-01-04/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

sudo systemctl enable docker
sudo systemctl start docker

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
      if ! command -v op >/dev/null 2>&1; then
        echo "[userdata] ERROR: 1Password CLI 'op' not found" >&2
        exit 1
      fi
      op read "op://${ONEPASSWORD_VAULT}/${key}"
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
    -c /etc/envoy/envoy.yaml
fi

echo "[userdata] bootstrap completed"
