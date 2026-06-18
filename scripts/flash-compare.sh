#!/bin/bash
# flash-compare.sh — Compare local build artifacts with firmware on a serial device
#
# Used by iotstack flash to skip erase/reflash when partition table and images
# already match the current build.
#
# Requires config.sh (and esp-serial.sh for baud/chip helpers).

[[ -n "${_FLASH_COMPARE_LOADED:-}" ]] && return 0
_FLASH_COMPARE_LOADED=1

_FLASH_COMPARE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/esp-serial.sh
source "${SCRIPTS_DIR:-$_FLASH_COMPARE_SCRIPT_DIR}/esp-serial.sh"

flash_file_md5() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  md5sum "$file" | awk '{print $1}'
}

flash_partition_table_csv_for_device() {
  # Prefer the compiled failsafe build table — matches partitions.bin on the device.
  # The generated ~/.iotstack artifact can lag (firmware-size estimate vs pass-2 layout).
  local failsafe_csv="${YAMLS_DIR}/.esphome/build/failsafe/partitions.csv"
  if [[ -f "$failsafe_csv" ]] && grep -qE '^production,' "$failsafe_csv" 2>/dev/null; then
    printf '%s\n' "$failsafe_csv"
    return 0
  fi
  [[ -n "${PARTITION_TABLE:-}" && -f "$PARTITION_TABLE" ]] || return 1
  printf '%s\n' "$PARTITION_TABLE"
}

flash_partition_offset_from_csv() {
  local csv_file="$1"
  local part_name="$2"
  [[ -f "$csv_file" ]] || return 1
  awk -F',' -v name="$part_name" '
    $1 ~ name {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4)
      print $4
      exit
    }
  ' "$csv_file"
}

flash_partition_offset() {
  # Echo hex offset for failsafe or production from the best available table.
  local part_name="$1"
  local csv offset
  csv=$(flash_partition_table_csv_for_device) || return 1
  offset=$(flash_partition_offset_from_csv "$csv" "$part_name")
  [[ -n "$offset" ]] || return 1
  printf '%s\n' "$offset"
}

flash_read_region_md5() {
  # Read flash region and return MD5 of the first file_size bytes.
  # Usage: flash_read_region_md5 <tty> <chip> <offset_hex> <file_size>
  local tty_device="$1"
  local esptool_chip="$2"
  local offset="$3"
  local file_size="$4"

  [[ -e "$tty_device" ]] || return 1
  [[ "$file_size" =~ ^[0-9]+$ ]] || return 1
  (( file_size > 0 )) || return 1

  local esptool_baud read_size verify_dir read_file exact_file md5
  esptool_baud=$(esp_esptool_baud_for_chip "$esptool_chip")
  read_size=$(( (file_size + 255) / 256 * 256 ))
  (( read_size < 0x10000 )) && read_size=0x10000

  verify_dir=$(mktemp -d)
  read_file="${verify_dir}/flash.read"
  exact_file="${verify_dir}/flash.exact"

  if ! python3 -m esptool --chip "$esptool_chip" --port "$tty_device" --baud "$esptool_baud" \
      --before default-reset read-flash "$offset" "$read_size" "$read_file" >/dev/null 2>&1; then
    rm -rf "$verify_dir"
    return 1
  fi

  dd if="$read_file" of="$exact_file" bs=1 count="$file_size" 2>/dev/null
  md5=$(md5sum "$exact_file" | awk '{print $1}')
  rm -rf "$verify_dir"
  printf '%s\n' "$md5"
}

flash_region_matches_device() {
  # Return 0 when the file's contents match flash at offset on the device.
  local tty_device="$1"
  local esptool_chip="$2"
  local offset="$3"
  local local_file="$4"

  [[ -f "$local_file" ]] || return 1

  local file_size local_md5 device_md5
  file_size=$(stat -c%s "$local_file" 2>/dev/null || stat -f%z "$local_file" 2>/dev/null || echo 0)
  (( file_size > 0 )) || return 1

  local_md5=$(flash_file_md5 "$local_file") || return 1
  device_md5=$(flash_read_region_md5 "$tty_device" "$esptool_chip" "$offset" "$file_size") || return 1

  [[ "$local_md5" == "$device_md5" ]]
}

flash_assess_failsafe_device() {
  # Compare local failsafe build with device flash. Sets assessment globals.
  # Usage: flash_assess_failsafe_device <tty> <chip> <build_dir> <failsafe_offset>
  # Sets: FLASH_ASSESS_PARTITION_MATCH, FLASH_ASSESS_FAILSAFE_MATCH,
  #       FLASH_ASSESS_NEED_ERASE, FLASH_ASSESS_SKIP_SERIAL
  local tty_device="$1"
  local esptool_chip="$2"
  local build_dir="$3"
  local failsafe_offset="$4"

  FLASH_ASSESS_PARTITION_MATCH=0
  FLASH_ASSESS_FAILSAFE_MATCH=0
  FLASH_ASSESS_NEED_ERASE=1
  FLASH_ASSESS_SKIP_SERIAL=0

  if [[ "${FLASH_ANYWAY:-0}" == "1" ]]; then
    debug "FLASH_ANYWAY=1 — forcing full serial flash"
    return 0
  fi

  local partition_file="${build_dir}/partitions.bin"
  local firmware_file="${build_dir}/firmware.bin"

  if flash_region_matches_device "$tty_device" "$esptool_chip" "0x8000" "$partition_file"; then
    FLASH_ASSESS_PARTITION_MATCH=1
  fi

  if flash_region_matches_device "$tty_device" "$esptool_chip" "$failsafe_offset" "$firmware_file"; then
    FLASH_ASSESS_FAILSAFE_MATCH=1
  fi

  if [[ "$FLASH_ASSESS_PARTITION_MATCH" -eq 1 && "$FLASH_ASSESS_FAILSAFE_MATCH" -eq 1 ]]; then
    FLASH_ASSESS_NEED_ERASE=0
    FLASH_ASSESS_SKIP_SERIAL=1
  else
    FLASH_ASSESS_NEED_ERASE=1
    FLASH_ASSESS_SKIP_SERIAL=0
  fi
}

flash_production_matches_device() {
  # Return 0 when production partition on device matches local firmware.bin.
  local tty_device="$1"
  local esptool_chip="$2"
  local build_dir="$3"
  local production_offset="${4:-}"

  [[ "${FLASH_ANYWAY:-0}" == "1" ]] && return 1

  if [[ -z "$production_offset" ]]; then
    production_offset=$(flash_partition_offset production) || return 1
  fi

  local firmware_file="${build_dir}/firmware.bin"
  flash_region_matches_device "$tty_device" "$esptool_chip" "$production_offset" "$firmware_file"
}