#!/bin/bash
# Query Home Assistant WebSocket API for entities matching a device

set -euo pipefail

# Source centralized configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"

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

# Export pass environment (from config.sh)
export GNUPGHOME
export PASSWORD_STORE_DIR

err() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

sync_secret() {
  local secrets_key="$1"
  local pass_path="$2"

  local secrets_value
  if [[ -f "$SECRETS_YAML" ]]; then
    secrets_value=$(grep "^${secrets_key}:" "$SECRETS_YAML" | cut -d'"' -f2 || echo "")
  fi

  # Check if pass has this secret
  local pass_value=""
  if pass show "$pass_path" &>/dev/null; then
    pass_value=$(pass show "$pass_path")
  fi

  # If different or missing, update pass
  if [[ "$pass_value" != "$secrets_value" ]]; then
    echo "$secrets_value" | pass insert -f "$pass_path" 2>&1 || true
  fi

  echo "$secrets_value"
}

HA_TOKEN=$(sync_secret "ha_token" "iotstack/common/ha_token" || pass show "iotstack/common/ha_token" 2>/dev/null || echo "")
HA_TOKEN=$(printf '%s' "$HA_TOKEN" | xargs)  # Trim all whitespace


HA_URL=$(sync_secret "ha_url" "iotstack/common/ha_url" || pass show "iotstack/common/ha_url" 2>/dev/null || echo "$HA_URL")
HA_URL=$(printf '%s' "$HA_URL" | xargs)  # Trim all whitespace


echo "[INFO] Using HA_URL: $HA_URL" >&2
echo "[DEBUG] HA_URL length: ${#HA_URL} chars" >&2

# Step 1: Get device list and find matching device_id
echo "[DEBUG] Fetching device registry from: $HA_URL/api/config/device_registry/list" >&2
if ! device_data=$(curl -v -m 10 -X GET \
  -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  "$HA_URL/api/config/device_registry/list" 2>&1); then
  err "Failed to query device registry: $device_data"
fi

# Check if response is valid JSON
if ! echo "$device_data" | jq empty 2>/dev/null; then
  err "Invalid JSON response from device registry:\n$device_data"
fi

# If --list flag, show all devices and exit
if [[ "$LIST_DEVICES" == "true" ]]; then
  echo "[INFO] Available devices:" >&2
  echo "$device_data" | jq -r '.[] | "  \(.id): \(.name)"'
  exit 0
fi

# Look for device matching name or id containing DEVICE_NAME (case-insensitive)
echo "[INFO] Querying entities for device: $DEVICE_NAME" >&2
echo "[DEBUG] Searching for device matching: '$DEVICE_NAME'" >&2
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

# Step 2: Query entity registry for entities belonging to this device
echo "[DEBUG] Fetching entity registry..." >&2
if ! entity_data=$(curl -s -m 10 -X GET \
  -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  "$HA_URL/api/config/entity_registry/list" 2>&1); then
  err "Failed to query entity registry: $entity_data"
fi

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
