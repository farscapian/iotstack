#!/bin/bash
# read-nvs-secrets.sh -- Read device-specific secrets from the NVS partition via USB serial
#
# Usage:
# ./scripts/read-nvs-secrets.sh [--all] <key...> <tty_device>
# ./scripts/read-nvs-secrets.sh --all /dev/ttyACM0
# ./scripts/read-nvs-secrets.sh wifi_ssid ota_password /dev/ttyACM0
#
# Keys (namespace iotstack):
# wifi_ssid, wifi_password, ota_password, prod_api_key, thread_tlv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
RST='\033[0m'

err() { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }
ok() { echo -e "${GRN}[OK]${RST} $*"; }
info() { echo -e "${YLW}[INFO]${RST} $*"; }

VALID_KEYS=(wifi_ssid wifi_password ota_password prod_api_key thread_tlv device_role)

_is_valid_key() {
 local key="$1"
 local k
 for k in "${VALID_KEYS[@]}"; do
 [[ "$k" == "$key" ]] && return 0
 done
 return 1
}

_usage() {
 cat <<EOF
Usage: read-nvs-secrets.sh [--all] [key...] <tty_device>

Read secrets stored in the device NVS partition (namespace: iotstack).
Device must be connected via USB serial; NVS cannot be read over the network.

Arguments:
 --all Print all NVS keys (known keys first, then any others)
 <key...> One or more keys to read (see list below)
 <tty_device> Serial port (e.g., /dev/ttyACM0)

Keys:
 wifi_ssid WiFi network name
 wifi_password WiFi password
 ota_password Device-specific OTA password (derived from failsafe role secret)
 prod_api_key Device-specific production API encryption key
 thread_tlv Thread operational dataset TLVs (hex string)
 device_role Provisioned iotstack role (roles.conf name, e.g. bleproxy, mmwave)

Examples:
 read-nvs-secrets.sh --all /dev/ttyACM0
 read-nvs-secrets.sh ota_password /dev/ttyACM0
 read-nvs-secrets.sh wifi_ssid wifi_password /dev/ttyACM0
EOF
}

_read_nvs_partition_from_device() {
 local tty_device="$1"
 local nvs_bin="$2"

 if [[ ! -f "$PARTITION_TABLE" ]]; then
 err "Partition table not found: $PARTITION_TABLE
Compile firmware first (generates the partition table), or flash a device once."
 fi

 local nvs_offset nvs_size
 nvs_offset=$(awk -F',' '/^nvs[[:space:]]*,/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4}' "$PARTITION_TABLE" | head -1)
 [[ -z "$nvs_offset" ]] && err "Could not find NVS partition offset in: $PARTITION_TABLE"

 nvs_size=$(awk -F',' '/^nvs[[:space:]]*,/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $5); print $5}' "$PARTITION_TABLE" | head -1)
 [[ -z "$nvs_size" ]] && err "Could not find NVS partition size in: $PARTITION_TABLE"

 local esptool_chip="${IOTSTACK_ESPTOOL_CHIP:-}"
 if [[ -z "$esptool_chip" ]]; then
 # shellcheck source=scripts/esp-serial.sh
 source "${SCRIPT_DIR}/esp-serial.sh"
 esptool_chip=$(esp_detect_chip "$tty_device" 2>/dev/null) || esptool_chip=esp32c6
 fi

 info "Reading NVS partition from $tty_device (offset $nvs_offset, size $nvs_size, chip $esptool_chip)..."
 if ! python3 -m esptool --chip "$esptool_chip" --port "$tty_device" --baud 9600 \
 read-flash "$nvs_offset" "$nvs_size" "$nvs_bin" >/dev/null 2>&1; then
 err "Failed to read NVS partition from $tty_device (is the device connected and idle?)"
 fi
}

# -- Parse arguments ----------------------------------------------------------
print_all=0
keys=()
tty_device=""

while [[ $# -gt 0 ]]; do
 case "$1" in
 --all)
 print_all=1
 shift
 ;;
 -h|--help|help)
 _usage
 exit 0
 ;;
 /dev/*)
 tty_device="$1"
 shift
 ;;
 *)
 if [[ -z "$tty_device" && $# -eq 1 && "$1" =~ ^/dev/ ]]; then
 tty_device="$1"
 shift
 elif [[ "$1" =~ ^/dev/ ]]; then
 tty_device="$1"
 shift
 else
 keys+=("$1")
 shift
 fi
 ;;
 esac
done

if [[ -z "$tty_device" ]]; then
 _usage
 exit 1
fi

[[ ! -e "$tty_device" ]] && err "TTY device not found: $tty_device"

if [[ $print_all -eq 0 && ${#keys[@]} -eq 0 ]]; then
 _usage
 exit 1
fi

if [[ $print_all -eq 0 ]]; then
 local_key=""
 for local_key in "${keys[@]}"; do
 _is_valid_key "$local_key" || err "Unknown NVS key: $local_key (valid: ${VALID_KEYS[*]})"
 done
fi

nvs_bin=$(mktemp)
trap 'rm -f "$nvs_bin"' EXIT

_read_nvs_partition_from_device "$tty_device" "$nvs_bin"

decode_args=("$SCRIPT_DIR/read-nvs-secrets.py" "$nvs_bin")
if [[ $print_all -eq 1 ]]; then
 decode_args+=(--all)
else
 decode_args+=("${keys[@]}")
fi

"${decode_args[@]}"