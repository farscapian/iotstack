#!/bin/bash
# Query Home Assistant WebSocket API for devices/entities
# Auto-installs websocat if needed

set -euo pipefail

DEVICE_NAME="${1:-}"
LIST_DEVICES="${LIST_DEVICES:-false}"
HA_URL="${HA_URL:-http://localhost:8123}"
SECRETS_YAML="${SECRETS_YAML:-$(dirname "$0")/../yamls/secrets.yaml}"

if [[ "$DEVICE_NAME" == "--list" ]] || [[ "$DEVICE_NAME" == "-l" ]]; then
  LIST_DEVICES=true
  DEVICE_NAME=""
fi

if [[ -z "$DEVICE_NAME" && "$LIST_DEVICES" != "true" ]]; then
  echo "Usage: $0 <device-name>" >&2
  echo "       $0 --list     (list all devices)" >&2
  exit 1
fi

# Setup pass environment
export GNUPGHOME="${HOME}/.iotstack/.gnupg"
export PASSWORD_STORE_DIR="${HOME}/.iotstack/.pass"

err() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

# Ensure websocat is installed
ensure_websocat() {
  if command -v websocat &>/dev/null; then
    return 0
  fi

  echo "[INFO] Installing websocat..." >&2

  if command -v cargo &>/dev/null; then
    # Install from Rust cargo
    cargo install websocat --quiet || err "Failed to install websocat via cargo"
  elif command -v apt &>/dev/null; then
    # Install from apt
    sudo apt update -qq && sudo apt install -y websocat >/dev/null 2>&1 || err "Failed to install websocat via apt"
  else
    err "Could not install websocat. Please install manually: https://github.com/vi/websocat"
  fi

  echo "[OK] websocat installed" >&2
}

# Helper: sync secret from secrets.yaml to pass if different
sync_secret() {
  local secret_name="$1"
  local secrets_key="$2"
  local pass_path="$3"

  local secrets_value=""
  if [[ -f "$SECRETS_YAML" ]]; then
    secrets_value=$(grep "^${secrets_key}:" "$SECRETS_YAML" | cut -d'"' -f2 || echo "")
  fi

  if [[ -z "$secrets_value" ]]; then
    return 1
  fi

  local pass_value=""
  if pass show "$pass_path" &>/dev/null; then
    pass_value=$(pass show "$pass_path")
  fi

  if [[ "$pass_value" != "$secrets_value" ]]; then
    if [[ -z "$pass_value" ]]; then
      warn "Secret '$pass_path' not in pass, syncing from secrets.yaml"
    else
      warn "Secret '$pass_path' differs from secrets.yaml, updating pass"
    fi
    echo "$secrets_value" | pass insert -f "$pass_path" 2>&1 || true
  fi

  printf '%s' "$secrets_value" | xargs
}

# Get secrets
HA_TOKEN=$(sync_secret "HA Token" "ha_token" "iotstack/common/ha_token" || pass show "iotstack/common/ha_token" 2>/dev/null || echo "")
HA_TOKEN=$(printf '%s' "$HA_TOKEN" | xargs)
[[ -z "$HA_TOKEN" ]] && err "HA_TOKEN not found in pass or secrets.yaml"

HA_URL=$(sync_secret "HA URL" "ha_url" "iotstack/common/ha_url" || pass show "iotstack/common/ha_url" 2>/dev/null || echo "$HA_URL")
HA_URL=$(printf '%s' "$HA_URL" | xargs)
[[ -z "$HA_URL" ]] && err "HA_URL not found in pass, secrets.yaml, or HA_URL env var"

# Convert HTTP/HTTPS to WS/WSS
WS_URL="${HA_URL//http:/ws:}"
WS_URL="${WS_URL//https:/wss:}"
WS_URL="${WS_URL}/api/websocket"

echo "[INFO] Using WebSocket URL: $WS_URL" >&2

# Ensure websocat is available
ensure_websocat

# Create WebSocket query commands
query_devices() {
  cat <<'EOF'
{"type": "auth", "access_token": "$HA_TOKEN"}
{"id": 1, "type": "config/device_registry/list"}
EOF
}

query_entities() {
  cat <<'EOF'
{"type": "auth", "access_token": "$HA_TOKEN"}
{"id": 2, "type": "config/entity_registry/list"}
EOF
}

# Send WebSocket commands and parse responses
echo "[DEBUG] Connecting to WebSocket..." >&2

if [[ "$LIST_DEVICES" == "true" ]]; then
  # Query and list devices
  query_devices | sed "s|\$HA_TOKEN|$HA_TOKEN|" | websocat "$WS_URL" 2>/dev/null | \
    jq -r 'select(.id == 1) | .result[] | "\(.id): \(.name)"'
else
  # Query entities for specific device
  echo "[INFO] Querying entities for device: $DEVICE_NAME" >&2

  # First get device ID
  device_id=$(query_devices | sed "s|\$HA_TOKEN|$HA_TOKEN|" | websocat "$WS_URL" 2>/dev/null | \
    jq -r --arg name "$DEVICE_NAME" '.result[] | select(.name | ascii_downcase | contains($name | ascii_downcase)) | .id' | head -1)

  if [[ -z "$device_id" ]]; then
    err "Device '$DEVICE_NAME' not found"
  fi

  echo "[INFO] Found device_id: $device_id" >&2

  # Query entities for this device
  query_entities | sed "s|\$HA_TOKEN|$HA_TOKEN|" | websocat "$WS_URL" 2>/dev/null | \
    jq --arg dev_id "$device_id" '[.result[] | select(.device_id == $dev_id)] | sort_by(.platform)'
fi

echo "[INFO] Query complete" >&2
