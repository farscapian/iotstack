#!/bin/bash
# flash-compare.sh -- Compare local build artifacts with firmware on a serial device
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
  # Prefer the compiled bootstrap build table -- matches partitions.bin on the device.
  # The generated ~/.iotstack artifact can lag (firmware-size estimate vs pass-2 layout).
  local bootstrap_role build_name bootstrap_csv
  bootstrap_role=$(iotstack_bootstrap_role)
  build_name="$bootstrap_role"
  bootstrap_csv="${YAMLS_DIR}/.esphome/build/${build_name}/partitions.csv"
  if [[ -f "$bootstrap_csv" ]] && grep -qE '^production,' "$bootstrap_csv" 2>/dev/null; then
    printf '%s\n' "$bootstrap_csv"
    return 0
  fi
  [[ -n "${PARTITION_TABLE:-}" && -f "$PARTITION_TABLE" ]] || return 1
  printf '%s\n' "$PARTITION_TABLE"
}

flash_partition_offset_from_csv() {
  local csv_file="$1"
  local part_name="$2"
  [[ -f "$csv_file" ]] || return 1
  # Match partition name exactly on $1 -- substring match hits comment lines
  # that mention "bootstrap" / "production" in prose above the data rows.
  awk -F',' -v name="$part_name" '
    {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      if ($1 != name) next
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4)
      print $4
      exit
    }
  ' "$csv_file"
}

flash_partition_offset() {
  # Echo hex offset for bootstrap or production from the best available table.
  local part_name="$1"
  local csv offset
  if [[ "$part_name" == "bootstrap" ]]; then
    part_name=$(iotstack_bootstrap_role)
  fi
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

flash_mdns_config_hash_for_hostname() {
  # ESPHome config_hash from mDNS TXT (8-char hex). Same parser as iotstack.sh.
  local hostname="$1"
  local mdns_service="${2:-_esphomelib._tcp}"
  local line current_hostname="" hash=""
  while IFS= read -r line; do
    if [[ $line =~ hostname\ =\ \[([^\]]+)\] ]]; then
      current_hostname="${BASH_REMATCH[1]%.local}"
    fi
    if [[ $line =~ txt\ = ]] && [[ "$current_hostname" == "$hostname" ]]; then
      [[ $line =~ config_hash=([^\"]*) ]] && hash="${BASH_REMATCH[1]}"
      if [[ -n "$hash" ]]; then
        echo "$hash"
        return 0
      fi
    fi
  done < <(avahi-browse -t -r "$mdns_service" 2>/dev/null)
  return 1
}

flash_build_image_hash_from_build_dir() {
  # 8-char hex image hash from ESPHome build_info.json (ESPHome field: config_hash).
  local build_dir="$1"
  local build_info="${build_dir}/build_info.json"
  [[ -f "$build_info" ]] || return 1
  python3 -c "import json,sys; print(format(json.load(open(sys.argv[1]))['config_hash'], '08x'))" "$build_info"
}

flash_bootstrap_matches_build_via_mdns() {
  # Return 0 when bootstrap-<mac> advertises the same config_hash as the local build.
  local device_mac="$1"
  local build_dir="$2"
  local bootstrap_hostname build_hash runtime_hash attempt

  [[ -n "$device_mac" ]] || return 1
  bootstrap_hostname="$(iotstack_bootstrap_hostname "$device_mac")"
  build_hash=$(flash_build_image_hash_from_build_dir "$build_dir" 2>/dev/null) || return 1
  [[ -n "$build_hash" ]] || return 1

  for attempt in 1 2 3; do
    runtime_hash=$(flash_mdns_config_hash_for_hostname "$bootstrap_hostname" "$(iotstack_bootstrap_mdns_service)" 2>/dev/null) \
      || runtime_hash=""
    if [[ -n "$runtime_hash" && "$runtime_hash" == "$build_hash" ]]; then
      return 0
    fi
    (( attempt < 3 )) && sleep 1
  done
  return 1
}

flash_assess_bootstrap_device() {
  # Compare local bootstrap build with device flash. Sets assessment globals.
  # Usage: flash_assess_bootstrap_device <tty> <chip> <build_dir> <bootstrap_offset> [device_mac]
  # Sets: FLASH_ASSESS_PARTITION_MATCH, FLASH_ASSESS_BOOTSTRAP_MATCH,
  #       FLASH_ASSESS_NEED_ERASE, FLASH_ASSESS_SKIP_SERIAL
  local tty_device="$1"
  local esptool_chip="$2"
  local build_dir="$3"
  local bootstrap_offset="$4"
  local device_mac="${5:-}"

  FLASH_ASSESS_PARTITION_MATCH=0
  FLASH_ASSESS_BOOTSTRAP_MATCH=0
  FLASH_ASSESS_NEED_ERASE=1
  FLASH_ASSESS_SKIP_SERIAL=0
  FLASH_ASSESS_VIA_MDNS=0

  if [[ "${FLASH_ERASE:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -n "$device_mac" ]] && flash_bootstrap_matches_build_via_mdns "$device_mac" "$build_dir"; then
    FLASH_ASSESS_PARTITION_MATCH=1
    FLASH_ASSESS_BOOTSTRAP_MATCH=1
    FLASH_ASSESS_NEED_ERASE=0
    FLASH_ASSESS_SKIP_SERIAL=1
    FLASH_ASSESS_VIA_MDNS=1
    return 0
  fi

  local partition_file="${build_dir}/partitions.bin"
  local firmware_file="${build_dir}/firmware.bin"

  if flash_region_matches_device "$tty_device" "$esptool_chip" "0x8000" "$partition_file"; then
    FLASH_ASSESS_PARTITION_MATCH=1
  fi

  if flash_region_matches_device "$tty_device" "$esptool_chip" "$bootstrap_offset" "$firmware_file"; then
    FLASH_ASSESS_BOOTSTRAP_MATCH=1
  fi

  if [[ "$FLASH_ASSESS_PARTITION_MATCH" -eq 1 && "$FLASH_ASSESS_BOOTSTRAP_MATCH" -eq 1 ]]; then
    FLASH_ASSESS_NEED_ERASE=0
    FLASH_ASSESS_SKIP_SERIAL=1
  else
    FLASH_ASSESS_NEED_ERASE=1
    FLASH_ASSESS_SKIP_SERIAL=0
  fi
}