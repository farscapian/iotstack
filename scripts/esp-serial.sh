#!/bin/bash
# esp-serial.sh -- Detect Espressif chips on USB serial ports
#
# Requires config.sh to be sourced first.

[[ -n "${_ESP_SERIAL_LOADED:-}" ]] && return 0
_ESP_SERIAL_LOADED=1

# Cached mapping: esp32c6=/dev/ttyACM0 (written by esp_serial_scan)
export ESP_SERIAL_MAP="${ESP_SERIAL_MAP:-${ARTIFACTS_DIR}/serial-port-map.env}"
export IOTSTACK_LAST_ESPTOOL_ERROR=""

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

esp_tty_is_native_jtag() {
  # True when tty is an ESP32-S3/S2 native USB JTAG/CDC port (Espressif VID 303a).
  # Uses udevadm; returns 1 if udevadm is unavailable or VID is not 303a.
  local tty="$1"
  local vid
  [[ -e "$tty" ]] || return 1
  vid=$(udevadm info --query=property --name="$tty" 2>/dev/null \
        | grep '^ID_VENDOR_ID=' | cut -d= -f2)
  [[ "$vid" == "303a" ]]
}

esp_uart0_companion_port() {
  # Given a flash TTY that is a native USB JTAG port (VID=303a), find the
  # companion USB-UART chip port on the same USB parent hub (the separate
  # UART0/GPIO43 interface present on DevKitC-1 style boards).
  #
  # Returns the companion TTY on stdout and exits 0 if found.
  # Returns nothing and exits 1 if:
  #   - tty is not native JTAG (caller should use tty directly)
  #   - no companion port found (single-port board)
  local tty="$1"
  esp_tty_is_native_jtag "$tty" || return 1

  # USB sysfs path for the JTAG device, e.g.
  #   /devices/pci.../usb1/1-2/1-2.3/1-2.3:1.0/tty/ttyACM1
  local jtag_syspath
  jtag_syspath=$(udevadm info --query=property --name="$tty" 2>/dev/null \
                 | grep '^DEVPATH=' | cut -d= -f2)
  [[ -n "$jtag_syspath" ]] || return 1

  # Walk up two levels: interface -> USB device -> USB hub (parent)
  local jtag_usb_dev="${jtag_syspath%/*:*}"   # strip :interface suffix
  local usb_hub="${jtag_usb_dev%/*}"           # parent hub path

  local dev devpath vid
  for dev in /dev/ttyACM* /dev/ttyUSB*; do
    [[ -e "$dev" && "$dev" != "$tty" ]] || continue
    devpath=$(udevadm info --query=property --name="$dev" 2>/dev/null \
              | grep '^DEVPATH=' | cut -d= -f2)
    [[ -n "$devpath" ]] || continue
    # Must share the same USB hub parent
    [[ "${devpath%/*:*}" == "$usb_hub"* ]] || continue
    # Must NOT be another native JTAG port
    vid=$(udevadm info --query=property --name="$dev" 2>/dev/null \
          | grep '^ID_VENDOR_ID=' | cut -d= -f2)
    [[ "$vid" == "303a" ]] && continue
    printf '%s\n' "$dev"
    return 0
  done
  return 1
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

esp_serial_is_iotstack_flash_invocation() {
  local cmdline="$1"
  # Wrapper shells embed iotstack commands in -c strings; only match real invocations.
  if [[ "$cmdline" =~ ^(/bin/)?bash[[:space:]] ]] && [[ "$cmdline" == *" -c "* ]]; then
    return 1
  fi
  [[ "$cmdline" == *"/iotstack.sh"* || "$cmdline" == *"/iotstack "* \
    || "$cmdline" =~ (^|[[:space:]])iotstack[[:space:]] ]]
}

esp_serial_is_iotstack_flash_on_tty() {
  local cmdline="$1"
  local tty="$2"
  esp_serial_is_iotstack_flash_invocation "$cmdline" || return 1
  [[ "$cmdline" == *" flash "* && "$cmdline" == *"$tty"* ]]
}

esp_serial_pid_in_current_session() {
  # True when pid is this shell, the flash session root, or any ancestor/descendant
  # of either (command substitutions and nested bash wrappers use a different $$).
  local pid="$1"
  local root walk

  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ "$pid" -eq "$$" ]] && return 0

  for root in "${IOTSTACK_FLASH_SESSION_PID:-}" "${IOTSTACK_FLASH_ROOT_PID:-}"; do
    [[ -z "$root" || ! "$root" =~ ^[0-9]+$ ]] && continue
    [[ "$pid" -eq "$root" ]] && return 0
    walk="$root"
    while [[ -n "$walk" && "$walk" -gt 1 ]]; do
      [[ "$pid" -eq "$walk" ]] && return 0
      walk=$(ps -o ppid= -p "$walk" 2>/dev/null | tr -d ' ')
    done
    esp_serial_pid_in_tree "$root" "$pid" && return 0
    esp_serial_pid_in_tree "$pid" "$root" && return 0
  done

  walk="$$"
  while [[ -n "$walk" && "$walk" -gt 1 ]]; do
    [[ "$pid" -eq "$walk" ]] && return 0
    walk=$(ps -o ppid= -p "$walk" 2>/dev/null | tr -d ' ')
  done
  esp_serial_pid_in_tree "$$" "$pid" && return 0

  return 1
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
  done < <(timeout 2s lsof -t "$tty" 2>/dev/null | sort -u || true)
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
    [[ -z "$pid" ]] && continue
    esp_serial_pid_in_current_session "$pid" && continue
    cmdline=$(esp_serial_process_cmdline "$pid")
    esp_serial_is_iotstack_flash_on_tty "$cmdline" "$tty" || continue
    printf '%s\n' "$pid"
  done < <(pgrep -f '(/iotstack\.sh|/iotstack) .+ flash ' 2>/dev/null || true)
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
    esp_serial_pid_in_current_session "$pid" && continue
    [[ -n "$preserve_root_pid" ]] && esp_serial_pid_in_tree "$preserve_root_pid" "$pid" && continue
    kill_pids+=("$pid")
  done < <(esp_serial_iotstack_serial_pids_on_tty "$tty")

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    esp_serial_pid_in_current_session "$pid" && continue
    [[ -n "$preserve_root_pid" ]] && esp_serial_pid_in_tree "$preserve_root_pid" "$pid" && continue
    kill_pids+=("$pid")
  done < <(esp_serial_stale_iotstack_flash_pids_on_tty "$tty")

  # serial-logs.py may be gone while log-stamp.py still runs in the pipeline.
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    esp_serial_pid_in_current_session "$pid" && continue
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
    esp_serial_pid_in_current_session "$pid" && continue
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
  esp_serial_settle_tty "$tty" 2
}

