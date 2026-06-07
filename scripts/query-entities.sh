#!/bin/bash
# Query Home Assistant WebSocket API for entities matching a device
# Uses pass as operational source, secrets.yaml as authoritative source

set -euo pipefail

DEVICE_NAME="${1:-BILRESA5}"
HA_URL="${HA_URL:-http://localhost:8123}"
SECRETS_YAML="${SECRETS_YAML:-$(dirname "$0")/../yamls/secrets.yaml}"

# Setup pass environment
export GNUPGHOME="${HOME}/.iotstack/.gnupg"
export PASSWORD_STORE_DIR="${HOME}/.iotstack/.pass"

err() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

# Helper: sync secret from secrets.yaml to pass if different
sync_secret() {
  local secret_name="$1"
  local secrets_key="$2"
  local pass_path="$3"

  # Read from secrets.yaml (authoritative)
  local secrets_value
  if [[ -f "$SECRETS_YAML" ]]; then
    secrets_value=$(grep "^${secrets_key}:" "$SECRETS_YAML" | cut -d'"' -f2 || echo "")
  fi

  if [[ -z "$secrets_value" ]]; then
    return 1  # Not in secrets.yaml
  fi

  # Check if pass has this secret
  local pass_value=""
  if pass show "$pass_path" &>/dev/null; then
    pass_value=$(pass show "$pass_path")
  fi

  # If different or missing, update pass
  if [[ "$pass_value" != "$secrets_value" ]]; then
    if [[ -z "$pass_value" ]]; then
      warn "Secret '$pass_path' not in pass, syncing from secrets.yaml"
    else
      warn "Secret '$pass_path' differs from secrets.yaml, updating pass"
    fi
    echo "$secrets_value" | pass insert -f "$pass_path" 2>&1 || true
  fi

  echo "$secrets_value"
}

# Get HA_TOKEN: sync from secrets.yaml if needed, then use pass
HA_TOKEN=$(sync_secret "HA Token" "ha_token" "iotstack/common/ha_token" || pass show "iotstack/common/ha_token" 2>/dev/null || echo "")

[[ -z "$HA_TOKEN" ]] && err "HA_TOKEN not found in pass or secrets.yaml"

# Get HA_URL: sync from secrets.yaml if needed, then use pass or default
HA_URL=$(sync_secret "HA URL" "ha_url" "iotstack/common/ha_url" || pass show "iotstack/common/ha_url" 2>/dev/null || echo "$HA_URL")

[[ -z "$HA_URL" ]] && err "HA_URL not found in pass, secrets.yaml, or HA_URL env var"

echo "[INFO] Querying entities for device: $DEVICE_NAME" >&2
echo "[INFO] Using HA_URL: $HA_URL" >&2

# Use curl with WebSocket to query entities
# We'll use the REST API which is simpler than raw WebSocket
curl -s -X POST \
  -H "Authorization: Bearer $HA_TOKEN" \
  -H "Content-Type: application/json" \
  "$HA_URL/api/config/entity_registry/list" | \
  jq --arg device "$DEVICE_NAME" '
    .[] |
    select(.device_id != null) |
    select(.original_name != null) |
    select(.original_name | contains($device)) |
    {
      entity_id,
      original_name,
      device_id,
      platform,
      disabled_by
    }
  ' | jq -s '.'

echo "[INFO] Query complete" >&2
