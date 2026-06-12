#!/bin/bash
# write-nvs-secrets.sh
# Write device-specific secrets to NVS partition after firmware flash
# Accepts pre-computed device-specific OTA password (computed by iotstack.sh)
#
# Usage:
#   ./scripts/write-nvs-secrets.sh /dev/ttyACM0 device_mac device_role ota_password
# Example:
#   ./scripts/write-nvs-secrets.sh /dev/ttyACM0 1af95c recovery a1b2c3d4e5f6

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
RST='\033[0m'

err()  { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }
ok()   { echo -e "${GRN}[OK]${RST} $*"; }
info() { echo -e "${YLW}[INFO]${RST} $*"; }

# Arguments
TTY_DEVICE="${1:-}"
DEVICE_MAC="${2:-}"
DEVICE_ROLE="${3:-}"
DEVICE_OTA_PASSWORD="${4:-}"

[[ -z "$TTY_DEVICE" ]] && err "Usage: $0 <tty_device> <device_mac> <device_role> <ota_password>"
[[ -z "$DEVICE_MAC" ]] && err "Usage: $0 <tty_device> <device_mac> <device_role> <ota_password>"
[[ -z "$DEVICE_ROLE" ]] && err "Usage: $0 <tty_device> <device_mac> <device_role> <ota_password>"
[[ -z "$DEVICE_OTA_PASSWORD" ]] && err "Usage: $0 <tty_device> <device_mac> <device_role> <ota_password>"

[[ ! -e "$TTY_DEVICE" ]] && err "TTY device not found: $TTY_DEVICE"

# ── Retrieve role-based secrets from pass store ────────────────────────────
info "Retrieving secrets for role: $DEVICE_ROLE"

# Get WiFi credentials (from common store, not role-specific)
WIFI_SSID=$(pass show "iotstack/common/wifi_ssid" 2>/dev/null || echo "")
WIFI_PASSWORD=$(pass show "iotstack/common/wifi_password" 2>/dev/null || echo "")

if [[ -z "$WIFI_SSID" || -z "$WIFI_PASSWORD" ]]; then
  err "WiFi credentials not found in pass store. Set with:
  pass insert iotstack/common/wifi_ssid
  pass insert iotstack/common/wifi_password"
fi

# Get role-based API encryption key for derivation
API_ENCRYPTION_KEY_BASE=$(pass show "iotstack/roles/${DEVICE_ROLE}/api_encryption_key" 2>/dev/null || echo "")

if [[ -z "$API_ENCRYPTION_KEY_BASE" ]]; then
  info "API encryption key not found for role: $DEVICE_ROLE, generating..."
  API_ENCRYPTION_KEY_BASE=$(openssl rand -base64 32 | tr -d '\n')
  # Store it in pass
  { echo "$API_ENCRYPTION_KEY_BASE"; echo "$API_ENCRYPTION_KEY_BASE"; } | \
    pass insert -f "iotstack/roles/${DEVICE_ROLE}/api_encryption_key" 2>/dev/null || \
    err "Failed to store API encryption key in pass"
  ok "API encryption key generated and stored for role: $DEVICE_ROLE"
fi

# ── Derive device-specific API key ────────────────────────────────────────
info "Deriving device-specific API encryption key from role + MAC"

# OTA password is pre-computed and passed as parameter (never stored on disk)
# API key is derived from role secret + MAC: sha256(base | mac)
DEVICE_API_KEY=$(echo -n "${API_ENCRYPTION_KEY_BASE}|${DEVICE_MAC}" | sha256sum | cut -c1-64)

info "Device secrets ready"
ok "OTA Password: (from parameter)"
ok "API Key: (derived)"

# ── Use Python to generate and write NVS data ────────────────────────────
info "Writing NVS partition to device..."

python3 << 'NVSPYTHON'
import json
import sys
import hashlib
import struct

wifi_ssid = sys.argv[1]
wifi_password = sys.argv[2]
ota_password = sys.argv[3]
api_key = sys.argv[4]
device_mac = sys.argv[5]
tty_device = sys.argv[6]

# Create NVS-format data (simplified key-value store)
# For now, store as JSON which firmware can parse
nvs_data = {
    "wifi_ssid": wifi_ssid,
    "wifi_password": wifi_password,
    "ota_password": ota_password,
    "api_encryption_key": api_key,
}

# Write to temporary file
nvs_file = f"/tmp/nvs_{device_mac}.json"
with open(nvs_file, 'w') as f:
    json.dump(nvs_data, f, separators=(',', ':'))

# Pad to 0x6000 (24KB NVS partition size)
with open(nvs_file, 'r+b') as f:
    current_size = f.seek(0, 2)
    padding_needed = 0x6000 - current_size
    if padding_needed > 0:
        f.write(b'\xff' * padding_needed)

print(f"[OK] NVS partition prepared ({current_size} bytes)")

# Write to device at offset 0x3d000 (after firmware)
import subprocess
result = subprocess.run([
    'esptool', '--chip', 'esp32c6', '--port', tty_device, '--baud', '460800',
    'write_flash', '0x3d000', nvs_file
], capture_output=True, text=True)

if result.returncode == 0:
    print("[OK] NVS written to device")
else:
    print(f"[ERROR] Failed to write NVS: {result.stderr}")
    sys.exit(1)

# Cleanup
import os
os.remove(nvs_file)

NVSPYTHON
"$WIFI_SSID" "$WIFI_PASSWORD" "$DEVICE_OTA_PASSWORD" "$DEVICE_API_KEY" "$DEVICE_MAC" "$TTY_DEVICE"

ok "Device configured with device-specific secrets"