esp_serial_settle_tty() {
  # USB CDC ports need a moment after close/kill before esptool can reconnect.
  local tty="$1"
  local delay_s="${2:-1}"
  [[ -n "$tty" && -e "$tty" ]] || return 0
  sleep "$delay_s"
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
  done < <(timeout 2s lsof "$tty" 2>/dev/null | tail -n +2 || true)
}

esp_esptool_usb_cdc_chip() {
  # USB CDC/JTAG targets (S3/S2 DevKit): chained --before no-reset often loses the stub.
  case "${1:-}" in
    esp32s3|esp32s2) return 0 ;;
    *) return 1 ;;
  esac
}

esp_esptool_chained_before_mode() {
  # --before mode for follow-on esptool writes in the same flash session.
  local chip="${1:-}"
  if esp_esptool_usb_cdc_chip "$chip"; then
    printf '%s\n' default-reset
  else
    printf '%s\n' no-reset
  fi
}

esp_esptool_usb_jtag_chip() {
  # Chips that reach the ROM bootloader over a built-in USB-Serial/JTAG
  # controller (no external UART bridge, no native USB-OTG CDC).
  case "${1:-}" in
    esp32c3|esp32c5|esp32c6|esp32h2|esp32p4) return 0 ;;
    *) return 1 ;;
  esac
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

