#!/usr/bin/env bash
# Secure Access Gateway connect helper (Phase 4)
# Modes: mTLS (default), ssh fallback, twingate placeholder

set -euo pipefail

MODE="mtls"
SERVICE=""
NAMESPACE="default"
LOCAL_PORT=""
REMOTE_PORT=""
TARGET="${GATEWAY_INSTANCE_ID:-}"
VERBOSE=false

usage() {
  cat <<'EOF'
Usage: ./connect.sh [options]
  --target <instance-id>     EC2 instance ID of the gateway (or set GATEWAY_INSTANCE_ID)
  --mode <mtls|ssh|twingate> Connection mode (default: mtls)
  --service <name>           Logical service name (for logging/instructions)
  --namespace <ns>           Kubernetes namespace (default: default)
  --local-port <port>        Local port to bind
  --remote-port <port>       Remote port on the gateway (default mtls:10000, ssh:2222)
  --verbose                  Verbose logging
  -h, --help                 Show this help

Examples:
  ./connect.sh --target i-abc --service internal-app --local-port 8080
  ./connect.sh --mode ssh --target i-abc --local-port 2222 --remote-port 2222
EOF
}

log() { echo "[connect] $*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2;;
    --mode) MODE="$2"; shift 2;;
    --service) SERVICE="$2"; shift 2;;
    --namespace) NAMESPACE="$2"; shift 2;;
    --local-port) LOCAL_PORT="$2"; shift 2;;
    --remote-port) REMOTE_PORT="$2"; shift 2;;
    --verbose) VERBOSE=true; shift;;
    -h|--help) usage; exit 0;;
    *) log "unknown option: $1"; usage; exit 1;;
  esac
done

case "$MODE" in
  mtls) :;;
  ssh) :;;
  twingate) :;;
  *) log "invalid --mode (mtls|ssh|twingate)"; exit 1;;
esac

if [[ "$MODE" != "twingate" ]] && [[ -z "${TARGET}" ]]; then
  log "--target is required (or set GATEWAY_INSTANCE_ID)"; exit 1
fi

if [[ -z "${REMOTE_PORT}" ]]; then
  if [[ "$MODE" == "mtls" ]]; then
    REMOTE_PORT=10000
  elif [[ "$MODE" == "ssh" ]]; then
    REMOTE_PORT=2222
  fi
fi

if [[ "$MODE" == "twingate" ]]; then
  log "Twingate mode selected; no SSM port-forward started. Use the Twingate client to reach protected resources."
  exit 0
fi

if [[ -z "${LOCAL_PORT}" ]]; then
  LOCAL_PORT="${REMOTE_PORT}"
fi

command -v aws >/dev/null 2>&1 || { log "aws CLI not found"; exit 1; }
command -v session-manager-plugin >/dev/null 2>&1 || { log "session-manager-plugin not found"; exit 1; }

SESSION_LOG="/tmp/gateway-session-${TARGET}.log"

log "mode=${MODE} target=${TARGET} local=${LOCAL_PORT} remote=${REMOTE_PORT}"
log "starting SSM port forward (logs: ${SESSION_LOG})"

aws ssm start-session \
  --target "${TARGET}" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "localPortNumber=${LOCAL_PORT},portNumber=${REMOTE_PORT}" \
  >"${SESSION_LOG}" 2>&1 &
SSM_PID=$!

cleanup() {
  log "stopping session"
  if kill -0 "${SSM_PID}" >/dev/null 2>&1; then
    kill "${SSM_PID}" || true
  fi
}
trap cleanup EXIT INT TERM

sleep 1
if ! kill -0 "${SSM_PID}" >/dev/null 2>&1; then
  log "session failed; see ${SESSION_LOG}"; exit 1
fi

if [[ "$MODE" == "mtls" ]]; then
  log "mTLS listener available on localhost:${LOCAL_PORT}"
  log "Next: export HTTPS_PROXY=https://localhost:${LOCAL_PORT} (or configure your client to use mTLS certs)"
else
  log "SSH forwarding ready on localhost:${LOCAL_PORT} (remote ${REMOTE_PORT})"
  log "Next: ssh -p ${LOCAL_PORT} ssh-user@localhost"
fi

log "Press Ctrl+C to close session"
wait "${SSM_PID}"
