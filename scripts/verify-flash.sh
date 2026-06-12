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
DEVICE_NAME="${2:-}"

[[ -z "$TTY_DEVICE" ]] && err "Usage: $0 <tty_device> <device_name>"
[[ -z "$DEVICE_NAME" ]] && err "Usage: $0 <tty_device> <device_name>"
[[ ! -e "$TTY_DEVICE" ]] && err "TTY device not found: $TTY_DEVICE"

# Build directory
BUILD_DIR="${PROJECT_DIR}/yamls/.esphome/build/${DEVICE_NAME}/.pioenvs/${DEVICE_NAME}"
[[ ! -d "$BUILD_DIR" ]] && err "Build directory not found: $BUILD_DIR"

info "Verifying flash checksums for: $DEVICE_NAME"
echo ""

# Temporary directory for verification files
VERIFY_DIR=$(mktemp -d)
trap "rm -rf $VERIFY_DIR" EXIT

declare -A checksums
declare -a offsets
declare -a files
declare -a sizes

# Define what to verify (offset, file, size in hex)
offsets=(0x0 0x8000 0x30000)
files=(bootloader.bin partitions.bin firmware.bin)
sizes=(0x5800 0x1000 0xc6000)  # bootloader: ~22KB, partitions: 4KB, firmware: ~792KB

# Verify each region
failed=0
for i in {0..2}; do
  offset="${offsets[$i]}"
  file="${files[$i]}"
  size="${sizes[$i]}"
  source_file="${BUILD_DIR}/${file}"

  if [[ ! -f "$source_file" ]]; then
    warn "Skipping $file (not found)"
    continue
  fi

  # Get checksum of original file
  original_md5=$(md5sum "$source_file" | awk '{print $1}')

  # Read back from device
  read_file="${VERIFY_DIR}/${file}.read"
  info "Verifying $file at offset $offset..."

  if esptool --chip esp32c6 --port "$TTY_DEVICE" --baud 57600 \
    read_flash "$offset" "$size" "$read_file" >/dev/null 2>&1; then

    # Get checksum of read data (truncate to same size as original)
    read_size=$(stat -f%z "$read_file" 2>/dev/null || stat -c%s "$read_file" 2>/dev/null || echo 0)

    if [[ $read_size -ge $(printf "%d" "$size") ]]; then
      # Truncate to expected size
      dd if="$read_file" of="${read_file}.truncated" bs=1 count=$(printf "%d" "$size") 2>/dev/null
      read_md5=$(md5sum "${read_file}.truncated" | awk '{print $1}')
    else
      read_md5=$(md5sum "$read_file" | awk '{print $1}')
    fi

    if [[ "$original_md5" == "$read_md5" ]]; then
      ok "$file: checksum matches ✓"
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
  exit 0
else
  err "$failed checksum(s) failed verification"
  exit 1
fi