esp_esptool_flash_args_file_for_build() {
  # First line of ESPHome/PlatformIO flash_args (mode, freq, size).
  local build_dir="$1"
  local candidate

  [[ -n "$build_dir" ]] || return 1
  for candidate in \
    "${build_dir}/flash_args" \
    "${build_dir}/flash_project_args"; do
    [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

esp_esptool_flash_param_from_file() {
  # Read --flash_mode/--flash_freq/--flash_size value from flash_args first line.
  local file="$1"
  local key="$2"
  local -a tokens=()
  local i

  [[ -f "$file" ]] || return 1
  read -r -a tokens <"$file" || return 1
  i=0
  while (( i < ${#tokens[@]} )); do
    if [[ "${tokens[i]}" == "$key" && $((i + 1)) -lt ${#tokens[@]} ]]; then
      printf '%s' "${tokens[i + 1]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

esp_esptool_flash_params_for_build() {
  # Set flash_mode, flash_freq, flash_size from build_dir flash_args when present.
  # Usage: esp_esptool_flash_params_for_build <build_dir> mode_var freq_var size_var
  local build_dir="$1"
  local -n _mode_ref="$2"
  local -n _freq_ref="$3"
  local -n _size_ref="$4"
  local flash_file

  _mode_ref=dio
  _freq_ref=40m
  _size_ref="${IOTSTACK_BOOTSTRAP_FLASH_SIZE:-4MB}"

  flash_file=$(esp_esptool_flash_args_file_for_build "$build_dir") || return 0

  if mode=$(esp_esptool_flash_param_from_file "$flash_file" --flash_mode); then
    _mode_ref="$mode"
  fi
  if freq=$(esp_esptool_flash_param_from_file "$flash_file" --flash_freq); then
    _freq_ref="$freq"
  fi
  if size=$(esp_esptool_flash_param_from_file "$flash_file" --flash_size); then
    _size_ref="$size"
  fi
}

esp_ota_init_bin_for_build() {
  # OTA slot init image at 0xd000: prefer build ota_data_initial.bin, else boot_app0.bin.
  local build_dir="$1"
  local candidate

  [[ -n "$build_dir" ]] || return 1
  for candidate in \
    "${build_dir}/ota_data_initial.bin" \
    "${build_dir}/boot_app0.bin" \
    "${HOME}/.platformio/packages/framework-arduinoespressif32/tools/partitions/boot_app0.bin"; do
    [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

esp_ota_init_bin_label() {
  local path="$1"
  case "$(basename "$path")" in
    ota_data_initial.bin) printf 'ota_data_initial.bin' ;;
    boot_app0.bin) printf 'boot_app0.bin' ;;
    *) printf '%s' "$(basename "$path")" ;;
  esac
}

esp_boot_app0_bin_for_build() {
  esp_ota_init_bin_for_build "$@"
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

esp_mac_suffix_resolve_timeout() {
  # esp_mac_suffix_resolve with a hard wall-clock limit (post-layout USB handoff).
  local port="$1"
  local esptool_capture="${2:-}"
  local timeout_sec="${3:-${IOTSTACK_POST_LAYOUT_USB_TIMEOUT_SEC:-45}}"
  local scripts_dir mac rc=0

  [[ -e "$port" ]] || return 1
  [[ "$timeout_sec" =~ ^[0-9]+$ && "$timeout_sec" -gt 0 ]] || timeout_sec=45

  if [[ -n "$esptool_capture" ]]; then
    mac=$(esp_mac_from_esptool_output "$esptool_capture" 2>/dev/null) || mac=""
    if [[ -n "$mac" && "$mac" =~ ^[0-9a-f]{6}$ ]]; then
      printf '%s\n' "$mac"
      return 0
    fi
  fi

  scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mac=$(timeout "$timeout_sec" bash -c '
    # shellcheck source=scripts/esp-serial.sh
    source "$0/esp-serial.sh"
    esp_mac_suffix_from_port "$1"
  ' "$scripts_dir" "$port" 2>/dev/null) || rc=$?

  if [[ $rc -eq 124 ]]; then
    IOTSTACK_LAST_ESPTOOL_ERROR="chip MAC read timed out after ${timeout_sec}s on ${port}"
    return 124
  fi
  [[ -n "$mac" && "$mac" =~ ^[0-9a-f]{6}$ ]] && { printf '%s\n' "$mac"; return 0; }
  return 1
}

esp_esptool_chip_id() {
  # Run esptool chip-id with auto-reset. Tries 115200 then 9600 for detection.
  local port="$1"
  local chip_hint="${2:-${IOTSTACK_ESPTOOL_CHIP:-}}"
  local baud out resume_capture=0 rc=1 attempt
  local -a esptool_args err_file

  [[ -e "$port" ]] || return 1

  if [[ -n "${IOTSTACK_FLASH_SERIAL_TTY:-}" && "$IOTSTACK_FLASH_SERIAL_TTY" == "$port" \
      && -n "${IOTSTACK_SERIAL_LOG_PID:-}" ]] \
      && declare -F create_log_serial_capture_pause &>/dev/null; then
    create_log_serial_capture_pause
    resume_capture=1
    esp_serial_wait_tty_free "$port" 5 || true
  else
    esp_serial_clear_tty_interference "$port" "${IOTSTACK_FLASH_SESSION_PID:-}"
    esp_serial_wait_tty_free "$port" 3 || true
  fi

  esp_serial_settle_tty "$port" 1

  err_file=$(mktemp)
  IOTSTACK_LAST_ESPTOOL_ERROR=""
  local prompted=0
  for attempt in 1 2 3 4; do
    for baud in 115200 9600 57600; do
      # --after hard-reset: return to running firmware after probe (S3 status LED / USB stub).
      esptool_args=(--port "$port" --baud "$baud" --before default-reset --after hard-reset chip-id)
      [[ -n "$chip_hint" ]] && esptool_args=(--chip "$chip_hint" "${esptool_args[@]}")
      : >"$err_file"
      if out=$(python3 -m esptool "${esptool_args[@]}" 2>"$err_file"); then
        rc=0
        break 2
      fi
      if [[ -s "$err_file" ]]; then
        IOTSTACK_LAST_ESPTOOL_ERROR=$(tail -5 "$err_file")
      fi
    done
    [[ $rc -eq 0 ]] && break
    # Native USB-Serial/JTAG auto-reset (XIAO ESP32-C6) is unreliable -- esptool's
    # default-reset often can't pull the chip into download mode, so this loop would
    # otherwise churn silently for minutes. After the first failed attempt on the
    # active flash port, ask the human to press RESET as a last resort, then keep
    # retrying (attempts 2-4) so the press is picked up.
    if (( prompted == 0 )) && [[ "${IOTSTACK_FLASH_SERIAL_TTY:-}" == "$port" ]]; then
      _esp_serial_log warn "[ACTION REQUIRED] No response from device on ${port} -- press the RESET button on the board now."
      _esp_serial_log warn "  (XIAO ESP32-C6 USB auto-reset is unreliable. If it still won't connect: hold BOOT, tap RESET, release BOOT.)"
      prompted=1
    fi
    esp_serial_settle_tty "$port" 2
  done
  if [[ $rc -ne 0 && -n "${IOTSTACK_LAST_ESPTOOL_ERROR:-}" ]]; then
    _esp_serial_log warn "esptool chip-id failed on $port:"
    while IFS= read -r line; do
      [[ -n "$line" ]] && _esp_serial_log warn "  $line"
    done <<<"$IOTSTACK_LAST_ESPTOOL_ERROR"
  fi
  rm -f "$err_file"

  if [[ $rc -eq 0 ]]; then
    # Ensure esptool released the TTY and the chip left the ROM stub (S3 status LED).
    esp_serial_wait_tty_free "$port" 3 || true
    esp_serial_settle_tty "$port" 1
  fi

  if [[ $resume_capture -eq 1 ]] && declare -F create_log_serial_capture_resume &>/dev/null; then
    create_log_serial_capture_resume
  fi

  if [[ $rc -eq 0 ]]; then
    printf '%s' "$out"
    return 0
  fi
  return 1
}

esp_flash_sessions_on_tty() {
  # Other iotstack flash invocations targeting the same TTY (pid per line).
  local tty="$1"
  local pid cmdline

  [[ -n "$tty" ]] || return 0
  while IFS= read -r pid; do
    [[ -z "$pid" || "$pid" == "$$" ]] && continue
    esp_serial_pid_in_current_session "$pid" && continue
    cmdline=$(esp_serial_process_cmdline "$pid")
    esp_serial_is_iotstack_flash_on_tty "$cmdline" "$tty" || continue
    printf '%s\n' "$pid"
  done < <(pgrep -f '(/iotstack\.sh|/iotstack) .+ flash ' 2>/dev/null || true)
}

esp_detect_chip() {
  # Echo esphome/esp-idf variant slug: esp32c6, esp32s3, esp32, esp32c3, ...
  local port="$1"
  local chip_hint="${2:-}"
  local out variant

  [[ -e "$port" ]] || return 1

  if ! out=$(esp_esptool_chip_id "$port" "$chip_hint"); then
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