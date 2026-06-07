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

  local arch=$(uname -m)
  local os=$(uname -s | tr '[:upper:]' '[:lower:]')
  local install_dir="${HOME}/.local/bin"

  mkdir -p "$install_dir"

  # Try downloading prebuilt binary
  if [[ "$os" == "linux" ]]; then
    local binary_url="https://github.com/vi/websocat/releases/download/v1.13.0/websocat_${arch}-unknown-linux-musl"
    echo "[INFO] Downloading prebuilt websocat binary..." >&2

    if curl -sL "$binary_url" -o "$install_dir/websocat" 2>/dev/null; then
      chmod +x "$install_dir/websocat"
      export PATH="$install_dir:$PATH"
      echo "[OK] websocat installed to $install_dir" >&2
      return 0
    fi
  fi

  # Fallback: try cargo
  if command -v cargo &>/dev/null; then
    echo "[INFO] Installing websocat via cargo..." >&2
    cargo install websocat --quiet 2>/dev/null || true
    if command -v websocat &>/dev/null; then
      echo "[OK] websocat installed via cargo" >&2
      return 0
    fi
  fi

  # Fallback: try apt
  if command -v apt &>/dev/null; then
    echo "[INFO] Trying apt (may fail)..." >&2
    sudo apt update -qq && sudo apt install -y websocat >/dev/null 2>&1 || true
    if command -v websocat &>/dev/null; then
      echo "[OK] websocat installed via apt" >&2
      return 0
    fi
  fi

  err "Could not install websocat. Please install manually: https://github.com/vi/websocat/releases"
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

  # Trim whitespace from secrets_value
  secrets_value=$(printf '%s' "$secrets_value" | xargs)

  if [[ -z "$secrets_value" ]]; then
    return 1
  fi

  local pass_value=""
  if pass show "$pass_path" &>/dev/null; then
    pass_value=$(pass show "$pass_path")
  fi

  # Trim whitespace from pass_value for comparison
  pass_value=$(printf '%s' "$pass_value" | xargs)

  # Only sync and warn if values differ
  if [[ "$pass_value" != "$secrets_value" ]]; then
    if [[ -z "$pass_value" ]]; then
      warn "Syncing '$pass_path' from secrets.yaml (first time)"
    else
      warn "Secret '$pass_path' changed in secrets.yaml, updating pass"
    fi
    echo "$secrets_value" | pass insert -f "$pass_path" 2>&1 || true
  fi
  # If they match, don't warn - already in sync

  printf '%s' "$secrets_value"
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

# Send WebSocket commands and parse responses
echo "[DEBUG] Connecting to WebSocket..." >&2

# Use timeout and process WebSocket response properly
query_ha_ws() {
  local cmd="$1"
  local timeout=10

  # Replace token in command
  cmd="${cmd//\$HA_TOKEN/$HA_TOKEN}"

  # Send command and capture response (with timeout)
  timeout "$timeout" bash -c "
    (echo '$cmd'; sleep 1) | websocat '$WS_URL' 2>/dev/null
  "
}

if [[ "$LIST_DEVICES" == "true" ]]; then
  # Query and list devices
  echo "[DEBUG] Sending device registry query..." >&2

  auth_cmd='{"type": "auth", "access_token": "$HA_TOKEN"}'
  device_cmd='{"id": 1, "type": "config/device_registry/list"}'

  {
    echo "$auth_cmd"
    sleep 0.5
    echo "$device_cmd"
    sleep 2
  } | sed "s|\$HA_TOKEN|$HA_TOKEN|g" | websocat -n "$WS_URL" 2>/dev/null | \
    jq -r 'select(.id == 1) | .result[] | "\(.id): \(.name)"'
else
  # Query entities for specific device
  echo "[INFO] Querying entities for device: $DEVICE_NAME" >&2

  auth_cmd='{"type": "auth", "access_token": "$HA_TOKEN"}'
  device_cmd='{"id": 1, "type": "config/device_registry/list"}'

  # First get device ID
  device_id=$({
    echo "$auth_cmd"
    sleep 0.5
    echo "$device_cmd"
    sleep 2
  } | sed "s|\$HA_TOKEN|$HA_TOKEN|g" | websocat -n "$WS_URL" 2>/dev/null | \
    jq -r --arg name "$DEVICE_NAME" '.result[] | select(.name | ascii_downcase | contains($name | ascii_downcase)) | .id' | head -1)

  if [[ -z "$device_id" ]]; then
    err "Device '$DEVICE_NAME' not found"
  fi

  echo "[INFO] Found device_id: $device_id" >&2

  # Query entities for this device
  entity_cmd='{"id": 2, "type": "config/entity_registry/list"}'

  {
    echo "$auth_cmd"
    sleep 0.5
    echo "$entity_cmd"
    sleep 2
  } | sed "s|\$HA_TOKEN|$HA_TOKEN|g" | websocat -n "$WS_URL" 2>/dev/null | \
    jq --arg dev_id "$device_id" '[.result[] | select(.device_id == $dev_id)] | sort_by(.platform)'
fi

echo "[INFO] Query complete" >&2
