#!/bin/bash
# Query Home Assistant WebSocket API for devices/entities
# Auto-installs websocat if needed

set -euo pipefail

DEVICE_NAME="${1:-}"
LIST_DEVICES="${LIST_DEVICES:-false}"
HA_URL="${HA_URL:-http://localhost:8123}"

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

  local install_dir="${HOME}/.local/bin"
  mkdir -p "$install_dir"

  # Try cargo first (most reliable)
  if command -v cargo &>/dev/null; then
    echo "[INFO] Installing websocat via cargo..." >&2
    if cargo install websocat --root "$install_dir" 2>&1 | grep -q "Installed"; then
      export PATH="$install_dir/bin:$PATH"
      echo "[OK] websocat installed via cargo to $install_dir/bin" >&2
      return 0
    fi
  fi

  # Try apt
  if command -v apt &>/dev/null; then
    echo "[INFO] Trying apt..." >&2
    if sudo apt update -qq && sudo apt install -y websocat >/dev/null 2>&1; then
      echo "[OK] websocat installed via apt" >&2
      return 0
    fi
  fi

  # Download latest prebuilt binary from GitHub
  echo "[INFO] Downloading websocat from GitHub releases..." >&2
  local arch
  arch=$(uname -m)
  # os_type variable not used currently, can be removed if no future need
  # local os_type
  # os_type=$(uname -s | tr '[:upper:]' '[:lower:]')

  # Map architecture to GitHub release naming
  local binary_name=""
  case "$arch" in
    x86_64)
      binary_name="websocat.x86_64-unknown-linux-musl"
      ;;
    aarch64)
      binary_name="websocat.aarch64-unknown-linux-musl"
      ;;
    *)
      err "Unsupported architecture: $arch. Install websocat manually from https://github.com/vi/websocat/releases"
      ;;
  esac

  # Download from latest release
  local download_url="https://github.com/vi/websocat/releases/download/v1.14.1/${binary_name}"

  if curl -sL "$download_url" -o "$install_dir/websocat" 2>/dev/null && [[ -s "$install_dir/websocat" ]]; then
    if file "$install_dir/websocat" | grep -q "ELF"; then
      chmod +x "$install_dir/websocat"
      export PATH="$install_dir:$PATH"
      echo "[OK] websocat installed to $install_dir" >&2
      return 0
    else
      err "Downloaded file is not a valid ELF binary"
    fi
  else
    err "Failed to download websocat from $download_url"
  fi
}

sync_secret() {
  local secrets_key="$1"
  local pass_path="$2"

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
    # Pass requires password twice (for confirmation)
    if ! { echo "$secrets_value"; echo "$secrets_value"; } | pass insert -f "$pass_path" 2>&1; then
      warn "Failed to sync '$pass_path' to pass - may cause repeated warnings"
    fi
  fi
  # If they match, don't warn - already in sync

  printf '%s' "$secrets_value"
}

# Get secrets
HA_TOKEN=$(sync_secret "ha_token" "iotstack/common/ha_token" || pass show "iotstack/common/ha_token" 2>/dev/null || echo "")
HA_TOKEN=$(printf '%s' "$HA_TOKEN" | xargs)

HA_URL=$(sync_secret "ha_url" "iotstack/common/ha_url" || pass show "iotstack/common/ha_url" 2>/dev/null || echo "$HA_URL")
HA_URL=$(printf '%s' "$HA_URL" | xargs)

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

  ws_response=$({
    echo "$auth_cmd"
    sleep 0.5
    echo "$device_cmd"
    sleep 2
  } | sed "s|\$HA_TOKEN|$HA_TOKEN|g" | websocat -n "$WS_URL" 2>/dev/null)

  echo "[DEBUG] WebSocket response:" >&2
  echo "$ws_response" | jq '.' >&2

  echo "$ws_response" | jq -r 'select(.id == 1) | .result[] | "\(.id): \(.name)"'
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
