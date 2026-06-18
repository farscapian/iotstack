#!/bin/bash
# write-nvs-secrets.sh
# Write device-specific secrets to NVS partition after firmware flash.
# Computes both bootstrap-derived and (optionally) production-derived secrets.
#
# Usage:
#   ./scripts/write-nvs-secrets.sh /dev/ttyACM0 device_mac [production_role]
#   ./scripts/write-nvs-secrets.sh --print-api-json device_mac [production_role]
# Examples:
#   ./scripts/write-nvs-secrets.sh /dev/ttyACM0 1af95c              # bootstrap only (USB)
#   ./scripts/write-nvs-secrets.sh /dev/ttyACM0 1af95c bleproxy     # bootstrap + production (USB)
#   ./scripts/write-nvs-secrets.sh --print-api-json 1af95c bleproxy  # JSON for update_nvs_secrets API

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source centralized configuration
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"

# Colors
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
RST='\033[0m'

err()  { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }
ok()   { echo -e "${GRN}[OK]${RST} $*" >&2; }
info() { echo -e "${YLW}[INFO]${RST} $*" >&2; }

# Get or prompt for credential (lazy-loading on demand)
_get_or_prompt_credential() {
  local pass_path="$1"
  local prompt_text="$2"
  local is_secret="${3:-true}"  # true for passwords, false for non-secret values

  # Try to get from pass store
  local value
  value=$(pass show "$pass_path" 2>/dev/null || echo "")

  # If not set or is placeholder, prompt user
  if [[ -z "$value" || "$value" == "CONFIGURE_ME" ]]; then
    echo "" >&2
    echo -ne "${YLW}[PROMPT]${RST} $prompt_text: " >&2

    if [[ "$is_secret" == "true" ]]; then
      read -rs value </dev/tty 2>/dev/null || value=""
      echo >&2
    else
      read -r value </dev/tty 2>/dev/null || value=""
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

# Get or generate a role OTA password (no prompt; auto-generates if absent)
_get_or_generate_role_ota_password() {
  local pass_path="$1"
  local role_label="$2"
  local value
  value=$(pass show "$pass_path" 2>/dev/null || echo "")
  if [[ -z "$value" ]]; then
    info "OTA password not found for role: $role_label, generating..."
    value=$(openssl rand -hex 16)
    { echo "$value"; echo "$value"; } | pass insert -f "$pass_path" 2>/dev/null || \
      err "Failed to store OTA password in pass: $pass_path"
    ok "OTA password generated and stored for role: $role_label"
  fi
  echo "$value"
}

# Arguments
PRINT_API_JSON=0
TTY_DEVICE=""
DEVICE_MAC=""
PRODUCTION_ROLE=""

if [[ "${1:-}" == "--print-api-json" ]]; then
  PRINT_API_JSON=1
  DEVICE_MAC="${2:-}"
  PRODUCTION_ROLE="${3:-}"
  [[ -z "$DEVICE_MAC" ]] && err "Usage: $0 --print-api-json <device_mac> [production_role]"
else
  TTY_DEVICE="${1:-}"
  DEVICE_MAC="${2:-}"
  PRODUCTION_ROLE="${3:-}"
  [[ -z "$TTY_DEVICE" || -z "$DEVICE_MAC" ]] && err "Usage: $0 <tty_device> <device_mac> [production_role]"
  [[ ! -e "$TTY_DEVICE" ]] && err "TTY device not found: $TTY_DEVICE"
fi

# Read NVS size from the generated partition table (USB path only)
if [[ "$PRINT_API_JSON" != "1" ]]; then
  if [[ ! -f "$PARTITION_TABLE" ]]; then
    err "Partition table not found: $PARTITION_TABLE\nMake sure to compile firmware first (which generates the partition table)"
  fi

  # Extract NVS offset and size from partition table CSV
  # Format: nvs,        data,  nvs,        0x9000,   0x4000,
  NVS_OFFSET=$(awk -F',' '/^nvs[[:space:]]*,/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4}' "$PARTITION_TABLE" | head -1)
  [[ -z "$NVS_OFFSET" ]] && err "Could not find NVS partition offset in: $PARTITION_TABLE"

  NVS_SIZE=$(awk -F',' '/^nvs[[:space:]]*,/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $5); print $5}' "$PARTITION_TABLE" | head -1)
  [[ -z "$NVS_SIZE" ]] && err "Could not find NVS partition size in: $PARTITION_TABLE"

  info "Using NVS partition offset: $NVS_OFFSET, size: $NVS_SIZE from generated partition table"
fi

# -- Retrieve shared credentials --------------------------------------------
info "Retrieving WiFi credentials..."
WIFI_SSID=$(_get_or_prompt_credential "iotstack/common/wifi_ssid" "WiFi network name (SSID)" false)
WIFI_PASSWORD=$(_get_or_prompt_credential "iotstack/common/wifi_password" "WiFi password" true)

# Get optional Thread credentials (lazy-load with skip option)
THREAD_TLV=$(pass show "iotstack/common/thread_tlv" 2>/dev/null || echo "")
if [[ -z "$THREAD_TLV" || "$THREAD_TLV" == "CONFIGURE_ME" ]]; then
  echo -ne "${YLW}[PROMPT]${RST} Thread TLV commissioning string (optional, press Enter to skip): " >&2
  read -rs THREAD_TLV_INPUT </dev/tty 2>/dev/null || THREAD_TLV_INPUT=""
  echo >&2
  if [[ -n "$THREAD_TLV_INPUT" ]]; then
    { echo "$THREAD_TLV_INPUT"; echo "$THREAD_TLV_INPUT"; } | pass insert -f "iotstack/common/thread_tlv" 2>/dev/null || true
    THREAD_TLV="$THREAD_TLV_INPUT"
    ok "Thread TLV stored in pass"
  else
    THREAD_TLV=""
  fi
fi

# -- Derive bootstrap device-specific OTA password --------------------------
info "Computing bootstrap secrets for device: $DEVICE_MAC"
BOOTSTRAP_OTA_BASE=$(_get_or_generate_role_ota_password "$(iotstack_bootstrap_pass_ota_path)" "bootstrap")
BOOTSTRAP_OTA_PASSWORD=$(echo -n "${BOOTSTRAP_OTA_BASE}|${DEVICE_MAC}" | sha256sum | cut -c1-32)

# -- Derive production device-specific API key (if production role given) --
PROD_API_KEY=""
if [[ -n "$PRODUCTION_ROLE" ]]; then
  if ! grep -q "^${PRODUCTION_ROLE}=" "$ROLES_CONF" 2>/dev/null; then
    err "Unknown production role: $PRODUCTION_ROLE (not in $ROLES_CONF)"
  fi
  info "Computing production API key for role: $PRODUCTION_ROLE (device: $DEVICE_MAC)"

  PROD_API_BASE=$(pass show "iotstack/roles/${PRODUCTION_ROLE}/api_encryption_key" 2>/dev/null || echo "")
  if [[ -z "$PROD_API_BASE" ]]; then
    info "API encryption key not found for role: $PRODUCTION_ROLE, generating..."
    PROD_API_BASE=$(openssl rand -base64 32 | tr -d '\n')
    { echo "$PROD_API_BASE"; echo "$PROD_API_BASE"; } | \
      pass insert -f "iotstack/roles/${PRODUCTION_ROLE}/api_encryption_key" 2>/dev/null || \
      err "Failed to store API encryption key in pass"
    ok "API encryption key generated and stored for role: $PRODUCTION_ROLE"
  fi
  PROD_API_KEY=$(echo -n "${PROD_API_BASE}|${DEVICE_MAC}" | sha256sum | cut -c1-64)
fi

info "Device secrets ready"
ok "Bootstrap OTA password: (derived)"
if [[ -n "$PRODUCTION_ROLE" ]]; then
  ok "Production API key: (derived for role: $PRODUCTION_ROLE)"
fi

# -- Matrix panel layout (matrix_hub75 reads these at boot) -------------------
# Set via flash flags, env override, or pass per role:
#   iotstack flash matrixdisplay /dev/ttyACM0 --panel-count=2 --matrix-panel-width=64 --matrix-panel-height=32
#   MATRIX_COLS=2 iotstack flash matrixdisplay /dev/ttyACM0
#   pass: iotstack/roles/matrixdisplay/matrix_{cols,panel_w,panel_h}
WRITE_MATRIX_LAYOUT=0
MATRIX_COLS="${MATRIX_COLS:-}"
MATRIX_PANEL_W="${MATRIX_PANEL_W:-}"
MATRIX_PANEL_H="${MATRIX_PANEL_H:-}"
if [[ "$PRODUCTION_ROLE" == "matrixdisplay" ]] || \
   [[ -n "$MATRIX_COLS" || -n "$MATRIX_PANEL_W" || -n "$MATRIX_PANEL_H" ]]; then
  WRITE_MATRIX_LAYOUT=1
  if [[ -n "$PRODUCTION_ROLE" ]]; then
    [[ -z "$MATRIX_COLS" ]] && MATRIX_COLS=$(pass show "iotstack/roles/${PRODUCTION_ROLE}/matrix_cols" 2>/dev/null || echo "")
    [[ -z "$MATRIX_PANEL_W" ]] && MATRIX_PANEL_W=$(pass show "iotstack/roles/${PRODUCTION_ROLE}/matrix_panel_w" 2>/dev/null || echo "")
    [[ -z "$MATRIX_PANEL_H" ]] && MATRIX_PANEL_H=$(pass show "iotstack/roles/${PRODUCTION_ROLE}/matrix_panel_h" 2>/dev/null || echo "")
  fi
  MATRIX_COLS="${MATRIX_COLS:-1}"
  MATRIX_PANEL_W="${MATRIX_PANEL_W:-64}"
  MATRIX_PANEL_H="${MATRIX_PANEL_H:-32}"
  if [[ "$MATRIX_COLS" != "1" && "$MATRIX_COLS" != "2" ]]; then
    err "MATRIX_COLS must be 1 or 2 (got: $MATRIX_COLS)"
  fi
  info "Matrix layout NVS: ${MATRIX_COLS} panel(s), ${MATRIX_PANEL_W}x${MATRIX_PANEL_H} px each"
fi

if [[ "$PRINT_API_JSON" == "1" ]]; then
  export WIFI_SSID WIFI_PASSWORD BOOTSTRAP_OTA_PASSWORD PROD_API_KEY THREAD_TLV \
         WRITE_MATRIX_LAYOUT MATRIX_COLS MATRIX_PANEL_W MATRIX_PANEL_H PRODUCTION_ROLE
  python3 - <<'PY'
import json, os

payload = {
    "wifi_ssid": os.environ["WIFI_SSID"],
    "wifi_password": os.environ["WIFI_PASSWORD"],
    "ota_password": os.environ["BOOTSTRAP_OTA_PASSWORD"],
    "api_key": os.environ.get("PROD_API_KEY", ""),
    "thread_tlv": os.environ.get("THREAD_TLV", ""),
}
if os.environ.get("WRITE_MATRIX_LAYOUT") == "1":
    payload["matrix_cols"] = os.environ.get("MATRIX_COLS", "1")
    payload["matrix_panel_w"] = os.environ.get("MATRIX_PANEL_W", "64")
    payload["matrix_panel_h"] = os.environ.get("MATRIX_PANEL_H", "32")
prod_role = os.environ.get("PRODUCTION_ROLE", "")
if prod_role:
    payload["device_role"] = prod_role
print(json.dumps(payload))
PY
  exit 0
fi

# -- Use Python to generate NVS data ----------------------------------------
info "Writing NVS partition to device..."

export WIFI_SSID="$WIFI_SSID" WIFI_PASSWORD="$WIFI_PASSWORD" \
       BOOTSTRAP_OTA_PASSWORD="$BOOTSTRAP_OTA_PASSWORD" \
       PROD_API_KEY="$PROD_API_KEY" \
       THREAD_TLV="$THREAD_TLV" DEVICE_MAC="$DEVICE_MAC" TTY_DEVICE="$TTY_DEVICE" \
       NVS_SIZE="$NVS_SIZE" WRITE_MATRIX_LAYOUT="$WRITE_MATRIX_LAYOUT" \
       MATRIX_COLS="${MATRIX_COLS:-}" MATRIX_PANEL_W="${MATRIX_PANEL_W:-}" MATRIX_PANEL_H="${MATRIX_PANEL_H:-}" \
       PRODUCTION_ROLE="${PRODUCTION_ROLE:-}"

# Use ESP-IDF Python environment which has nvs_partition_gen installed
ESP_IDF_PYTHON="${HOME}/.espressif/python_env/idf6.1_py3.14_env/bin/python3"

# Generate NVS binary (store output to parse paths)
python_output=$($ESP_IDF_PYTHON << 'NVSPYTHON'
import os
import subprocess
import sys

# Get environment variables
wifi_ssid = os.environ['WIFI_SSID']
wifi_password = os.environ['WIFI_PASSWORD']
bootstrap_ota_password = os.environ['BOOTSTRAP_OTA_PASSWORD']
prod_api_key = os.environ.get('PROD_API_KEY', '')
thread_tlv = os.environ.get('THREAD_TLV', '')
production_role = os.environ.get('PRODUCTION_ROLE', '')
write_matrix_layout = os.environ.get('WRITE_MATRIX_LAYOUT', '0') == '1'
matrix_cols = os.environ.get('MATRIX_COLS', '1')
matrix_panel_w = os.environ.get('MATRIX_PANEL_W', '64')
matrix_panel_h = os.environ.get('MATRIX_PANEL_H', '32')
device_mac = os.environ['DEVICE_MAC']
nvs_size_str = os.environ['NVS_SIZE']  # e.g., "0x4000"

# Convert hex size string to decimal
nvs_size = int(nvs_size_str, 16)

# Create CSV for NVS partition generator
# Format: key,type,encoding,value
nvs_csv_path = f"/tmp/nvs_{device_mac}.csv"
with open(nvs_csv_path, 'w') as f:
    f.write("key,type,encoding,value\n")
    # Namespace row is REQUIRED -- without it nvs_partition_gen writes keys to
    # ns_index 0 (the reserved registry), making them unreachable via nvs_open().
    # Must match the NAMESPACE constant in external_components/nvs_secrets/nvs_secrets.cpp
    f.write("iotstack,namespace,,\n")
    f.write(f"wifi_ssid,data,string,{wifi_ssid}\n")
    f.write(f"wifi_password,data,string,{wifi_password}\n")
    # bootstrap reads this key for OTA authentication
    f.write(f"ota_password,data,string,{bootstrap_ota_password}\n")
    if prod_api_key:
        f.write(f"prod_api_key,data,string,{prod_api_key}\n")
    if thread_tlv:
        f.write(f"thread_tlv,data,string,{thread_tlv}\n")
    if write_matrix_layout:
        f.write(f"matrix_cols,data,u8,{matrix_cols}\n")
        f.write(f"matrix_panel_w,data,u16,{matrix_panel_w}\n")
        f.write(f"matrix_panel_h,data,u16,{matrix_panel_h}\n")
    if production_role:
        f.write(f"device_role,data,string,{production_role}\n")

print(f"[OK] Created NVS CSV file for nvs_partition_gen")

# Use ESP-IDF nvs_partition_gen to create proper NVS binary
nvs_bin_path = f"/tmp/nvs_{device_mac}.bin"

print(f"[OK] Generating NVS partition binary using esp_idf_nvs_partition_gen")

idf_python = os.path.expanduser('~/.espressif/python_env/idf6.1_py3.14_env/bin/python3')
result = subprocess.run([
    idf_python, '-m', 'esp_idf_nvs_partition_gen', 'generate',
    nvs_csv_path,        # input CSV file
    nvs_bin_path,        # output binary file
    f'0x{nvs_size:x}',   # partition size in bytes (dynamically read from partition table)
    '--version', '2'     # Version 2 (multipage blob support)
], capture_output=True, text=True)

if result.returncode != 0:
    print(f"[ERROR] Failed to generate NVS partition")
    print(f"[ERROR] stdout: {result.stdout}")
    print(f"[ERROR] stderr: {result.stderr}")
    sys.exit(1)

print(f"[OK] NVS partition binary generated at {nvs_bin_path}")
print(f"NVS_BIN_PATH={nvs_bin_path}")
print(f"NVS_CSV_PATH={nvs_csv_path}")
NVSPYTHON
)

# Show Python output (except the path lines)
while IFS= read -r line; do
  [[ "$line" =~ ^NVS_BIN_PATH= ]] || [[ "$line" =~ ^NVS_CSV_PATH= ]] || echo "$line"
done <<< "$python_output"

# Parse paths from Python output
NVS_BIN_PATH=""
NVS_CSV_PATH=""
while IFS= read -r line; do
  if [[ "$line" =~ ^NVS_BIN_PATH= ]]; then
    NVS_BIN_PATH="${line#NVS_BIN_PATH=}"
  elif [[ "$line" =~ ^NVS_CSV_PATH= ]]; then
    NVS_CSV_PATH="${line#NVS_CSV_PATH=}"
  fi
done <<< "$python_output"

if [[ -z "$NVS_BIN_PATH" ]] || [[ ! -f "$NVS_BIN_PATH" ]]; then
  err "NVS binary generation failed - file not found at: $NVS_BIN_PATH"
fi

# Chip: auto-detect from serial port
# shellcheck source=scripts/esp-serial.sh
source "${SCRIPT_DIR}/esp-serial.sh"
ESPTOOL_CHIP="${IOTSTACK_ESPTOOL_CHIP:-}"
if [[ -z "$ESPTOOL_CHIP" ]]; then
  ESPTOOL_CHIP=$(esp_detect_chip "$TTY_DEVICE" 2>/dev/null) || ESPTOOL_CHIP=esp32c6
fi

# Write to device using esptool via Python
ESPTOOL_BAUD=$(esp_esptool_baud_for_chip "$ESPTOOL_CHIP")
info "Writing NVS partition to device at $NVS_OFFSET (${ESPTOOL_CHIP}, ${ESPTOOL_BAUD} baud)..."
if python3 -m esptool --chip "$ESPTOOL_CHIP" --port "$TTY_DEVICE" --baud "$ESPTOOL_BAUD" --before default-reset write-flash "$NVS_OFFSET" "$NVS_BIN_PATH"; then
  ok "NVS written to device successfully"
else
  err "Failed to write NVS partition to device"
fi

# Cleanup temp files
rm -f "$NVS_CSV_PATH" "$NVS_BIN_PATH"

ok "Device configured with device-specific secrets"
