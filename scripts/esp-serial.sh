#!/bin/bash
# esp-serial.sh -- Detect Espressif chips on USB serial ports
#
# Requires config.sh to be sourced first.

[[ -n "${_ESP_SERIAL_LOADED:-}" ]] && return 0
_ESP_SERIAL_LOADED=1

# Cached mapping: esp32c6=/dev/ttyACM0 (written by esp_serial_scan)
export ESP_SERIAL_MAP="${ESP_SERIAL_MAP:-${ARTIFACTS_DIR}/serial-port-map.env}"

_esp_serial_log() {
  local level="$1"
  shift
  case "$level" in
    info)
      if declare -F info &>/dev/null; then info "$@"; else echo "[INFO] $*" >&2; fi
      ;;
    warn)
      if declare -F warn &>/dev/null; then warn "$@"; else echo "[WARN] $*" >&2; fi
      ;;
    *)
      echo "[$level] $*" >&2
      ;;
  esac
}

esp_serial_ports() {
  local dev
  for dev in /dev/ttyACM* /dev/ttyUSB*; do
    [[ -e "$dev" ]] && printf '%s\n' "$dev"
  done
}

esp_serial_process_cmdline() {
  local pid="$1"
  ps -p "$pid" -o args= 2>/dev/null || true
}

esp_serial_pid_in_tree() {
  # True when check_pid is root_pid or a descendant.
  local root_pid="$1"
  local check_pid="$2"
  local child

  [[ -n "$root_pid" && -n "$check_pid" ]] || return 1
  [[ "$root_pid" -eq "$check_pid" ]] && return 0
  while IFS= read -r child; do
    [[ -z "$child" ]] && continue
    esp_serial_pid_in_tree "$child" "$check_pid" && return 0
  done < <(pgrep -P "$root_pid" 2>/dev/null || true)
  return 1
}

esp_serial_kill_process_tree() {
  local pid="$1"
  local child

  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0
  while IFS= read -r child; do
    [[ -z "$child" ]] && continue
    esp_serial_kill_process_tree "$child"
  done < <(pgrep -P "$pid" 2>/dev/null || true)
  kill -TERM "$pid" 2>/dev/null || true
}

esp_serial_is_iotstack_serial_holder() {
  local cmdline="$1"
  [[ "$cmdline" == *"serial-logs.py"* ]] \
    || { [[ "$cmdline" == *"log-stamp.py"* ]] && [[ "$cmdline" == *"serial:"* ]]; }
}

esp_serial_is_iotstack_flash_on_tty() {
  local cmdline="$1"
  local tty="$2"
  [[ "$cmdline" == *"iotstack"* && "$cmdline" == *" flash "* && "$cmdline" == *"$tty"* ]]
}

esp_serial_tty_holder_pids() {
  # PIDs with the TTY open (lsof), one per line.
  local tty="$1"
  local line pid

  [[ -n "$tty" && -e "$tty" ]] || return 0
  command -v lsof &>/dev/null || return 0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(awk '{print $2}' <<<"$line")
    [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] && printf '%s\n' "$pid"
  done < <(lsof -t "$tty" 2>/dev/null | sort -u || true)
}

