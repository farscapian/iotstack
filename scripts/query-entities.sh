#!/bin/bash
# Query Home Assistant WebSocket API for entities matching a device

set -euo pipefail

# Source centralized configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"

DEVICE_NAME="${1:-}"
LIST_DEVICES="${LIST_DEVICES:-false}"

if [[ "$DEVICE_NAME" == "--list" ]] || [[ "$DEVICE_NAME" == "-l" ]]; then
  LIST_DEVICES=true
  DEVICE_NAME=""
fi

if [[ -z "$DEVICE_NAME" && "$LIST_DEVICES" != "true" ]]; then
  echo "Usage: $0 <device-name>" >&2
  echo "       $0 --list     (list all devices)" >&2
  exit 1
fi

err() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

sync_secret() {
  local secrets_key="$1"
  local pass_path="$2"

  local secrets_value=""
  if [[ -f "${SECRETS_YAML:-}" ]]; then
    secrets_value=$(grep "^${secrets_key}:" "$SECRETS_YAML" | cut -d'"' -f2 || echo "")
  fi

  local pass_value=""
  if pass show "$pass_path" &>/dev/null; then
    pass_value=$(pass show "$pass_path")
  fi

  if [[ -n "$secrets_value" && "$pass_value" != "$secrets_value" ]]; then
    echo "$secrets_value" | pass insert -f "$pass_path" 2>&1 || true
  fi

  echo "$secrets_value"
}

# Sync legacy secrets.yaml values into pass, then prompt/validate if still missing.
sync_secret "ha_token" "iotstack/common/ha_token" >/dev/null 2>&1 || true
sync_secret "ha_url" "iotstack/common/ha_url" >/dev/null 2>&1 || true

# shellcheck source=scripts/ensure-integration-secrets.sh
source "${SCRIPT_DIR}/ensure-integration-secrets.sh"
ensure_ha_integration

echo "[INFO] Using HA_URL: $HA_URL" >&2

echo "[DEBUG] Fetching device registry via WebSocket" >&2
device_data=$(ha_websocket_query "config/device_registry/list")

if ! echo "$device_data" | jq empty 2>/dev/null; then
  err "Invalid JSON response from device registry"
fi

if [[ "$LIST_DEVICES" == "true" ]]; then
  echo "[INFO] Available devices:" >&2
  echo "$device_data" | jq -r '.[] | "  \(.id): \(.name)"'
  exit 0
fi

echo "[INFO] Querying entities for device: $DEVICE_NAME" >&2
device_id=$(echo "$device_data" | jq -r --arg name "$DEVICE_NAME" '
  .[] |
  select(
    (.name | ascii_downcase | contains($name | ascii_downcase)) or
    (.id | ascii_downcase | contains($name | ascii_downcase))
  ) |
  .id
' | head -1)

if [[ -z "$device_id" ]]; then
  warn "Device '$DEVICE_NAME' not found in device registry"
  echo "[DEBUG] Available devices:" >&2
  echo "$device_data" | jq -r '.[] | "  \(.id): \(.name)"' >&2
  exit 1
fi

echo "[DEBUG] Found device_id: $device_id" >&2
echo "[DEBUG] Fetching entity registry via WebSocket" >&2
entity_data=$(ha_websocket_query "config/entity_registry/list")

if ! echo "$entity_data" | jq empty 2>/dev/null; then
  err "Invalid JSON response from entity registry"
fi

echo "$entity_data" | jq --arg dev_id "$device_id" '
  [
    .[] |
    select(.device_id == $dev_id) |
    {
      entity_id,
      name,
      original_name,
      device_id,
      platform,
      disabled_by
    }
  ] | sort_by(.platform)
'

echo "[INFO] Query complete" >&2