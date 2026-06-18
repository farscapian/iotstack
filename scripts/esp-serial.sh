#!/bin/bash
# esp-serial.sh -- Detect Espressif chips on USB serial ports
#
# Requires config.sh to be sourced first.

[[ -n "${_ESP_SERIAL_LOADED:-}" ]] && return 0
_ESP_SERIAL_LOADED=1

# Cached mapping: esp32c6=/dev/ttyACM0 (written by esp_serial_scan)
export ESP_SERIAL_MAP="${ESP_SERIAL_MAP:-${ARTIFACTS_DIR}/serial-port-map.env}"

esp_serial_ports() {
  local dev
  for dev in /dev/ttyACM* /dev/ttyUSB*; do
    [[ -e "$dev" ]] && printf '%s\n' "$dev"
  done
}

esp_esptool_baud_for_chip() {
  # Flash/probe baud rate per chip family.
  # ESP32-S3 DevKitC-1 UART bridges often fail at 9600 (no serial data); C6 XIAO
  # needs 9600 for reliable large transfers. Pick per variant.
  local chip="${1:-}"
  case "$chip" in
    esp32s3|esp32s2) printf '%s\n' 115200 ;;
    *) printf '%s\n' 9600 ;;
  esac
}

esp_mac_from_esptool_output() {
  # Last 6 hex chars of chip MAC from esptool chip-id / write-flash output.
  # S3 reports "MAC:"; classic/C6 output includes "BASE MAC:".
  local out="$1"
  local mac
  mac=$(echo "$out" | grep -E '(BASE )?MAC:' | tail -1 | awk '{print $NF}' | sed 's/://g' | tr -d '[:space:]')
  [[ -n "$mac" ]] || return 1
  printf '%s\n' "${mac: -6}"
}

esp_esptool_chip_id() {
  # Run esptool chip-id with auto-reset. Tries 115200 then 9600 for detection.
  local port="$1"
  local baud out

  [[ -e "$port" ]] || return 1

  for baud in 115200 9600 57600; do
    if out=$(python3 -m esptool --port "$port" --baud "$baud" --before default-reset chip-id 2>/dev/null); then
      printf '%s' "$out"
      return 0
    fi
  done
  return 1
}

esp_detect_chip() {
  # Echo esphome/esp-idf variant slug: esp32c6, esp32s3, esp32, esp32c3, ...
  local port="$1"
  local out variant

  [[ -e "$port" ]] || return 1

  if ! out=$(esp_esptool_chip_id "$port"); then
    return 1
  fi

  if echo "$out" | grep -qi 'ESP32-C6'; then
    variant=esp32c6
  elif echo "$out" | grep -qi 'ESP32-S3'; then
    variant=esp32s3
  elif echo "$out" | grep -qi 'ESP32-C3'; then
    variant=esp32c3
  elif echo "$out" | grep -qi 'ESP32-H2'; then
    variant=esp32h2
  elif echo "$out" | grep -qi 'ESP32-S2'; then
    variant=esp32s2
  elif echo "$out" | grep -qi 'ESP32'; then
    variant=esp32
  else
    return 1
  fi

  printf '%s\n' "$variant"
}

esp_serial_load_map() {
  if [[ -f "$ESP_SERIAL_MAP" ]]; then
    # shellcheck disable=SC1090
    source "$ESP_SERIAL_MAP"
  fi
}