esp_serial_iotstack_serial_pids_on_tty() {
  # serial-logs.py / serial log-stamp.py targeting tty, even if lsof missed them.
  local tty="$1"
  local pid cmdline

  [[ -n "$tty" ]] || return 0
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    cmdline=$(esp_serial_process_cmdline "$pid")
    [[ -z "$cmdline" ]] && continue
    if esp_serial_is_iotstack_serial_holder "$cmdline" && [[ "$cmdline" == *"$tty"* ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(pgrep -f 'serial-logs\.py|log-stamp\.py' 2>/dev/null || true)
}

esp_serial_stale_iotstack_flash_pids_on_tty() {
  local tty="$1"
  local pid cmdline

  [[ -n "$tty" ]] || return 0
  while IFS= read -r pid; do
    [[ -z "$pid" || "$pid" -eq "$$" ]] && continue
    cmdline=$(esp_serial_process_cmdline "$pid")
    esp_serial_is_iotstack_flash_on_tty "$cmdline" "$tty" || continue
    printf '%s\n' "$pid"
  done < <(pgrep -f 'iotstack.* flash ' 2>/dev/null || true)
}

esp_serial_clear_tty_interference() {
  # Stop iotstack-owned processes that block USB serial (stale logs, captures, stopped flash).
  # Usage: esp_serial_clear_tty_interference <tty> [preserve_root_pid]
  local tty="$1"
  local preserve_root_pid="${2:-${IOTSTACK_SERIAL_LOG_PID:-}}"
  local -a kill_pids=()
  local pid cmdline state

  [[ -n "$tty" && -e "$tty" ]] || return 0

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    [[ -n "$preserve_root_pid" ]] && esp_serial_pid_in_tree "$preserve_root_pid" "$pid" && continue
    kill_pids+=("$pid")
  done < <(esp_serial_iotstack_serial_pids_on_tty "$tty")

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    [[ -n "$preserve_root_pid" ]] && esp_serial_pid_in_tree "$preserve_root_pid" "$pid" && continue
    kill_pids+=("$pid")
  done < <(esp_serial_stale_iotstack_flash_pids_on_tty "$tty")

  # serial-logs.py may be gone while log-stamp.py still runs in the pipeline.
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    [[ -n "$preserve_root_pid" ]] && esp_serial_pid_in_tree "$preserve_root_pid" "$pid" && continue
    cmdline=$(esp_serial_process_cmdline "$pid")
    esp_serial_is_iotstack_serial_holder "$cmdline" || continue
    kill_pids+=("$pid")
  done < <(esp_serial_tty_holder_pids "$tty")

  if [[ ${#kill_pids[@]} -eq 0 ]]; then
    return 0
  fi

  # Deduplicate PIDs.
  local -A seen=()
  local -a unique_pids=()
  for pid in "${kill_pids[@]}"; do
    [[ -n "${seen[$pid]:-}" ]] && continue
    seen[$pid]=1
    unique_pids+=("$pid")
  done

  for pid in "${unique_pids[@]}"; do
    cmdline=$(esp_serial_process_cmdline "$pid")
    state=$(ps -p "$pid" -o stat= 2>/dev/null | tr -d ' ' || true)
    if [[ "$state" == *T* ]]; then
      kill -CONT "$pid" 2>/dev/null || true
    fi
    if esp_serial_is_iotstack_serial_holder "$cmdline"; then
      _esp_serial_log info "Stopping stale iotstack serial capture on $tty (pid $pid)..."
    elif esp_serial_is_iotstack_flash_on_tty "$cmdline" "$tty"; then
      _esp_serial_log warn "Stopping stale iotstack flash on $tty (pid $pid)..."
    fi
    esp_serial_kill_process_tree "$pid"
  done

  sleep 1
}

esp_serial_wait_tty_free() {
  # Wait until no process holds the TTY (after stopping serial capture).
  local tty="$1"
  local timeout_s="${2:-5}"
  local elapsed=0

  [[ -n "$tty" && -e "$tty" ]] || return 0
  command -v lsof &>/dev/null || return 0

  while (( elapsed < timeout_s )); do
    [[ -z "$(esp_serial_tty_holder_pids "$tty")" ]] && return 0
    sleep 0.2
    elapsed=$((elapsed + 1))
  done
  return 1
}

esp_serial_tty_blocked_processes() {
  # Non-iotstack processes still holding the TTY after cleanup (for error messages).
  local tty="$1"
  local line pid cmdline

  [[ -n "$tty" && -e "$tty" ]] || return 0
  command -v lsof &>/dev/null || return 0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pid=$(awk '{print $2}' <<<"$line")
    cmdline=$(esp_serial_process_cmdline "$pid")
    esp_serial_is_iotstack_serial_holder "$cmdline" && continue
    esp_serial_is_iotstack_flash_on_tty "$cmdline" "$tty" && continue
    printf '%s\n' "$line"
  done < <(lsof "$tty" 2>/dev/null | tail -n +2 || true)
}

esp_esptool_baud_for_chip() {
  # Flash/probe baud rate per chip family.
  # ESP32-C6 (XIAO): 9600 only -- higher rates corrupt large firmware transfers.
  # ESP32-S3/S2 (USB CDC / DevKit): 460800 for speed; 9600 often yields no serial data.
  # Override for experiments: IOTSTACK_ESPTOOL_BAUD=<rate>
  local chip="${1:-}"
  if [[ -n "${IOTSTACK_ESPTOOL_BAUD:-}" ]]; then
    printf '%s\n' "$IOTSTACK_ESPTOOL_BAUD"
    return 0
  fi
  case "$chip" in
    esp32s3|esp32s2) printf '%s\n' 460800 ;;
    *) printf '%s\n' 9600 ;;
  esac
}

esp_esptool_hard_reset() {
  # Reboot into firmware after a no-reset flash (NVS write leaves chip in bootloader stub).
  # default-reset enters ROM download mode from any state; hard-reset boots firmware.
  local port="$1"
  local chip="${2:-esp32c6}"
  local baud attempt
  baud=$(esp_esptool_baud_for_chip "$chip")
  [[ -e "$port" ]] || return 1
  for attempt in 1 2 3; do
    if python3 -m esptool --chip "$chip" --port "$port" --baud "$baud" \
        --before default-reset --after hard-reset chip-id >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

esp_boot_app0_bin_for_build() {
  # boot_app0.bin at 0xd000 is required for OTA partition boot selection (Arduino layout).
  local build_dir="$1"
  local candidate

  [[ -n "$build_dir" ]] || return 1
  for candidate in \
    "${build_dir}/boot_app0.bin" \
    "${HOME}/.platformio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"; do
    [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
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

esp_mac_suffix_resolve() {
  # MAC suffix from esptool capture (write-flash) or chip-id probe on the port.
  local port="$1"
  local esptool_capture="${2:-}"
  local mac=""

  if [[ -n "$esptool_capture" ]]; then
    mac=$(esp_mac_from_esptool_output "$esptool_capture" 2>/dev/null) || mac=""
    if [[ -n "$mac" && "$mac" =~ ^[0-9a-f]{6}$ ]]; then
      printf '%s\n' "$mac"
      return 0
    fi
  fi
  esp_mac_suffix_from_port "$port"
}

esp_esptool_chip_id() {
  # Run esptool chip-id with auto-reset. Tries 115200 then 9600 for detection.
  local port="$1"
  local baud out resume_capture=0 rc=1

  [[ -e "$port" ]] || return 1

  if [[ -n "${IOTSTACK_FLASH_SERIAL_TTY:-}" && "$IOTSTACK_FLASH_SERIAL_TTY" == "$port" \
      && -n "${IOTSTACK_SERIAL_LOG_PID:-}" ]] \
      && declare -F create_log_serial_capture_pause &>/dev/null; then
    create_log_serial_capture_pause
    resume_capture=1
    esp_serial_wait_tty_free "$port" 5 || true
  else
    esp_serial_clear_tty_interference "$port"
    esp_serial_wait_tty_free "$port" 3 || true
  fi

  for baud in 115200 9600 57600; do
    if out=$(python3 -m esptool --port "$port" --baud "$baud" --before default-reset chip-id 2>/dev/null); then
      rc=0
      break
    fi
  done

  if [[ $resume_capture -eq 1 ]] && declare -F create_log_serial_capture_resume &>/dev/null; then
    create_log_serial_capture_resume
  fi

  if [[ $rc -eq 0 ]]; then
    printf '%s' "$out"
    return 0
  fi
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