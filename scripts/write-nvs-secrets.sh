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

# Get or prompt for credential (lazy-loading on demand)
_get_or_prompt_credential() {
  local pass_path="$1"
  local prompt_text="$2"
  local is_secret="${3:-true}"  # true for passwords, false for non-secret values

  # Try to get from pass store
  local value=$(pass show "$pass_path" 2>/dev/null || echo "")

  # If not set or is placeholder, prompt user
  if [[ -z "$value" || "$value" == "CONFIGURE_ME" ]]; then
    echo "" >&2
    echo -ne "${YLW}[PROMPT]${RST} $prompt_text: " >&2

    if [[ "$is_secret" == "true" ]]; then
      # For secrets, read without echo
      read -s value </dev/tty 2>/dev/null || value=""
      echo >&2
    else
      # For non-secrets, read normally
      read value </dev/tty 2>/dev/null || value=""
    fi

    if [[ -z "$value" ]]; then
      err "Credential required: $pass_path"
    fi

    # Store in pass for future use (double echo for confirmation)
    info "Storing credential in pass store: $pass_path"
    { echo "$value"; echo "$value"; } | pass insert -f "$pass_path" 2>/dev/null || \
      err "Failed to store credential in pass store"
  fi

  echo "$value"
}

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

# ── Retrieve role-based secrets from pass store (lazy-load on demand) ─────
info "Retrieving secrets for role: $DEVICE_ROLE"

# Get WiFi credentials (lazy-load if not set or placeholder)
WIFI_SSID=$(_get_or_prompt_credential "iotstack/common/wifi_ssid" "WiFi network name (SSID)" false)
WIFI_PASSWORD=$(_get_or_prompt_credential "iotstack/common/wifi_password" "WiFi password" true)

# Get optional Thread credentials (lazy-load with skip option)
THREAD_TLV=$(pass show "iotstack/common/thread_tlv" 2>/dev/null || echo "")
if [[ -z "$THREAD_TLV" || "$THREAD_TLV" == "CONFIGURE_ME" ]]; then
  echo -ne "${YLW}[PROMPT]${RST} Thread TLV commissioning string (optional, press Enter to skip): " >&2
  read -s THREAD_TLV_INPUT </dev/tty 2>/dev/null || THREAD_TLV_INPUT=""
  echo >&2
  if [[ -n "$THREAD_TLV_INPUT" ]]; then
    { echo "$THREAD_TLV_INPUT"; echo "$THREAD_TLV_INPUT"; } | pass insert -f "iotstack/common/thread_tlv" 2>/dev/null || true
    THREAD_TLV="$THREAD_TLV_INPUT"
    ok "Thread TLV stored in pass"
  else
    THREAD_TLV=""
  fi
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

export WIFI_SSID="$WIFI_SSID" WIFI_PASSWORD="$WIFI_PASSWORD" \
       OTA_PASSWORD="$DEVICE_OTA_PASSWORD" API_KEY="$DEVICE_API_KEY" \
       THREAD_TLV="$THREAD_TLV" DEVICE_MAC="$DEVICE_MAC" TTY_DEVICE="$TTY_DEVICE"

python3 << 'NVSPYTHON'
import os
import subprocess
import sys

# Get environment variables
wifi_ssid = os.environ['WIFI_SSID']
wifi_password = os.environ['WIFI_PASSWORD']
ota_password = os.environ['OTA_PASSWORD']
api_key = os.environ['API_KEY']
thread_tlv = os.environ.get('THREAD_TLV', '')
device_mac = os.environ['DEVICE_MAC']
tty_device = os.environ['TTY_DEVICE']

# Create CSV for NVS partition generator
# Format: key,type,encoding,value
nvs_csv_path = f"/tmp/nvs_{device_mac}.csv"
with open(nvs_csv_path, 'w') as f:
    f.write("key,type,encoding,value\n")
    f.write(f"wifi_ssid,data,string,{wifi_ssid}\n")
    f.write(f"wifi_password,data,string,{wifi_password}\n")
    f.write(f"ota_password,data,string,{ota_password}\n")
    f.write(f"api_encryption_key,data,string,{api_key}\n")
    if thread_tlv:
        f.write(f"thread_tlv,data,string,{thread_tlv}\n")

print(f"[OK] Created NVS CSV file for nvs_partition_gen")

# Use ESP-IDF nvs_partition_gen to create proper NVS binary
# The tool generates a binary in NVS format (not raw JSON)
nvs_bin_path = f"/tmp/nvs_{device_mac}.bin"

try:
    # Import the NVS partition generator from ESP-IDF
    from esp_idf_nvs_partition_gen import nvs_partition_gen

    print(f"[OK] Using nvs_partition_gen to generate proper NVS partition")

    # Generate the binary file
    nvs_partition_gen.generate(
        input_file=nvs_csv_path,
        output_file=nvs_bin_path,
        size=0x6000,  # 24KB NVS partition size
        version=2  # Version 2 supports multipage blobs
    )

    print(f"[OK] NVS partition binary generated at {nvs_bin_path}")

except Exception as e:
    print(f"[ERROR] Failed to generate NVS partition: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

# Write to device at offset 0x9000 (NVS partition)
# Using 9600 baud for reliable writes (higher speeds cause corruption)
print(f"[OK] Writing NVS partition to device at 0x9000...")
result = subprocess.run([
    'esptool', '--chip', 'esp32c6', '--port', tty_device, '--baud', '9600',
    'write_flash', '0x9000', nvs_bin_path
], capture_output=True, text=True)

if result.returncode == 0:
    print("[OK] NVS written to device successfully")
else:
    print(f"[ERROR] Failed to write NVS: {result.stderr}")
    sys.exit(1)

# Cleanup
os.remove(nvs_csv_path)
os.remove(nvs_bin_path)

NVSPYTHON

ok "Device configured with device-specific secrets"