esp_tty_for_variant() {
  local want_variant="$1"
  local port variant

  esp_serial_load_map

  # Explicit per-variant override from environment / .env
  case "$want_variant" in
    esp32c6) [[ -n "${IOTSTACK_TEST_TTY_C6:-}" ]] && { printf '%s\n' "$IOTSTACK_TEST_TTY_C6"; return 0; } ;;
    esp32s3) [[ -n "${IOTSTACK_TEST_TTY_S3:-}" ]] && { printf '%s\n' "$IOTSTACK_TEST_TTY_S3"; return 0; } ;;
  esac

  # In-memory / file cache from last scan
  variant=$(echo "$want_variant" | tr '[:upper:]' '[:lower:]')
  local cached
  cached=$(grep -m1 "^${variant}=" "$ESP_SERIAL_MAP" 2>/dev/null | cut -d= -f2-)
  if [[ -n "$cached" && -e "$cached" ]]; then
    printf '%s\n' "$cached"
    return 0
  fi

  # Live scan
  while IFS= read -r port; do
    [[ -z "$port" ]] && continue
    variant=$(esp_detect_chip "$port" 2>/dev/null) || continue
    if [[ "$variant" == "$want_variant" ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  done < <(esp_serial_ports)

  return 1
}

esp_serial_scan() {
  # Probe all ports and write ${variant}=${port} lines to ESP_SERIAL_MAP.
  local port variant
  local -a found_variants=()
  local tmp
  tmp=$(mktemp)

  : > "$tmp"
  while IFS= read -r port; do
    [[ -z "$port" ]] && continue
    variant=$(esp_detect_chip "$port" 2>/dev/null) || continue
    # First match wins per variant (stable sort from glob order)
    if ! grep -q "^${variant}=" "$tmp" 2>/dev/null; then
      printf '%s=%s\n' "$variant" "$port" >> "$tmp"
      found_variants+=("${variant}:${port}")
    fi
  done < <(esp_serial_ports)

  mv "$tmp" "$ESP_SERIAL_MAP"
  printf '%s\n' "${found_variants[@]}"
}

esp_serial_require_variant() {
  local want_variant="$1"
  local tty
  tty=$(esp_tty_for_variant "$want_variant") || return 1
  printf '%s\n' "$tty"
}

esp_mac_suffix_from_port() {
  # Echo last 6 hex chars of chip MAC for a serial port.
  local port="$1"
  local out

  [[ -e "$port" ]] || return 1

  if ! out=$(esp_esptool_chip_id "$port"); then
    return 1
  fi

  esp_mac_from_esptool_output "$out"
}

esp_tty_for_mac_suffix() {
  # Find USB serial port whose chip MAC ends with the given 6-char suffix.
  local want_mac="$1"
  local port got_mac

  want_mac=$(echo "$want_mac" | tr '[:upper:]' '[:lower:]')
  [[ "$want_mac" =~ ^[0-9a-f]{6}$ ]] || return 1

  while IFS= read -r port; do
    [[ -z "$port" ]] && continue
    got_mac=$(esp_mac_suffix_from_port "$port" 2>/dev/null) || continue
    if [[ "$(echo "$got_mac" | tr '[:upper:]' '[:lower:]')" == "$want_mac" ]]; then
      printf '%s\n' "$port"
      return 0
    fi
  done < <(esp_serial_ports)

  return 1
}

esp_nvs_device_role_from_port() {
  # Read iotstack NVS device_role (roles.conf name) from a USB serial port.
  local port="$1"
  local scripts_dir role

  [[ -e "$port" ]] || return 1
  scripts_dir="${SCRIPTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  role=$("${scripts_dir}/read-nvs-secrets.sh" device_role "$port" 2>/dev/null) || return 1
  role=$(echo "$role" | tr -d '[:space:]')
  [[ -n "$role" ]] || return 1
  printf '%s\n' "$role"
}

esp_tty_for_role() {
  # Find USB port whose NVS device_role matches (provisioned devices only).
  local want_role="$1"
  local port got_role
  local -a matches=()

  want_role=$(echo "$want_role" | tr '[:upper:]' '[:lower:]')
  [[ -n "$want_role" ]] || return 1

  while IFS= read -r port; do
    [[ -z "$port" ]] && continue
    got_role=$(esp_nvs_device_role_from_port "$port" 2>/dev/null) || continue
    got_role=$(echo "$got_role" | tr '[:upper:]' '[:lower:]')
    if [[ "$got_role" == "$want_role" ]]; then
      matches+=("$port")
    fi
  done < <(esp_serial_ports)

  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s\n' "${matches[0]}"
    return 0
  fi
  return 1
}