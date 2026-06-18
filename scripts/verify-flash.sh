#!/bin/bash
# verify-flash.sh
# Verify that firmware was correctly written to device by comparing checksums
#
# Usage:
#   ./scripts/verify-flash.sh /dev/ttyACM0 recovery
#   ./scripts/verify-flash.sh /dev/ttyACM0 bleproxy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source centralized configuration
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/config.sh"

# Colors
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
RST='\033[0m'

err()  { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }
ok()   { echo -e "${GRN}[OK]${RST} $*"; }
warn() { echo -e "${YLW}[WARN]${RST} $*"; }
info() { echo -e "${YLW}[INFO]${RST} $*"; }

# Arguments
TTY_DEVICE="${1:-}"
DEVICE_NAME="${2:-}"

[[ -z "$TTY_DEVICE" ]] && err "Usage: $0 <tty_device> <device_name>"
[[ -z "$DEVICE_NAME" ]] && err "Usage: $0 <tty_device> <device_name>"
[[ ! -e "$TTY_DEVICE" ]] && err "TTY device not found: $TTY_DEVICE"

# Chip: ESP_VERIFY_CHIP env, or auto-detect from serial port
ESPTOOL_CHIP="${ESP_VERIFY_CHIP:-}"
if [[ -z "$ESPTOOL_CHIP" ]]; then
  # shellcheck source=scripts/esp-serial.sh
  source "${SCRIPT_DIR}/esp-serial.sh"
  ESPTOOL_CHIP=$(esp_detect_chip "$TTY_DEVICE" 2>/dev/null) || true
fi
[[ -z "$ESPTOOL_CHIP" ]] && ESPTOOL_CHIP=esp32c6
info "Using esptool chip: $ESPTOOL_CHIP (port: $TTY_DEVICE)"

# Build directory
BUILD_DIR="${PROJECT_DIR}/yamls/.esphome/build/${DEVICE_NAME}/.pioenvs/${DEVICE_NAME}"
[[ ! -d "$BUILD_DIR" ]] && err "Build directory not found: $BUILD_DIR"

info "Verifying flash checksums for: $DEVICE_NAME"
echo ""

# Temporary directory for verification files
VERIFY_DIR=$(mktemp -d)
trap 'rm -rf "$VERIFY_DIR"' EXIT

# Extract failsafe (ota_0) firmware offset from generated partition table
failsafe_offset=$(awk -F',' '/^failsafe[[:space:]]*,/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4}' "$PARTITION_TABLE" | head -1)
[[ -z "$failsafe_offset" ]] && err "Could not find failsafe partition offset in: $PARTITION_TABLE"

declare -a offsets
declare -a files

# Define what to verify (offset, file, actual file size - no padding)
# Note: partitions.bin is dynamically generated and already verified by esptool,
# so we only verify bootloader and firmware
offsets=(0x0 "$failsafe_offset")
files=(bootloader.bin firmware.bin)

# Verify each region
failed=0
for i in {0..1}; do
  offset="${offsets[$i]}"
  file="${files[$i]}"
  source_file="${BUILD_DIR}/${file}"

  if [[ ! -f "$source_file" ]]; then
    warn "Skipping $file (not found)"
    continue
  fi

  # Get actual file size and checksum
  file_size=$(stat -f%z "$source_file" 2>/dev/null || stat -c%s "$source_file" 2>/dev/null || echo 0)
  original_md5=$(md5sum "$source_file" | awk '{print $1}')

  # Read back from device (read more to account for padding, then truncate)
  read_file="${VERIFY_DIR}/${file}.read"
  # Read with padding (round up to 256-byte boundary for safety)
  read_size=$(( (file_size + 255) / 256 * 256 ))
  read_size=$(( read_size > 0x10000 ? read_size : 0x10000 ))  # At least 64KB to be safe

  info "Verifying $file at offset $offset (size: $file_size bytes)..."

  local esptool_baud
  esptool_baud=$(esp_esptool_baud_for_chip "$ESPTOOL_CHIP")
  if python3 -m esptool --chip "$ESPTOOL_CHIP" --port "$TTY_DEVICE" --baud "$esptool_baud" --before default-reset \
    read-flash "$offset" "$read_size" "$read_file" >/dev/null 2>&1; then

    # Truncate read file to exact original size for comparison
    dd if="$read_file" of="${read_file}.exact" bs=1 count="$file_size" 2>/dev/null
    read_md5=$(md5sum "${read_file}.exact" | awk '{print $1}')

    if [[ "$original_md5" == "$read_md5" ]]; then
      ok "$file: checksum matches"
    else
      echo -e "${RED}[FAIL]${RST} $file: checksum mismatch"
      echo "  Original: $original_md5"
      echo "  Read:     $read_md5"
      failed=$((failed + 1))
    fi
  else
    echo -e "${RED}[FAIL]${RST} $file: could not read from device"
    failed=$((failed + 1))
  fi
done

echo ""
if [[ $failed -eq 0 ]]; then
  ok "All flash checksums verified successfully!"
else
  err "$failed checksum(s) failed verification"
fi
