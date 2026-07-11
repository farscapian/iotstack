#!/bin/bash
# iotstack.sh -- CLI tool for managing iotstack ESPHome devices
# Wrapper around update_devices.sh with a cleaner interface

set -euo pipefail

# Top-level invocation PID; subshells (e.g. profile=$(bootstrap_resolve_profile))
# use a different $$ but must not be treated as a stale flash session.
export IOTSTACK_FLASH_ROOT_PID=$$

# Global configuration
VERBOSE=0
QUIET=0
IOTSTACK_TIMESTAMP=0
# ENV_FILE is defined in config.sh

# Colors (using ANSI-C quoting to properly interpret escape sequences)
RED=$'\033[0;31m'
GRN=$'\033[0;32m'
YLW=$'\033[0;33m'
BLU=$'\033[0;34m'
DIM=$'\033[2m'
RST=$'\033[0m'

err()  { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }
ok()   { [[ $QUIET -eq 0 ]] && echo -e "${GRN}[OK]${RST} $*"; return 0; }
warn() { [[ $QUIET -eq 0 ]] && echo -e "${YLW}[WARN]${RST} $*"; return 0; }
info() { [[ $QUIET -eq 0 ]] && echo -e "${BLU}[INFO]${RST} $*"; return 0; }
debug() { [[ $VERBOSE -eq 1 ]] && [[ $QUIET -eq 0 ]] && echo -e "${DIM}[DEBUG]${RST} $*" >&2; return 0; }

# Forward iotstack global flags to update_devices.sh.
_update_devices_inherited_flags() {
  [[ $VERBOSE -eq 1 ]] && printf '%s\n' --verbose
  iotstack_compilation_output_enabled && printf '%s\n' --compilation-output
}

# Print a table separator rule aligned to the header columns. Each argument is
# a column width; prints that many '-' per column with single-space gaps,
# wrapped in DIM. Dashes are built by space-padding then substitution so the
# width is correct -- printf '%-Ns' counts bytes and would mis-pad the
# multibyte '-' (U+2500) characters.
_print_table_rule() {
  local first=1 w dashes
  printf '  %s' "$DIM"
  for w in "$@"; do
    (( first )) || printf ' '
    printf -v dashes '%*s' "$w" ''
    printf '%s' "${dashes// /-}"
    first=0
  done
  printf '%s\n' "$RST"
}

# -- Compile skip (config_hash) -----------------------------------------------
# Skip esphome compile when `esphome config-hash` matches build_info.json and
# firmware.bin exists. The config_hash helpers (_current_config_hash_for_yaml,
# _build_matches_config_hash, _config_hash_from_build_dir, ...) live in
# scripts/iotstack-version.sh so iotstack.sh and update_devices.sh share the exact
# same logic. Only the iotstack.sh-specific miss-reason logger stays here.

_compile_skip_miss_reason() {
  local yaml_file="$1"
  local device_name="${2:-}"
  local yaml_name current_hash built_hash firmware_bin resolved_device

  yaml_name=$(iotstack_compilation_cache_yaml_name "$yaml_file")
  resolved_device=$(_compile_skip_device_name "$yaml_file" "$device_name")

  built_hash=$(_config_hash_from_build_dir "$resolved_device" 2>/dev/null) || built_hash=""
  if [[ -z "$built_hash" ]]; then
    echo "no build_info.json for ${resolved_device}"
    return 0
  fi

  current_hash=$(_current_config_hash_for_yaml "$yaml_file" "$resolved_device" 2>/dev/null) || current_hash=""
  if [[ -z "$current_hash" ]]; then
    echo "${yaml_name} config_hash unavailable (esphome config-hash failed)"
    return 0
  fi
  if [[ "$built_hash" != "$current_hash" ]]; then
    echo "${yaml_name} config_hash mismatch (built ${built_hash}, current ${current_hash})"
    return 0
  fi

  firmware_bin="${YAMLS_DIR}/.esphome/build/${resolved_device}/.pioenvs/${resolved_device}/firmware.bin"
  if [[ ! -f "$firmware_bin" ]]; then
    echo "${yaml_name} config_hash matched but firmware.bin missing"
    return 0
  fi
  echo "${yaml_name} compile skip check failed"
}

_check_serial_port_in_use() {
  # Free the port from stale iotstack captures, then fail on non-iotstack holders.
  local tty_device="$1"
  local processes pid cmd kill_cmd

  debug "_check_serial_port_in_use: checking $tty_device"

  if [[ -n "${IOTSTACK_FLASH_SERIAL_TTY:-}" && "$IOTSTACK_FLASH_SERIAL_TTY" == "$tty_device" \
      && -n "${IOTSTACK_SERIAL_LOG_PID:-}" ]]; then
    debug "Pausing device serial log capture for esptool on $tty_device..."
    create_log_serial_capture_pause
    sleep 1
    return 0
  fi

  esp_serial_clear_tty_interference "$tty_device" "${IOTSTACK_FLASH_SESSION_PID:-}"

  if command -v lsof &>/dev/null; then
    processes=$(esp_serial_tty_blocked_processes "$tty_device" || true)
    if [[ -n "$processes" ]]; then
      pid=$(awk '{print $2}' <<<"$processes" | head -1)
      cmd=$(awk '{print $1}' <<<"$processes" | head -1)
      if [[ "$cmd" == "screen" ]]; then
        kill_cmd="screen -X -S $pid quit"
      else
        kill_cmd="kill -9 $pid"
      fi
      err "Serial port $tty_device is already in use:
$processes

Quick fix (copy/paste):
  $kill_cmd

Or manually: press Ctrl+A then D to detach screen, then run the command above."
    fi
    return 0
  fi

  if command -v fuser &>/dev/null; then
    if fuser "$tty_device" >/dev/null 2>&1; then
      warn "Serial port $tty_device may be in use. Close any open terminal sessions before flashing."
    fi
  fi
}

_hex_sizes_equal() {
  local a="${1,,}" b="${2,,}"
  [[ -n "$a" && "$a" == "$b" ]]
}

_partition_table_bootstrap_size() {
  # Bootstrap (ota_0) size from the persisted partition table artifact (~/.iotstack/artifacts/).
  # Survives `iotstack clean` so pass 1 can start exact.
  [[ -f "$PARTITION_TABLE" ]] || return 1
  local size label
  label=$(iotstack_bootstrap_role)
  size=$(awk -F, -v label="$label" '
    $1 ~ ("^" label "[[:space:]]*$") {
      gsub(/ /, "", $5)
      print $5
      exit
    }
  ' "$PARTITION_TABLE")
  [[ -n "$size" && "$size" =~ ^0x[0-9a-fA-F]+$ ]] || return 1
  printf '%s' "$size"
}

_sync_bootstrap_partition_table_from_build() {
  local build_csv="${YAMLS_DIR}/.esphome/build/$(iotstack_bootstrap_role)/partitions.csv"
  if [[ -f "$build_csv" ]] && grep -qE '^production,' "$build_csv" 2>/dev/null; then
    cp "$build_csv" "$PARTITION_TABLE"
    _ensure_partition_table_symlink "$PARTITION_TABLE"
    debug "Partition table synced from bootstrap build (production offset $(flash_partition_offset production 2>/dev/null))"
  fi
}

_bootstrap_part_size() {
  # Echo the bootstrap (ota_0) partition size as hex for a given firmware.bin:
  # round_up_64KB(firmware_size + IOTSTACK_BOOTSTRAP_MARGIN). Falls back to
  # IOTSTACK_BOOTSTRAP_PART_SIZE if the binary cannot be measured.
  local bin="$1"
  local margin="${IOTSTACK_BOOTSTRAP_MARGIN:-0x10000}"
  local sz
  sz=$(stat -c%s "$bin" 2>/dev/null || stat -f%z "$bin" 2>/dev/null || echo 0)
  if (( sz <= 0 )); then
    printf '%s' "${IOTSTACK_BOOTSTRAP_PART_SIZE:-0xe0000}"
    return
  fi
  local total=$(( sz + margin ))
  (( total % 0x10000 != 0 )) && total=$(( (total / 0x10000 + 1) * 0x10000 ))
  printf '0x%x' "$total"
}

_esphome_compile_show_failure() {
  local compile_yaml="$1"
  local compile_log="$2"
  local line

  [[ -f "$compile_log" && -s "$compile_log" ]] || return 0
  warn "Compile failed for $(basename "$compile_yaml") (last lines):"
  if declare -F create_log_stamp_line &>/dev/null && create_log_enabled; then
    create_log_stamp_line "esphome:compile" "--- compile failed: $(basename "$compile_yaml") ---"
    while IFS= read -r line; do
      create_log_stamp_line "esphome:compile" "$line"
    done <"$compile_log"
  fi
  tail -40 "$compile_log" >&2
}

_esphome_compile() {
  # Run esphome compile; one INFO line names the compile YAML. By default compiler
  # output is captured and shown only on failure. --compilation-output streams it live.
  local yaml_file="$1"
  local compile_yaml compile_log rc=0
  compile_yaml=$(iotstack_prepare_compile_yaml "$yaml_file") || return 1
  compile_log=$(mktemp)
  info "Compiling $(basename "$compile_yaml")..."
  if iotstack_compilation_output_enabled; then
    local -a compile_tee_targets=("$compile_log")
    [[ -e /dev/tty && -w /dev/tty ]] && compile_tee_targets+=("/dev/tty")
    if create_log_child_output_piped; then
      create_log_subprocess_indent_env
      if ! env PYTHONUNBUFFERED=1 stdbuf -oL -eL esphome compile "$compile_yaml" 2>&1 \
          | stdbuf -oL -eL tee "${compile_tee_targets[@]}" \
          | create_log_tee_console "esphome:compile"; then
        rc=1
      fi
    elif ! env PYTHONUNBUFFERED=1 stdbuf -oL -eL esphome compile "$compile_yaml" 2>&1 \
        | stdbuf -oL -eL tee "$compile_log"; then
      rc=1
    fi
    [[ $rc -eq 1 ]] && _esphome_compile_show_failure "$compile_yaml" "$compile_log"
  elif ! esphome compile "$compile_yaml" >"$compile_log" 2>&1; then
    rc=1
    _esphome_compile_show_failure "$compile_yaml" "$compile_log"
  fi
  rm -f "$compile_log"
  iotstack_cleanup_compile_yaml "$compile_yaml" "$yaml_file"
  return $rc
}

declare -gA _IOTSTACK_COMPILE_CACHE_HIT_NOTIFIED=()
declare -gA _IOTSTACK_SMART_COMPILE_DONE=()

_smart_compile_already_done() {
  local yaml_file="$1"
  local cache_key
  cache_key=$(iotstack_compilation_cache_yaml_name "$yaml_file")
  [[ -n "${_IOTSTACK_SMART_COMPILE_DONE[$cache_key]:-}" ]]
}

_smart_compile_mark_done() {
  local yaml_file="$1"
  local cache_key
  cache_key=$(iotstack_compilation_cache_yaml_name "$yaml_file")
  _IOTSTACK_SMART_COMPILE_DONE[$cache_key]=1
}

_smart_compile_repeat_satisfied() {
  local yaml_file="$1"
  local device_name="$2"
  local firmware_bin="${YAMLS_DIR}/.esphome/build/${device_name}/.pioenvs/${device_name}/firmware.bin"
  debug "Build already prepared for $(iotstack_compilation_cache_yaml_name "$yaml_file")"
  if _is_bootstrap_yaml "$yaml_file"; then
    _sync_bootstrap_partition_table_from_build \
      || { local fs_size; fs_size=$(_bootstrap_part_size "$firmware_bin")
           IOTSTACK_BOOTSTRAP_PART_SIZE="$fs_size" _update_partition_table_file; }
  else
    ensure_partition_table_artifact
  fi
}

_smart_compile_cache_hit_notice() {
  local yaml_file="$1"
  local device_name="$2"
  local firmware_kind="$3"  # e.g. production, bootstrap
  local notify_key
  notify_key="${firmware_kind}:$(iotstack_compilation_cache_yaml_name "$yaml_file")"
  [[ -n "${_IOTSTACK_COMPILE_CACHE_HIT_NOTIFIED[$notify_key]:-}" ]] && return 0
  _IOTSTACK_COMPILE_CACHE_HIT_NOTIFIED[$notify_key]=1
  info "Compilation cache hit -- ${firmware_kind} firmware (${device_name}) already built; compile skipped"
}

_smart_compile_cache_miss_notice() {
  # Log why smart_compile cannot reuse a cached build (called before esphome compile).
  local yaml_file="$1"
  local device_name="$2"
  local firmware_kind="$3"  # e.g. production, bootstrap
  local reason
  reason=$(_compile_skip_miss_reason "$yaml_file" "$device_name")
  info "Compilation cache miss -- ${firmware_kind} firmware (${device_name}): ${reason}"
}

_flash_sync_update_devices_cache() {
  # After smart_compile, write update_devices.sh's build cache so --reassign skips recompile.
  local yaml_file="$1"
  local yaml_name
  yaml_name=$(basename "$yaml_file" .yaml)
  local cache_file="${IOTSTACK_HOME}/logs/${yaml_name}.build.cache"
  local build_info="${YAMLS_DIR}/.esphome/build/${yaml_name}/build_info.json"
  [[ -f "$build_info" ]] || return 0
  local esphome_version config_hash
  esphome_version=$(esphome version 2>/dev/null | grep -o '[0-9][0-9]*\.[0-9.]*' | head -1) || return 0
  config_hash=$(python3 -c \
    "import json,sys; print(format(json.load(open(sys.argv[1]))['config_hash'], '08x'))" \
    "$build_info" 2>/dev/null) || return 0
  mkdir -p "$(dirname "$cache_file")"
  printf 'esphome_version=%s\nconfig_hash=%s\n' \
    "$esphome_version" "$config_hash" > "$cache_file"
  debug "Synced update_devices build cache for ${yaml_name}"
}

smart_compile() {
  # Smart compilation that skips a rebuild when the current esphome config_hash
  # already matches the built one. config_hash is the sole build-identity key
  # (it reflects YAML + packages + common/ + external_components/ + git tag via
  # the project_version fingerprint), so there is no force/disable escape hatch.
  # Usage: smart_compile <yaml_file> [device_name_for_logging]
  local yaml_file="$1"
  local device_name="${2:-unknown}"

  if _smart_compile_already_done "$yaml_file"; then
    _smart_compile_repeat_satisfied "$yaml_file" "$device_name"
    return 0
  fi

  local firmware_bin="${YAMLS_DIR}/.esphome/build/${device_name}/.pioenvs/${device_name}/firmware.bin"
  local cached=0
  _build_matches_config_hash "$yaml_file" "$device_name" && cached=1

  # -- Non-bootstrap builds ----------------------------------------------------
  # Production firmware is OTA'd into the production partition and uses ESPHome's
  # default partition table for its build-size check, so the custom table size
  # is irrelevant to it. Just make sure a table exists, then compile.
  if ! _is_bootstrap_yaml "$yaml_file"; then
    if [[ $cached -eq 1 ]]; then
      ensure_partition_table_artifact
      _smart_compile_cache_hit_notice "$yaml_file" "$device_name" "production"
      _smart_compile_mark_done "$yaml_file"
      return 0
    fi
    _update_partition_table_file
    _smart_compile_cache_miss_notice "$yaml_file" "$device_name" "production"
    _esphome_compile "$yaml_file" || return 1
    _smart_compile_mark_done "$yaml_file"
    return 0
  fi

  # -- Bootstrap: size its partition dynamically to the actual firmware ---------
  # The bootstrap partition is sized to exactly what bootstrap needs (+ margin);
  # production absorbs the rest. The partition size affects the flashed
  # partitions.bin (not the position-independent app image), so we compile,
  # measure, regenerate the table, then recompile so partitions.bin matches.
  if [[ $cached -eq 1 && -f "$firmware_bin" ]]; then
    _smart_compile_cache_hit_notice "$yaml_file" "$device_name" "bootstrap"
    _sync_bootstrap_partition_table_from_build \
      || { local fs_size; fs_size=$(_bootstrap_part_size "$firmware_bin")
           IOTSTACK_BOOTSTRAP_PART_SIZE="$fs_size" _update_partition_table_file; }
    _smart_compile_mark_done "$yaml_file"
    return 0
  fi

  # Pass 1: compile (prefer persisted partition size; fall back to generous default).
  local pass1_size fs_size fw_bytes partitions_bin
  _smart_compile_cache_miss_notice "$yaml_file" "$device_name" "bootstrap"
  local generous_size="${IOTSTACK_BOOTSTRAP_PART_SIZE_GENEROUS:-0x180000}"
  pass1_size=$(_partition_table_bootstrap_size 2>/dev/null) \
    || pass1_size="${IOTSTACK_BOOTSTRAP_PART_SIZE:-0xe0000}"
  export IOTSTACK_BOOTSTRAP_PART_SIZE="$pass1_size"
  _update_partition_table_file
  if _hex_sizes_equal "$pass1_size" "$generous_size"; then
    debug "Bootstrap compile pass 1/2: measuring firmware size (partition ${pass1_size})"
  else
    debug "Bootstrap compile pass 1: partition table ${pass1_size}"
  fi
  if ! _esphome_compile "$yaml_file"; then
    if _hex_sizes_equal "$pass1_size" "$generous_size"; then
      return 1
    fi
    warn "Bootstrap compile failed with partition ${pass1_size} -- retrying with generous ${generous_size}"
    export IOTSTACK_BOOTSTRAP_PART_SIZE="$generous_size"
    _update_partition_table_file
    debug "Bootstrap compile pass 1/2: measuring firmware size (partition ${generous_size})"
    _esphome_compile "$yaml_file" || return 1
  fi

  fs_size=$(_bootstrap_part_size "$firmware_bin")
  fw_bytes=$(stat -c%s "$firmware_bin" 2>/dev/null || echo "?")
  info "Bootstrap firmware ${fw_bytes} bytes -> bootstrap partition ${fs_size}"
  partitions_bin="${YAMLS_DIR}/.esphome/build/$(iotstack_bootstrap_role)/.pioenvs/$(iotstack_bootstrap_role)/partitions.bin"

  if _hex_sizes_equal "$fs_size" "$IOTSTACK_BOOTSTRAP_PART_SIZE" && [[ -f "$partitions_bin" ]]; then
    _sync_bootstrap_partition_table_from_build
    info "Bootstrap partition table already exact (${fs_size}) -- skipping pass 2"
  else
    export IOTSTACK_BOOTSTRAP_PART_SIZE="$fs_size"
    _update_partition_table_file
    debug "Bootstrap compile pass 2/2: applying exact partition table (${fs_size})"
    _esphome_compile "$yaml_file" || return 1
    _sync_bootstrap_partition_table_from_build
  fi

  _smart_compile_mark_done "$yaml_file"
  return 0
}

# Prompt for multi-device operations
confirm_multi_device() {
  local count="$1"
  local devices_desc="$2"

  if [[ $count -le 1 ]]; then
    return 0  # Single device, no prompt needed
  fi

  echo ""
  warn "This operation will affect $count device(s):"
  echo "  $devices_desc"
  echo ""
  read -p "Continue? (y/N) " -n 1 -r
  echo ""

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    return 0
  else
    info "Operation cancelled."
    exit 0
  fi
}

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Source centralized configuration (now under scripts/). config.sh exports
# SCRIPTS_DIR, PROJECT_ROOT, ROLES_CONF and UPDATE_SCRIPT.
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/scripts/config.sh"
# shellcheck source=scripts/create-log.sh
source "${SCRIPT_DIR}/scripts/create-log.sh"

# --create-log: stamp iotstack messages to the session log (implies --timestamp);
# stdout stays on the tty. --create-log generates a GUID log id; implies --timestamp and -v.
_iotstack_log_plain() {
  local tag="$1"
  shift
  if create_log_enabled; then
    create_log_stamp_line "iotstack.sh" "[$tag] ${IOTSTACK_LOG_INDENT:-}$*"
  fi
}

_iotstack_echo() {
  local stream="$1"
  shift
  local ts indent="${IOTSTACK_LOG_INDENT:-}"
  ts=$(iotstack_timestamp_prefix)
  if [[ "$stream" == "stderr" ]]; then
    echo -e "${ts}${indent}$*" >&2
  else
    echo -e "${ts}${indent}$*"
  fi
}

# Flash workflow step banners; nested log lines use IOTSTACK_LOG_INDENT (2 spaces).
declare -g IOTSTACK_LOG_INDENT=""
declare -g _IOTSTACK_FLASH_STEP_NUM=0
declare -g IOTSTACK_FLASH_SUPPRESS_STEPS=0

_flash_step_reset() {
  _IOTSTACK_FLASH_STEP_NUM=0
  _IOTSTACK_FLASH_SERIAL_STEP=0
  _IOTSTACK_FLASH_NVS_STEP=0
  _IOTSTACK_FLASH_OTA_STEP=0
  export IOTSTACK_LOG_INDENT=""
}

_flash_step_begin_at() {
  local num="$1"
  local title="$2"
  [[ "${IOTSTACK_FLASH_SUPPRESS_STEPS:-0}" == "1" ]] && return 0
  _IOTSTACK_FLASH_STEP_NUM=$num
  export IOTSTACK_LOG_INDENT=""
  echo ""
  _iotstack_echo stdout "${BLU}[INFO]${RST} Step ${num}: ${title}"
  export IOTSTACK_LOG_INDENT="  "
}

_flash_preflight_step_begin() {
  _flash_step_begin_at 0 "Preflight checks"
}

_flash_step_begin() {
  local title="$1"
  _flash_step_begin_at $((_IOTSTACK_FLASH_STEP_NUM + 1)) "$title"
}

_flash_step_end() {
  export IOTSTACK_LOG_INDENT=""
}

declare -g _IOTSTACK_FLASH_SERIAL_STEP=0
declare -g _IOTSTACK_FLASH_NVS_STEP=0
declare -g _IOTSTACK_FLASH_OTA_STEP=0

_flash_serial_step_begin() {
  # USB/esptool: bootloader, partition table, boot_app0, bootstrap partition only.
  [[ "${_IOTSTACK_FLASH_SERIAL_STEP:-0}" == "1" ]] && return 0
  _IOTSTACK_FLASH_SERIAL_STEP=1
  _flash_step_begin "Flashing production partition table and bootstrap image via serial"
}

_flash_nvs_step_begin() {
  # WiFi credentials and device secrets (API when bootstrap is online, else USB).
  [[ "${_IOTSTACK_FLASH_NVS_STEP:-0}" == "1" ]] && return 0
  _IOTSTACK_FLASH_NVS_STEP=1
  _flash_step_begin "Write device-specific secrets to NVS"
}

_flash_ota_step_begin() {
  # Production partition updates use the same path as: iotstack update <role> <mac>
  [[ "${_IOTSTACK_FLASH_OTA_STEP:-0}" == "1" ]] && return 0
  _IOTSTACK_FLASH_OTA_STEP=1
  _flash_step_begin "iotstack update (production OTA)"
}

err()  { _iotstack_log_plain "ERROR" "$@"; _iotstack_echo stderr "${RED}[ERROR]${RST} $*"; exit 1; }
ok()   { [[ $QUIET -eq 0 ]] && { _iotstack_log_plain "OK" "$@"; _iotstack_echo stdout "${GRN}[OK]${RST} $*"; }; return 0; }
warn() { [[ $QUIET -eq 0 ]] && { _iotstack_log_plain "WARN" "$@"; _iotstack_echo stdout "${YLW}[WARN]${RST} $*"; }; return 0; }
info() { [[ $QUIET -eq 0 ]] && { _iotstack_log_plain "INFO" "$@"; _iotstack_echo stdout "${BLU}[INFO]${RST} $*"; }; return 0; }
debug() { [[ $VERBOSE -eq 1 && $QUIET -eq 0 ]] && { _iotstack_log_plain "DEBUG" "$@"; _iotstack_echo stderr "${DIM}[DEBUG]${RST} $*"; }; return 0; }

_run_update_devices() {
  if create_log_child_output_piped; then
    create_log_run "update_devices.sh" bash "$UPDATE_SCRIPT" "$@"
    return $?
  fi
  "$UPDATE_SCRIPT" "$@"
}

# partition-table.sh is sourced by config.sh (generate_partition_table, update_partition_table_file)
# shellcheck source=scripts/bootstrap-yaml.sh
source "${SCRIPT_DIR}/scripts/bootstrap-yaml.sh"
# shellcheck source=scripts/flash-compare.sh
source "${SCRIPT_DIR}/scripts/flash-compare.sh"

_is_bootstrap_yaml() {
  bootstrap_is_artifact_yaml "$1" || [[ "$(basename "$1")" == "bootstrap.yaml" ]]
}

_update_partition_table_file() {
  debug "Generating local build partition table CSV: $PARTITION_TABLE"
  update_partition_table_file
  debug "Build partition table CSV ready (bootstrap + production layout for compile -- not read from device)"
}

# UPDATE_SCRIPT is provided by config.sh (scripts/update_devices.sh)

_load_ha_credentials_optional() {
  # shellcheck source=scripts/ensure-integration-secrets.sh
  source "${SCRIPT_DIR}/scripts/ensure-integration-secrets.sh"
  load_ha_credentials_optional
}

_ensure_chip_tool_storage() {
  command -v chip-tool &>/dev/null || return 0
  # shellcheck source=scripts/ensure-chip-tool-storage.sh
  source "${SCRIPT_DIR}/scripts/ensure-chip-tool-storage.sh"
  setup_chip_tool_storage
}

_ha_websocket_call_service() {
  local domain="$1"
  local service="$2"
  local target_json="$3"

  python3 "${SCRIPT_DIR}/scripts/ha_websocket.py" \
    --ha-url "$HA_URL" \
    --ha-token "$HA_TOKEN" \
    call-service "$domain" "$service" \
    --target "$target_json" \
    >/dev/null 2>&1
}

# Check if update_devices.sh exists
if [[ ! -f "$UPDATE_SCRIPT" ]]; then
  err "update_devices.sh not found at $UPDATE_SCRIPT"
fi

if [[ ! -d "$YAMLS_DIR" ]]; then
  err "yamls directory not found at $YAMLS_DIR"
fi

# -- Dynamic Role Discovery --------------------------------------------------
# Roles are discovered from YAML filenames in yamls/ directory
# File: yamls/bleproxy.yaml -> Role: bleproxy

# Resolve role name to YAML path
# If given "bleproxy", returns "yamls/bleproxy.yaml"
resolve_device() {
  local role_name="$1"

  # Check if role is defined in roles.conf
  if ! is_valid_role "$role_name"; then
    local available_roles
    available_roles=$(list_roles_from_conf | tr '\n' ', ' | sed 's/,$//')
    err "Unknown role: '$role_name'

Available roles:
  $available_roles

Run 'iotstack roles' for details."
  fi

  local yaml_file="${YAMLS_DIR}/${role_name}.yaml"

  # Verify YAML file exists
  if [[ ! -f "$yaml_file" ]]; then
    err "Role '$role_name' defined in roles.conf but YAML not found: $yaml_file"
  fi

  echo "$yaml_file"
}

# Extract device_type and network_type from YAML file
# Returns: "device_type|network_type" (e.g., "esp32c6|wifi")
get_yaml_device_info() {
  local yaml_file="$1"
  local board=""
  local variant=""
  local network_type=""

  if [[ -f "$yaml_file" ]]; then
    # Extract board and variant from esp32 section
    board=$(grep -A5 "^esp32:" "$yaml_file" | grep -E "^\s*board:\s*" | head -1 | sed 's/.*board:\s*//; s/\s*$//')
    variant=$(grep -A5 "^esp32:" "$yaml_file" | grep -E "^\s*variant:\s*" | head -1 | sed 's/.*variant:\s*//; s/\s*$//')

    # Determine network_type from presence of wifi or openthread sections
    if grep -q "^wifi:" "$yaml_file" 2>/dev/null; then
      network_type="wifi"
    elif grep -q "^openthread:" "$yaml_file" 2>/dev/null; then
      network_type="thread"
    fi
  fi

  echo "${board}|${variant}|${network_type}"
}

# List available role names from roles.conf
# Returns: role names (one per line)
list_roles_from_conf() {
  grep -v "^#\|^$" "$ROLES_CONF" | cut -d= -f1 | sort
}

# Validate that a role name exists in roles.conf
# Returns: 0 if valid, 1 if invalid
is_valid_role() {
  local role_name="$1"
  list_roles_from_conf | grep -q "^${role_name}$"
}

# List available role names (YAML filenames without extension,)
# DEPRECATED: Use list_roles_from_conf() instead - this scans all YAML files, not official roles
list_device_names() {
  for yaml_file in "$YAMLS_DIR"/*.yaml; do
    if [[ -f "$yaml_file" ]]; then
      local basename_only
      basename_only=$(basename "$yaml_file" .yaml)
      [[ "$basename_only" == "secrets" ]] && continue
      echo "$basename_only"
    fi
  done | sort
}

# Query Home Assistant for device areas via WebSocket
# Returns JSON with device_name -> area_name mapping
get_ha_device_areas() {
  _load_ha_credentials_optional || return 1

  local ha_token="$HA_TOKEN"
  local ha_url="$HA_URL"

  # Convert HTTP/HTTPS to WS/WSS
  local ws_url="${ha_url//http:/ws:}"
  ws_url="${ws_url//https:/wss:}"
  ws_url="${ws_url}/api/websocket"

  # Query device registry and area registry via WebSocket (with timeout)
  timeout 5 bash -c "{
    echo '{\"type\": \"auth\", \"access_token\": \"'$ha_token'\"}'
    sleep 0.5
    echo '{\"id\": 1, \"type\": \"config/device_registry/list\"}'
    sleep 0.5
    echo '{\"id\": 2, \"type\": \"config/area_registry/list\"}'
    sleep 2
  } | websocat -n '$ws_url' 2>/dev/null" | jq -s '
    # Handle case where responses might not be in expected order
    map(select(.result != null)) |
    # Find device and area registries
    (map(select(.id == 1) | .result) | .[0] // []) as $devices |
    (map(select(.id == 2) | .result) | .[0] // []) as $areas |
    # Build area lookup map (area_id -> name)
    ($areas | map({(.id): .name}) | add // {}) as $area_map |
    # Map device names to area (handle multiple formats)
    ($devices | map(
      .name as $name |
      ($name | sub("-[0-9a-fA-F]{6}$"; "")) as $name_base |
      ($name | capture("(?<suffix>[0-9a-fA-F]{6})$") | .suffix // "") as $mac_suffix |
      {
        ($name): ($area_map[.area_id] // "-"),
        ($name_base): ($area_map[.area_id] // "-")
      } +
      if ($mac_suffix != "") then {($mac_suffix): ($area_map[.area_id] // "-")} else {} end
    ) | add // {})
  ' 2>/dev/null || echo '{}'
}

# -- Parallel Job Queue --------------------------------------------------------
# Helper to run multiple commands in parallel with job limiting
# Usage: run_parallel_jobs <max_jobs> <"cmd1" "cmd2" ...>
# Each command is executed in background, with at most max_jobs running
# Returns array job_results[i] with exit code of command i
run_parallel_jobs() {
  local max_jobs=$1
  shift
  local commands=("$@")
  local slot_count=0
  declare -a job_pids=()

  for i in "${!commands[@]}"; do
    # Wait for a slot to free up
    while [[ $slot_count -ge $max_jobs ]]; do
      wait -n 2>/dev/null || true
      slot_count=$((slot_count - 1))
    done

    # Start job in background
    local cmd="${commands[$i]}"
    eval "$cmd" &
    job_pids[i]=$!
    slot_count=$((slot_count + 1))
  done

  # Wait for all remaining jobs
  job_results=()
  for i in "${!job_pids[@]}"; do
    local pid="${job_pids[$i]}"
    wait "$pid" 2>/dev/null
    job_results[i]=$?
  done
}

# -- Subcommands --------------------------------------------------------------

usage() {
  cat "${SCRIPT_DIR}/docs/help/iotstack.txt"
}

help_update() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-update.txt"
}

help_verify() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-verify.txt"
}

help_verify_flash() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-verify-flash.txt"
}

help_devices() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-devices.txt"
}

help_bootstrap() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-bootstrap.txt"
}

help_roles() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-roles.txt"
}

_ROLE_HELP_DIR="${SCRIPT_DIR}/docs/help/roles"

role_help_file() {
  printf '%s/%s.txt' "$_ROLE_HELP_DIR" "$1"
}

_iotstack_extract_role_from_args() {
  # First production role in argv (skip help, flags, MACs, paths, tty devices).
  local arg
  for arg in "$@"; do
    [[ "$arg" == "help" ]] && continue
    [[ "$arg" =~ ^-- ]] && continue
    [[ "$arg" =~ ^/dev/ ]] && continue
    [[ "$arg" =~ ^[0-9a-fA-F]{6}$ ]] && continue
    [[ -f "$arg" ]] && continue
    [[ "$arg" == "all" ]] && continue
    if is_valid_role "$arg"; then
      printf '%s\n' "$arg"
      return 0
    fi
  done
  return 1
}

_iotstack_command_help_if_requested() {
  # Usage: _iotstack_command_help_if_requested <flash|update|reassign|verify> "$@"
  # Shows per-role help when help + role are present; else generic command help.
  local cmd="$1"
  shift
  local arg role="" want_help=0
  for arg in "$@"; do
    [[ "$arg" == "help" ]] && want_help=1
  done
  [[ $want_help -eq 1 ]] || return 1
  role=$(_iotstack_extract_role_from_args "$@") || role=""
  if [[ -n "$role" ]]; then
    help_role "$role"
  else
    case "$cmd" in
      flash)    help_flash ;;
      update)   help_update ;;
      reassign) help_reassign ;;
      verify)   help_verify ;;
      *)        return 1 ;;
    esac
  fi
  return 0
}

help_role() {
  local role="${1:-}"
  local yaml_file info board variant network friendly f

  if [[ -z "$role" ]]; then
    err "Usage: iotstack help <role>"
  fi
  if ! is_valid_role "$role"; then
    err "Unknown role: $role. Run 'iotstack roles' for available roles."
  fi

  f=$(role_help_file "$role")
  if [[ -f "$f" ]]; then
    cat "$f"
    return 0
  fi

  yaml_file=$(resolve_device "$role")
  info=$(get_yaml_device_info "$yaml_file")
  IFS='|' read -r board variant network <<< "$info"
  friendly=$(yaml_friendly_name_from_file "$yaml_file" 2>/dev/null) || friendly="$role"

  cat <<EOF
iotstack ${role} -- ${friendly}

Config: yamls/${role}.yaml
Chip: ${variant:-unknown}${board:+ (${board})}
Network: ${network:-unknown}

  iotstack flash ${role} [/dev/ttyACM0]
  iotstack update ${role}
  iotstack reassign <MAC> ${role}
  iotstack verify ${role}

Role help file not found: docs/help/roles/${role}.txt
EOF
}

help_reassign() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-reassign.txt"
}

help_flash() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-flash.txt"
}

help_logs() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-logs.txt"
}

help_query() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-query.txt"
}

help_secret() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-secret.txt"
}

help_rotate_secrets() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-rotate-secrets.txt"
}

help_device() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-device.txt"
}

_iotstack_require_jq() {
  command -v jq &>/dev/null || err "jq is required for --json output"
}

_iotstack_format_json() {
  # Validate and pretty-print a complete JSON document from stdin.
  _iotstack_require_jq
  jq '.'
}

_iotstack_json_slurp() {
  # Slurp newline-delimited JSON objects into one array, then pretty-print.
  _iotstack_require_jq
  jq -s '.'
}

_list_devices_flush_parsed_mdns_row() {
  local device_data="$1"
  local hostname="$2"
  local friendly="$3"
  local project="$4"
  local version="$5"
  local bootstrap_hash="$6"
  local production_hash="$7"

  [[ -z "$hostname" ]] && return 0

  local bootstrap_prefix
  bootstrap_prefix="$(iotstack_bootstrap_role)-"
  if [[ "$hostname" == "${bootstrap_prefix}"* ]]; then
    [[ -z "$friendly" ]] && friendly="$(iotstack_bootstrap_friendly_name)"
    [[ -z "$project" ]] && project="iotstack.$(iotstack_bootstrap_role)-prod"
  fi

  echo "$hostname|$friendly|$project|$version|$bootstrap_hash|$production_hash" >> "$device_data"
}

_list_devices_append_parsed_mdns() {
  # Append hostname|friendly|project|version|bootstrap_hash|production_hash rows.
  local device_data="$1"
  local current_hostname=""
  local current_friendly=""
  local current_project=""
  local current_version=""
  local current_bootstrap_hash=""
  local current_production_hash=""
  local current_config_hash=""

  while IFS= read -r line; do
    # avahi-browse -r emits "= interface IPv4 <hostname> ..." (resolved) and
    # "+ ..." (announced). When resolution is slow, only "+" lines may appear.
    if [[ $line =~ ^[=+][[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+([^[:space:]]+) ]]; then
      local parsed_host="${BASH_REMATCH[1]%.local}"
      if [[ -n "$current_hostname" && "$current_hostname" != "$parsed_host" ]]; then
        _list_devices_flush_parsed_mdns_row "$device_data" "$current_hostname" "$current_friendly" \
          "$current_project" "$current_version" "$current_bootstrap_hash" "$current_production_hash"
        current_friendly=""
        current_project=""
        current_version=""
        current_bootstrap_hash=""
        current_production_hash=""
        current_config_hash=""
      fi
      current_hostname="$parsed_host"
    elif [[ $line =~ hostname\ =\ \[([^\]]+)\] ]]; then
      local resolved_host="${BASH_REMATCH[1]%.local}"
      if [[ -n "$current_hostname" && "$current_hostname" != "$resolved_host" ]]; then
        _list_devices_flush_parsed_mdns_row "$device_data" "$current_hostname" "$current_friendly" \
          "$current_project" "$current_version" "$current_bootstrap_hash" "$current_production_hash"
        current_friendly=""
        current_project=""
        current_version=""
        current_bootstrap_hash=""
        current_production_hash=""
        current_config_hash=""
      fi
      current_hostname="$resolved_host"
    fi
    if [[ $line =~ txt\ = ]]; then
      if [[ $line =~ friendly_name=([^\"]*) ]]; then
        current_friendly="${BASH_REMATCH[1]}"
        current_friendly="${current_friendly% [0-9a-f][0-9a-f]*}"
      fi
      [[ $line =~ project_name=([^\"]*) ]] && current_project="${BASH_REMATCH[1]}"
      [[ $line =~ project_version=([^\"]*) ]] && current_version="${BASH_REMATCH[1]}"
      [[ $line =~ bootstrap_image_hash=([^\"]*) ]] && current_bootstrap_hash="${BASH_REMATCH[1]}"
      [[ $line =~ production_image_hash=([^\"]*) ]] && current_production_hash="${BASH_REMATCH[1]}"
      [[ $line =~ config_hash=([^\"]*) ]] && current_config_hash="${BASH_REMATCH[1]}"
      if [[ -n "$current_hostname" && -n "$current_config_hash" ]]; then
        if [[ "$current_hostname" == "$(iotstack_bootstrap_role)-"* ]]; then
          [[ -z "$current_bootstrap_hash" ]] && current_bootstrap_hash="$current_config_hash"
        else
          [[ -z "$current_production_hash" ]] && current_production_hash="$current_config_hash"
        fi
      fi
    fi
  done
  _list_devices_flush_parsed_mdns_row "$device_data" "$current_hostname" "$current_friendly" \
    "$current_project" "$current_version" "$current_bootstrap_hash" "$current_production_hash"
}

_list_devices_merge_by_mac() {
  # Collapse rows that share a MAC suffix; prefer production hostnames for identity fields.
  local input="$1"
  local output="$2"
  declare -A merged_bs merged_prod merged_friendly merged_project merged_version
  declare -A merged_host_prod merged_host_bs
  local -a macs=()

  while IFS='|' read -r hostname friendly project version bootstrap_hash production_hash; do
    [[ -z "$hostname" ]] && continue
    local mac="${hostname##*-}"
    [[ -z "$mac" ]] && continue
    macs+=("$mac")
    [[ -n "$bootstrap_hash" ]] && merged_bs["$mac"]="$bootstrap_hash"
    [[ -n "$production_hash" ]] && merged_prod["$mac"]="$production_hash"
    if [[ "$hostname" == "$(iotstack_bootstrap_role)-"* ]]; then
      merged_host_bs["$mac"]="$hostname"
      [[ -n "$friendly" ]] && merged_friendly["$mac"]="$friendly"
      [[ -n "$project" ]] && merged_project["$mac"]="$project"
      [[ -n "$version" ]] && merged_version["$mac"]="$version"
    else
      merged_host_prod["$mac"]="$hostname"
      [[ -n "$friendly" ]] && merged_friendly["$mac"]="$friendly"
      [[ -n "$project" ]] && merged_project["$mac"]="$project"
      [[ -n "$version" ]] && merged_version["$mac"]="$version"
    fi
  done < "$input"

  if ((${#macs[@]} > 0)); then
    mapfile -t macs < <(printf '%s\n' "${macs[@]}" | sort -u)
  fi
  : >"$output"
  local mac hostname
  for mac in "${macs[@]}"; do
    [[ -z "$mac" ]] && continue
    hostname="${merged_host_prod[$mac]:-${merged_host_bs[$mac]:-}}"
    [[ -z "$hostname" ]] && continue
    echo "$hostname|${merged_friendly[$mac]:-}|${merged_project[$mac]:-}|${merged_version[$mac]:-}|${merged_bs[$mac]:-}|${merged_prod[$mac]:-}" >>"$output"
  done
}

_list_devices_collect_mdns_parallel() {
  # Run production/bootstrap/meta avahi-browse in parallel, then parse into device_data.
  local device_data="$1"
  local device_mode="$2"
  local prod_raw="" boot_raw="" meta_raw=""
  local -a browse_pids=()
  local pid

  # -t -r resolves TXT records (friendly_name/project/version/image hashes) and
  # terminates after dumping the cache. -r alone would run until the timeout, so
  # -t keeps it prompt; the timeout is only a guard against a stalled resolve.
  # TCP liveness probes below drop any stale cache entries this returns.
  if [[ "$device_mode" != "bootstrap" ]]; then
    prod_raw=$(mktemp)
    timeout 8 avahi-browse -t -r "_esphomelib._tcp" 2>/dev/null >"$prod_raw" &
    browse_pids+=("$!")
    meta_raw=$(mktemp)
    timeout 8 avahi-browse -t -r "$(iotstack_meta_mdns_service)" 2>/dev/null >"$meta_raw" &
    browse_pids+=("$!")
  fi
  if [[ "$device_mode" != "production" ]]; then
    boot_raw=$(mktemp)
    timeout 8 avahi-browse -t -r "$(iotstack_bootstrap_mdns_service)" 2>/dev/null >"$boot_raw" &
    browse_pids+=("$!")
  fi

  for pid in "${browse_pids[@]}"; do
    wait "$pid" || true
  done

  if [[ -n "$prod_raw" ]]; then
    _list_devices_append_parsed_mdns "$device_data" <"$prod_raw"
    rm -f "$prod_raw"
  fi
  if [[ -n "$meta_raw" ]]; then
    _list_devices_append_parsed_mdns "$device_data" <"$meta_raw"
    rm -f "$meta_raw"
  fi
  if [[ -n "$boot_raw" ]]; then
    _list_devices_append_parsed_mdns "$device_data" <"$boot_raw"
    rm -f "$boot_raw"
  fi
}

_LIST_DEVICES_LIVE_TIMEOUT_SEC=2
_BOOTSTRAP_WIFI_READY_TIMEOUT_SEC=10
# The XIAO ESP32-C6 USB-Serial/JTAG auto-reset is unreliable: a single software
# reset boots the freshly written app only ~half the time. On timeout, re-issue
# the reset and re-check this many times before asking for a manual RESET. The
# attempts are ~independent, so 10 retries (11 total tries) put the "needs a
# manual RESET" probability well under 1% -- 0.5^11 ~= 0.05%, and even at 40%
# per-try odds 0.6^11 ~= 0.36%.
_BOOTSTRAP_REBOOT_RETRIES=10
_BOOTSTRAP_REBOOT_RETRY_TIMEOUT_SEC=15
_BOOTSTRAP_MANUAL_RESET_TIMEOUT_SEC=60

_list_devices_bootstrap_live() {
  # Probe bootstrap OTA (3232) and API (6053) concurrently; either port means alive.
  local hostname="$1"
  local timeout_sec="$2"
  local pid_ota pid_api rc_ota=1 rc_api=1

  _iotstack_tcp_open "$hostname" 3232 "$timeout_sec" &
  pid_ota=$!
  _iotstack_tcp_open "$hostname" 6053 "$timeout_sec" &
  pid_api=$!
  wait "$pid_ota" && rc_ota=0 || true
  wait "$pid_api" && rc_api=0 || true
  [[ $rc_ota -eq 0 || $rc_api -eq 0 ]]
}

_list_devices_host_live() {
  # Return 0 when hostname.local accepts the firmware's service port right now.
  # Filters stale avahi-daemon cache entries (offline devices can linger in mDNS).
  local hostname="$1"
  local bootstrap_prefix
  bootstrap_prefix="$(iotstack_bootstrap_role)-"
  if [[ "$hostname" == "${bootstrap_prefix}"* ]]; then
    _list_devices_bootstrap_live "$hostname" "$_LIST_DEVICES_LIVE_TIMEOUT_SEC"
    return $?
  fi
  _production_api_reachable "$hostname" "$_LIST_DEVICES_LIVE_TIMEOUT_SEC"
}

_list_devices_filter_live_hosts() {
  # Keep only mDNS rows whose host accepts a TCP probe (all hosts probed in parallel).
  local input="$1"
  local output="$2"
  local -a rows=() probe_pids=()
  local row pid rc

  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    rows+=("$row")
    _list_devices_host_live "${row%%|*}" &
    probe_pids+=("$!")
  done <"$input"

  : >"$output"
  local i=0
  for pid in "${probe_pids[@]}"; do
    row="${rows[$i]}"
    if wait "$pid"; then
      echo "$row" >>"$output"
    else
      debug "Skipping stale mDNS entry (no TCP response): ${row%%|*}"
    fi
    i=$((i + 1))
  done
}

_list_devices_row_matches_filter() {
  # Return 0 when a discovered row should be listed.
  # device_mode: all | production | bootstrap
  # In all mode, bootstrap-<mac> hosts are included unless the same MAC suffix
  # is already on production (suppresses stale bootstrap mDNS cache entries).
  local hostname="$1"
  local project="$2"
  local filter_role="$3"
  local device_mode="$4"
  local -n production_macs_ref="$5"
  local bootstrap_prefix role matches_role mac

  bootstrap_prefix="$(iotstack_bootstrap_role)-"
  if [[ "$hostname" == "${bootstrap_prefix}"* ]]; then
    case "$device_mode" in
      production) return 1 ;;
      bootstrap) return 0 ;;
      all)
        mac="${hostname##*-}"
        [[ -n "${production_macs_ref[$mac]:-}" ]] && return 1
        return 0
        ;;
    esac
  elif [[ "$device_mode" == "bootstrap" ]]; then
    return 1
  fi
  [[ -z "$filter_role" ]] && return 0

  if [[ "$filter_role" == "other" ]]; then
    matches_role=false
    for role in $(list_device_names); do
      if [[ "$project" == *"$role"* ]]; then
        matches_role=true
        break
      fi
    done
    [[ "$matches_role" == true ]] && return 1
    return 0
  fi

  [[ "$project" == *"$filter_role"* ]]
}

list_devices() {
  local output_format="${1:-text}"
  local filter_role="${2:-}"
  local suffix_only="${3:-false}"
  local device_mode="${4:-all}"  # all | production | bootstrap

  # Gather device data into temp buffer
  local device_data
  device_data=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$device_data' '${device_data}.merged' '${device_data}.sorted' '${device_data}.live'" RETURN

  _list_devices_collect_mdns_parallel "$device_data" "$device_mode"

  # Merge supplemental _iotstack-meta rows and duplicate service records by MAC.
  _list_devices_merge_by_mac "$device_data" "${device_data}.merged"
  sort -u "${device_data}.merged" > "${device_data}.sorted"
  _list_devices_filter_live_hosts "${device_data}.sorted" "${device_data}.live"
  mv "${device_data}.live" "${device_data}.sorted"

  # MAC suffixes with a live production host (used to drop stale bootstrap mDNS).
  declare -A production_macs=()
  if [[ "$device_mode" == "all" ]]; then
    local prod_hostname
    while IFS='|' read -r prod_hostname _ _ _ _ _; do
      [[ "$prod_hostname" == "$(iotstack_bootstrap_role)-"* ]] && continue
      production_macs["${prod_hostname##*-}"]=1
    done < "${device_data}.sorted"
  fi

  # Try to get Home Assistant area info (only for production devices).
  # Normalize to a single JSON object: get_ha_device_areas can emit more than
  # one document (e.g. an empty "{}" plus a fallback "{}"), and a multi-doc
  # input makes the per-row `jq -r` lookups emit one line per document -- which
  # would put an embedded newline into the area value and break table rows.
  local ha_areas="{}"
  if [[ "$device_mode" != "bootstrap" ]] && [[ -s "${device_data}.sorted" ]]; then
    if get_ha_device_areas > /tmp/ha_areas.json 2>/dev/null; then
      ha_areas=$(jq -cs 'reduce .[] as $o ({}; . * $o)' /tmp/ha_areas.json 2>/dev/null || echo '{}')
      [[ -z "$ha_areas" ]] && ha_areas="{}"
    fi
  fi

  # If ID-only mode, output device IDs in requested format
  if [[ "$suffix_only" == "true" ]]; then
    if [[ "$output_format" == "csv" ]]; then
      echo "ID"
      while IFS='|' read -r hostname friendly project version _bs_hash _prod_hash; do
        _list_devices_row_matches_filter "$hostname" "$project" "$filter_role" "$device_mode" production_macs || continue
        suffix="${hostname##*-}"
        echo "$suffix"
      done < "${device_data}.sorted" | sort -u
    elif [[ "$output_format" == "json" ]]; then
      local -a id_suffixes=()
      while IFS='|' read -r hostname friendly project version _bs_hash _prod_hash; do
        _list_devices_row_matches_filter "$hostname" "$project" "$filter_role" "$device_mode" production_macs || continue
        id_suffixes+=("${hostname##*-}")
      done < "${device_data}.sorted"
      if ((${#id_suffixes[@]} > 0)); then
        mapfile -t id_suffixes < <(printf '%s\n' "${id_suffixes[@]}" | sort -u)
      fi
      (
        echo "["
        first=true
        for suffix in "${id_suffixes[@]}"; do
          [[ "$first" != true ]] && echo ","
          printf '  "%s"' "$suffix"
          first=false
        done
        echo
        echo "]"
      ) | _iotstack_format_json
    else
      # Text format: space-separated IDs
      local suffixes=()
      while IFS='|' read -r hostname friendly project version _bs_hash _prod_hash; do
        _list_devices_row_matches_filter "$hostname" "$project" "$filter_role" "$device_mode" production_macs || continue
        suffix="${hostname##*-}"
        suffixes+=("$suffix")
      done < "${device_data}.sorted"

      if [[ ${#suffixes[@]} -eq 0 ]]; then
        if [[ -n "$filter_role" ]]; then
          warn "No devices found for role: $filter_role"
        elif [[ "$device_mode" == "all" ]]; then
          warn "No production or bootstrap devices found on network"
        elif [[ "$device_mode" == "bootstrap" ]]; then
          warn "No bootstrap devices found on network"
        else
          warn "No ESPHome devices found on network"
        fi
      else
        printf '%s\n' "${suffixes[@]}" | sort -u | tr '\n' ' '
        echo
      fi
    fi
    return
  fi

  if [[ "$output_format" == "csv" ]]; then
    echo "ID,Device,Friendly Name,Project,Version,Bootstrap Image Hash,Production Image Hash,HA area"
    while IFS='|' read -r hostname friendly project version bootstrap_hash production_hash; do
      _list_devices_row_matches_filter "$hostname" "$project" "$filter_role" "$device_mode" production_macs || continue
      id="${hostname##*-}"
      # Try to get area from HA (match by full hostname or base name)
      area=$(echo "$ha_areas" | jq -r ".[\"$hostname\"] // .[\"$friendly\"] // \"-\"" 2>/dev/null)
      [[ -z "$area" ]] && area="-"
      [[ -z "$bootstrap_hash" ]] && bootstrap_hash="-"
      [[ -z "$production_hash" ]] && production_hash="-"
      echo "$id,$hostname,$friendly,$project,$version,$bootstrap_hash,$production_hash,$area"
    done < "${device_data}.sorted"
  elif [[ "$output_format" == "json" ]]; then
    while IFS='|' read -r hostname friendly project version bootstrap_hash production_hash; do
      _list_devices_row_matches_filter "$hostname" "$project" "$filter_role" "$device_mode" production_macs || continue
      id="${hostname##*-}"
      area=$(echo "$ha_areas" | jq -r ".[\"$hostname\"] // .[\"$friendly\"] // empty" 2>/dev/null)
      jq -nc \
        --arg id "$id" \
        --arg device "$hostname" \
        --arg friendly_name "$friendly" \
        --arg area "$area" \
        --arg project "$project" \
        --arg version "$version" \
        --arg bootstrap_image_hash "$bootstrap_hash" \
        --arg production_image_hash "$production_hash" \
        '{
          id: $id,
          device: $device,
          friendly_name: $friendly_name,
          project: $project,
          version: $version,
          bootstrap_image_hash: (if $bootstrap_image_hash == "" then null else $bootstrap_image_hash end),
          production_image_hash: (if $production_image_hash == "" then null else $production_image_hash end),
          ha_area: (if $area == "" then null else $area end)
        }'
    done < "${device_data}.sorted" | _iotstack_json_slurp
  else
    # Text format - calculate column widths (all left-aligned)
    local margin=2
    local header_id="ID"
    local header_device="Device"
    local header_friendly="Friendly Name"
    local header_area="HA area"
    local header_project="Project"
    local header_version="Version"
    local header_bootstrap_hash="Bootstrap Image Hash"
    local header_production_hash="Production Image Hash"

    local w_id=$(( ${#header_id} + margin ))
    local w_device=$(( ${#header_device} + margin ))
    local w_friendly=$(( ${#header_friendly} + margin ))
    local w_area=$(( ${#header_area} + margin ))
    local w_project=$(( ${#header_project} + margin ))
    local w_version=$(( ${#header_version} + margin ))
    local w_bootstrap_hash=$(( ${#header_bootstrap_hash} + margin ))
    local w_production_hash=$(( ${#header_production_hash} + margin ))

    # Scan data to find max widths (filtered rows only) and whether any rows will print.
    local found=0
    while IFS='|' read -r hostname friendly project version bootstrap_hash production_hash; do
      _list_devices_row_matches_filter "$hostname" "$project" "$filter_role" "$device_mode" production_macs || continue
      found=$((found + 1))
      id="${hostname##*-}"
      area=$(echo "$ha_areas" | jq -r ".[\"$hostname\"] // .[\"$friendly\"] // \"-\"" 2>/dev/null)
      [[ -z "$area" ]] && area="-"
      [[ -z "$bootstrap_hash" ]] && bootstrap_hash="-"
      [[ -z "$production_hash" ]] && production_hash="-"
      (( ${#id} + margin > w_id )) && w_id=$(( ${#id} + margin ))
      (( ${#hostname} + margin > w_device )) && w_device=$(( ${#hostname} + margin ))
      (( ${#friendly} + margin > w_friendly )) && w_friendly=$(( ${#friendly} + margin ))
      (( ${#area} + margin > w_area )) && w_area=$(( ${#area} + margin ))
      (( ${#project} + margin > w_project )) && w_project=$(( ${#project} + margin ))
      (( ${#version} + margin > w_version )) && w_version=$(( ${#version} + margin ))
      (( ${#bootstrap_hash} + margin > w_bootstrap_hash )) && w_bootstrap_hash=$(( ${#bootstrap_hash} + margin ))
      (( ${#production_hash} + margin > w_production_hash )) && w_production_hash=$(( ${#production_hash} + margin ))
    done < "${device_data}.sorted"

    if [[ $found -eq 0 ]]; then
      if [[ -n "$filter_role" ]]; then
        warn "No devices found for role: $filter_role"
      elif [[ "$device_mode" == "all" ]]; then
        warn "No production or bootstrap devices found on network"
      elif [[ "$device_mode" == "bootstrap" ]]; then
        warn "No bootstrap devices found on network (devices booted to production are listed by: iotstack devices --production)"
      else
        warn "No ESPHome devices found on network"
      fi
    else
      if [[ "$device_mode" == "all" ]]; then
        info "Discovered ESPHome devices on network (production and bootstrap):"
      elif [[ "$device_mode" == "production" ]]; then
        info "Discovered ESPHome devices on network:"
      else
        info "Discovered bootstrap devices on network:"
      fi
      echo

      # Print headers with calculated widths (all left-aligned with %)
      printf "  ${GRN}%-${w_id}s %-${w_device}s %-${w_friendly}s %-${w_project}s %-${w_version}s %-${w_bootstrap_hash}s %-${w_production_hash}s %-${w_area}s${RST}\n" \
        "$header_id" "$header_device" "$header_friendly" "$header_project" "$header_version" \
        "$header_bootstrap_hash" "$header_production_hash" "$header_area"

      # Print separator
      _print_table_rule "$w_id" "$w_device" "$w_friendly" "$w_project" "$w_version" "$w_bootstrap_hash" "$w_production_hash" "$w_area"

      # Print data rows with calculated widths
      while IFS='|' read -r hostname friendly project version bootstrap_hash production_hash; do
        _list_devices_row_matches_filter "$hostname" "$project" "$filter_role" "$device_mode" production_macs || continue
        id="${hostname##*-}"
        # Try to get area from HA (match by full hostname or base name)
        area=$(echo "$ha_areas" | jq -r ".[\"$hostname\"] // .[\"$friendly\"] // \"-\"" 2>/dev/null)
        [[ -z "$area" ]] && area="-"
        [[ -z "$bootstrap_hash" ]] && bootstrap_hash="-"
        [[ -z "$production_hash" ]] && production_hash="-"
        printf "  ${GRN}%-${w_id}s${RST} %-${w_device}s %-${w_friendly}s %-${w_project}s %-${w_version}s %-${w_bootstrap_hash}s %-${w_production_hash}s %-${w_area}s\n" \
          "$id" "$hostname" "$friendly" "$project" "$version" "$bootstrap_hash" "$production_hash" "$area"
      done < "${device_data}.sorted"

      echo
      ok "Found $found device(s) on network"
    fi
  fi
}

list_yaml_configs() {
  local margin=2
  local header_device="Device"
  local header_type="Type"
  local header_network="Network"
  local header_config="Config File"

  local w_device=$(( ${#header_device} + margin ))
  local w_type=$(( ${#header_type} + margin ))
  local w_network=$(( ${#header_network} + margin ))
  local w_config=$(( ${#header_config} + margin ))

  # Scan YAML files to calculate widths
  while IFS= read -r yaml_file; do
    if grep -q '^esphome:' "$yaml_file" 2>/dev/null; then
      friendly_name=$(grep -E "^\s*friendly_name:\s*" "$yaml_file" | head -1 | sed 's/.*friendly_name:\s*"\?\([^"]*\)"\?.*/\1/')
      [[ -z "$friendly_name" ]] && friendly_name=$(basename "$yaml_file" .yaml)

      device_info=$(get_yaml_device_info "$yaml_file")
      device_type="${device_info%%|*}"
      network_type="${device_info##*|}"

      (( ${#friendly_name} + margin > w_device )) && w_device=$(( ${#friendly_name} + margin ))
      (( ${#device_type} + margin > w_type )) && w_type=$(( ${#device_type} + margin ))
      (( ${#network_type} + margin > w_network )) && w_network=$(( ${#network_type} + margin ))
      (( ${#yaml_file} + margin > w_config )) && w_config=$(( ${#yaml_file} + margin ))
    fi
  done < <(find "${SCRIPT_DIR}/yamls" -maxdepth 1 -name "*.yaml" -type f | sort)

  info "Available device configurations:"
  echo

  # Print headers
  printf "  ${GRN}%-${w_device}s %-${w_type}s %-${w_network}s %-${w_config}s${RST}\n" \
    "$header_device" "$header_type" "$header_network" "$header_config"

  # Print separator
  _print_table_rule "$w_device" "$w_type" "$w_network" "$w_config"

  # Print data rows
  local found=0
  while IFS= read -r yaml_file; do
    if grep -q '^esphome:' "$yaml_file" 2>/dev/null; then
      friendly_name=$(grep -E "^\s*friendly_name:\s*" "$yaml_file" | head -1 | sed 's/.*friendly_name:\s*"\?\([^"]*\)"\?.*/\1/')
      [[ -z "$friendly_name" ]] && friendly_name=$(basename "$yaml_file" .yaml)

      device_info=$(get_yaml_device_info "$yaml_file")
      device_type="${device_info%%|*}"
      network_type="${device_info##*|}"

      printf "  ${GRN}%-${w_device}s${RST} %-${w_type}s %-${w_network}s %-${w_config}s\n" \
        "$friendly_name" "$device_type" "$network_type" "$yaml_file"
      found=$((found + 1))
    fi
  done < <(find "${SCRIPT_DIR}/yamls" -maxdepth 1 -name "*.yaml" -type f | sort)

  if [[ $found -eq 0 ]]; then
    warn "No device configurations found"
  else
    echo
    ok "Found $found device configuration(s)"
  fi
}

# -- Bootstrap-mediated production updates -------------------------------------

_wait_for_device() {
  # Wait for an mDNS device name (e.g. bootstrap-1a7cfc) to appear, up to timeout
  # seconds. Returns 0 if found, 1 on timeout.
  local name="$1"
  local timeout="${2:-60}"
  local waited=0
  # Bootstrap devices advertise _iotstack-bootstrap._tcp; production uses _esphomelib._tcp
  local mdns_svc="_esphomelib._tcp"
  [[ "$name" == "$(iotstack_bootstrap_role)-"* ]] && mdns_svc="$(iotstack_bootstrap_mdns_service)"
  while (( waited < timeout )); do
    if [[ "$name" == "$(iotstack_bootstrap_role)-"* ]] && _iotstack_ota_tcp_open "$name" 3232; then
      return 0
    fi
    if avahi-browse -t -r "$mdns_svc" 2>/dev/null | grep -Fqi "$name"; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
    (( waited % 20 == 0 )) && info "  ...still waiting for $name ($waited/${timeout}s)"
  done
  return 1
}

_find_production_hostname_for_mac() {
  # Return the production mDNS hostname (e.g. bleproxy-1a7cfc) for a MAC suffix.
  local mac="$1"
  local line hostname
  while IFS= read -r line; do
    [[ "$line" =~ ^=\  ]] || continue
    hostname=$(awk '{print $4}' <<< "$line" | cut -d'.' -f1)
    if [[ "$hostname" =~ -${mac}$ ]] && [[ "$hostname" != "$(iotstack_bootstrap_role)-"* ]]; then
      echo "$hostname"
      return 0
    fi
  done < <(avahi-browse -t -r _esphomelib._tcp 2>/dev/null)
  return 1
}

_device_on_bootstrap() {
  local mac="$1"
  avahi-browse -t -r "$(iotstack_bootstrap_mdns_service)" 2>/dev/null | grep -Fqi "$(iotstack_bootstrap_hostname "$mac")"
}

_bootstrap_device_ota_password() {
  # NVS stores sha256(bootstrap_role_secret | mac) -- used for OTA from bootstrap.
  local mac="$1"
  local fs_secret
  fs_secret=$(iotstack_bootstrap_pass_ota_read) || return 1
  echo -n "${fs_secret}|${mac}" | sha256sum | cut -c1-32
}

_wait_for_ota_service() {
  # Wait for ESPHome OTA (port 3232) on a device hostname.
  local hostname="$1"
  local max_wait="${2:-90}"
  local waited=0
  local probe_timeout=3 poll_sleep=3 progress_interval=15
  if (( max_wait <= _BOOTSTRAP_WIFI_READY_TIMEOUT_SEC )); then
    probe_timeout=2
    poll_sleep=1
    progress_interval=5
  fi
  while (( waited < max_wait )); do
    if _iotstack_tcp_open "$hostname" 3232 "$probe_timeout"; then
      return 0
    fi
    sleep "$poll_sleep"
    waited=$((waited + poll_sleep))
    (( waited > 0 && waited % progress_interval == 0 )) \
      && info "  ...still waiting for ${hostname} OTA service ($waited/${max_wait}s)"
  done
  return 1
}

_iotstack_tcp_open() {
  # Return 0 when hostname.local accepts TCP on port within timeout_sec.
  # Prefer wait-for-it (quiet, reliable connect probe); fall back to bash /dev/tcp.
  local hostname="$1"
  local port="$2"
  local timeout_sec="${3:-3}"
  local hostport="${hostname}.local:${port}"

  if command -v wait-for-it &>/dev/null; then
    wait-for-it "$hostport" -t "$timeout_sec" -q
    return $?
  fi
  timeout "$timeout_sec" bash -c "echo > /dev/tcp/${hostname}.local/${port}" 2>/dev/null
}

_iotstack_ota_tcp_open() {
  _iotstack_tcp_open "$1" "$2" "${3:-3}"
}

_bootstrap_ota_reachable() {
  # Bootstrap firmware advertises bootstrap-<mac> with OTA on 3232.
  local device_mac="$1"
  _iotstack_ota_tcp_open "$(iotstack_bootstrap_hostname "$device_mac")" 3232
}

_flash_production_firmware_current() {
  # Return 0 when production partition on serial matches the compiled build.
  local tty_device="$1"
  local yaml_path="$2"
  local build_name build_dir production_offset chip

  build_name=$(basename "$yaml_path" .yaml)
  build_dir="${YAMLS_DIR}/.esphome/build/${build_name}/.pioenvs/${build_name}"
  production_offset=$(flash_partition_offset production 2>/dev/null) || return 1
  [[ -n "$production_offset" && -d "$build_dir" ]] || return 1
  chip=$(esp_detect_chip "$tty_device" 2>/dev/null) || return 1
  flash_production_matches_device "$tty_device" "$chip" "$build_dir" "$production_offset"
}

_flash_invoke_update() {
  # Production partition update: delegate to iotstack update flow (_update_via_bootstrap).
  # Usage: _flash_invoke_update <mac_suffix> <yaml_path> <device_role> [tty_device]
  local device_mac="$1"
  local yaml_path="$2"
  local device_role="$3"
  local tty_device="${4:-}"
  declare -a update_args=(--upgrade-delta)

  [[ -n "$tty_device" ]] && update_args+=("$tty_device")

  _flash_msg_ota_production "$device_mac" "$device_role"
  create_log_serial_relabel "$device_role"
  _update_via_bootstrap "$device_role" "$yaml_path" "$device_mac" -- "${update_args[@]}"
}

_wait_for_production_online() {
  # Wait for production firmware after OTA from bootstrap.
  # Production images omit ota: (no port 3232). Detect the role hostname via API
  # (6053) and/or _esphomelib._tcp mDNS -- not the bootstrap IP/OTA port.
  local hostname="$1"
  local max_wait="${2:-90}"
  local waited=0
  while (( waited < max_wait )); do
    if timeout 3 bash -c "echo > /dev/tcp/${hostname}.local/6053" 2>/dev/null; then
      return 0
    fi
    if avahi-browse -t -r _esphomelib._tcp 2>/dev/null | grep -Fqi "$hostname"; then
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
    (( waited % 15 == 0 )) && info "  Still rebooting... ($waited/${max_wait}s)"
  done
  return 1
}

_mdns_config_hash_for_hostname() {
  # ESPHome config_hash from mDNS TXT (same value shown in iotstack devices --production / --bootstrap).
  # Production: _esphomelib._tcp; bootstrap recovery: _iotstack-bootstrap._tcp.
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

_flash_production_matches_build() {
  # Return 0 when on-device production firmware matches the local build.
  # Default: mDNS config_hash (fast, same as iotstack devices --production).
  # --on-flash-verify: full USB read-flash MD5 of the production partition.
  local prod_hostname="$1"
  local yaml_path="$2"
  local tty_device="${3:-}"

  [[ "${FLASH_ERASE:-0}" == "1" ]] && return 1

  if [[ "${FLASH_ON_FLASH_VERIFY:-0}" == "1" ]]; then
    [[ -n "$tty_device" ]] && _flash_production_firmware_current "$tty_device" "$yaml_path"
    return $?
  fi

  local mdns_hash build_hash
  mdns_hash=$(_mdns_config_hash_for_hostname "$prod_hostname" 2>/dev/null) || return 1
  build_hash=$(_build_image_hash_for_yaml "$yaml_path" 2>/dev/null) || return 1
  [[ -n "$mdns_hash" && -n "$build_hash" && "$mdns_hash" == "$build_hash" ]]
}

_flash_production_partition_paths() {
  # Set reply vars for production build artifacts: build_dir, firmware_file, production_offset.
  local yaml_path="$1"
  local build_name
  build_name=$(basename "$yaml_path" .yaml)
  _FLASH_PROD_BUILD_DIR="${YAMLS_DIR}/.esphome/build/${build_name}/.pioenvs/${build_name}"
  _FLASH_PROD_FIRMWARE="${_FLASH_PROD_BUILD_DIR}/firmware.bin"
  _FLASH_PROD_OFFSET=$(flash_partition_offset production 2>/dev/null) || _FLASH_PROD_OFFSET=""
  if [[ -n "$_FLASH_PROD_OFFSET" ]]; then
    local _part_csv
    _part_csv=$(flash_partition_table_csv_for_device 2>/dev/null) || true
    [[ "$_part_csv" == *"/build/bootstrap/partitions.csv" ]] \
      && debug "On-flash production offset ${_FLASH_PROD_OFFSET} (from bootstrap build partition table)"
  fi
}

_flash_read_production_partition_md5() {
  # Full MD5 of the production partition on serial flash (one esptool read-flash).
  local tty_device="$1"
  local yaml_path="$2"
  local chip firmware_file file_size
  _flash_production_partition_paths "$yaml_path"
  firmware_file="$_FLASH_PROD_FIRMWARE"
  [[ -f "$firmware_file" && -n "$_FLASH_PROD_OFFSET" ]] || return 1
  chip=$(esp_detect_chip "$tty_device" 2>/dev/null) || return 1
  file_size=$(stat -c%s "$firmware_file" 2>/dev/null) || return 1
  flash_read_region_md5 "$tty_device" "$chip" "$_FLASH_PROD_OFFSET" "$file_size"
}

_flash_production_image_hash_on_device() {
  # First 8 hex chars of the production-partition MD5 read from serial flash.
  local md5
  md5=$(_flash_read_production_partition_md5 "$1" "$2") || return 1
  echo "${md5:0:8}"
}

_flash_bootstrap_image_hash_on_device() {
  # First 8 hex chars of the bootstrap-partition MD5 read from serial flash.
  local tty_device="$1"
  local build_dir="${YAMLS_DIR}/.esphome/build/$(iotstack_bootstrap_role)/.pioenvs/$(iotstack_bootstrap_role)"
  local firmware_file="${build_dir}/firmware.bin"
  local bootstrap_offset chip file_size md5
  bootstrap_offset=$(flash_partition_offset bootstrap 2>/dev/null) || bootstrap_offset=""
  [[ -f "$firmware_file" && -n "$bootstrap_offset" ]] || return 1
  chip=$(esp_detect_chip "$tty_device" 2>/dev/null) || return 1
  file_size=$(stat -c%s "$firmware_file" 2>/dev/null) || return 1
  md5=$(flash_read_region_md5 "$tty_device" "$chip" "$bootstrap_offset" "$file_size") || return 1
  echo "${md5:0:8}"
}

_production_running_image_hash() {
  # Prefer live mDNS config_hash; fall back to on-flash MD5 prefix from serial.
  local prod_hostname="$1"
  local tty_device="${2:-}"
  local yaml_path="${3:-}"
  local hash
  hash=$(_mdns_config_hash_for_hostname "$prod_hostname" 2>/dev/null) || true
  [[ -n "$hash" ]] && { echo "$hash"; return 0; }
  if [[ -n "$tty_device" && -n "$yaml_path" ]]; then
    hash=$(_flash_production_image_hash_on_device "$tty_device" "$yaml_path" 2>/dev/null) || true
    [[ -n "$hash" ]] && { echo "$hash"; return 0; }
  fi
  echo "unknown"
}

_production_api_reachable() {
  # Production native API accepts TCP on 6053.
  _iotstack_tcp_open "$1" 6053 "${2:-3}"
}

_production_mdns_advertised() {
  local hostname="$1"
  avahi-browse -t -r _esphomelib._tcp 2>/dev/null | grep -Fqi "$hostname"
}

_production_reachable_now() {
  # Quick probe (no wait loop) -- API preferred; mDNS alone is weaker signal.
  local hostname="$1"
  _production_api_reachable "$hostname" || _production_mdns_advertised "$hostname"
}

_build_image_hash_for_yaml() {
  # image_hash for comparing device mDNS against the compiled build (8-char hex).
  local yaml_path="$1"
  local yaml_name cache_file hash latest_log
  yaml_name=$(basename "$yaml_path" .yaml)
  hash=$(_config_hash_from_build_dir "$yaml_name" 2>/dev/null) || true
  [[ -n "$hash" ]] && { echo "$hash"; return 0; }
  cache_file="${HOME}/.iotstack/logs/${yaml_name}/${yaml_name}.build.cache"
  if [[ -f "$cache_file" ]]; then
    hash=$(grep '^config_hash=' "$cache_file" 2>/dev/null | cut -d= -f2-)
    [[ -n "$hash" ]] && { echo "$hash"; return 0; }
  fi
  latest_log=$(ls -t "${HOME}/.iotstack/logs/${yaml_name}/"*.compile.log 2>/dev/null | head -1) || true
  if [[ -n "$latest_log" && -f "$latest_log" ]]; then
    hash=$(grep -oE 'config_hash=0x[0-9a-f]+' "$latest_log" 2>/dev/null | tail -1 | sed 's/config_hash=0x//')
    [[ -n "$hash" ]] && echo "$hash"
  fi
}

# Set by _flash_report_device_assessment for _flash_production_smart branching.
FLASH_ASSESS_PROD_ONLINE=0
FLASH_ASSESS_PROD_MDNS=0
FLASH_ASSESS_BOOTSTRAP_ONLINE=0
FLASH_ASSESS_FLASH_CURRENT=0
IOTSTACK_NVS_PROVISIONED_VIA_USB=0

_flash_assess_device_runtime() {
  # Quick WiFi/runtime probe (no compile). Sets FLASH_ASSESS_PROD_ONLINE / BOOTSTRAP_ONLINE.
  local device_mac="$1"
  local prod_hostname="$2"
  local tty_device="${3:-}"
  local max_retry="${4:-12}"
  local waited=0 bootstrap_hash bootstrap_hostname

  FLASH_ASSESS_PROD_ONLINE=0
  FLASH_ASSESS_PROD_MDNS=0
  FLASH_ASSESS_BOOTSTRAP_ONLINE=0

  while true; do
    if _production_api_reachable "$prod_hostname"; then
      FLASH_ASSESS_PROD_ONLINE=1
      break
    fi
    if _bootstrap_ota_reachable "$device_mac"; then
      FLASH_ASSESS_BOOTSTRAP_ONLINE=1
      break
    fi
    if (( waited >= max_retry )); then
      if _production_mdns_advertised "$prod_hostname"; then
        FLASH_ASSESS_PROD_MDNS=1
      fi
      break
    fi
    sleep 3
    waited=$((waited + 3))
  done

  info "MAC suffix: ${device_mac}"
  bootstrap_hostname="$(iotstack_bootstrap_hostname "$device_mac")"
  if [[ "${FLASH_ON_FLASH_VERIFY:-0}" == "1" && -n "$tty_device" ]]; then
    info "Reading on-flash bootstrap partition via USB..."
    bootstrap_hash=$(_flash_bootstrap_image_hash_on_device "$tty_device" 2>/dev/null) || bootstrap_hash="unknown"
    info "On-flash bootstrap: ${bootstrap_hostname} (image hash ${bootstrap_hash})"
  elif [[ $FLASH_ASSESS_BOOTSTRAP_ONLINE -eq 1 ]]; then
    bootstrap_hash=$(_mdns_config_hash_for_hostname "$bootstrap_hostname" "$(iotstack_bootstrap_mdns_service)" 2>/dev/null) \
      || bootstrap_hash="unknown"
    info "Runtime bootstrap: ${bootstrap_hostname} (config_hash ${bootstrap_hash})"
  fi
  if [[ $FLASH_ASSESS_PROD_ONLINE -eq 1 ]]; then
    local running_hash
    running_hash=$(_mdns_config_hash_for_hostname "$prod_hostname" 2>/dev/null) || running_hash="unknown"
    info "Device is running production image ${prod_hostname} with config_hash=${running_hash}"
    info "Production API is online"
  elif [[ $FLASH_ASSESS_PROD_MDNS -eq 1 ]]; then
    local mdns_only_hash
    mdns_only_hash=$(_mdns_config_hash_for_hostname "$prod_hostname" 2>/dev/null) || mdns_only_hash="unknown"
    info "Runtime: production on mDNS only (${prod_hostname}, config_hash ${mdns_only_hash}, API port 6053 not reachable)"
  elif [[ $FLASH_ASSESS_BOOTSTRAP_ONLINE -eq 1 ]]; then
    info "Runtime: bootstrap online ($(iotstack_bootstrap_hostname "$device_mac"), OTA port 3232)"
  else
    info "Runtime: not reachable on WiFi (no production or bootstrap mDNS/API)"
  fi
}

_flash_assess_device_on_flash_action() {
  # On-flash compare + recommended action (requires compiled build artifacts).
  local tty_device="$1"
  local yaml_path="$2"
  local device_mac="$3"
  local prod_hostname="$4"
  local running_hash build_hash mdns_hash device_md5 local_md5 local_image_hash firmware_file
  local assess_role="${prod_hostname%-${device_mac}}"

  FLASH_ASSESS_FLASH_CURRENT=0
  mdns_hash=$(_mdns_config_hash_for_hostname "$prod_hostname" 2>/dev/null) || true
  running_hash="unknown"
  local_image_hash=""

  _flash_production_partition_paths "$yaml_path"
  firmware_file="$_FLASH_PROD_FIRMWARE"
  if [[ -f "$firmware_file" ]]; then
    local_md5=$(flash_file_md5 "$firmware_file") || true
    [[ -n "$local_md5" ]] && local_image_hash="${local_md5:0:8}"
  fi

  if [[ "${FLASH_ON_FLASH_VERIFY:-0}" == "1" ]]; then
    if [[ -f "$firmware_file" && -n "$_FLASH_PROD_OFFSET" ]]; then
      info "Reading on-flash production partition via USB (offset ${_FLASH_PROD_OFFSET})..."
      device_md5=$(_flash_read_production_partition_md5 "$tty_device" "$yaml_path" 2>/dev/null) || device_md5=""
      if [[ -n "$device_md5" ]]; then
        running_hash="${device_md5:0:8}"
        if [[ "${FLASH_ERASE:-0}" != "1" && -n "$local_md5" && "$local_md5" == "$device_md5" ]]; then
          FLASH_ASSESS_FLASH_CURRENT=1
        fi
      fi
    fi
  elif [[ "${FLASH_ERASE:-0}" != "1" ]] \
     && _flash_production_matches_build "$prod_hostname" "$yaml_path" "$tty_device"; then
    FLASH_ASSESS_FLASH_CURRENT=1
    running_hash="${mdns_hash:-unknown}"
  fi

  build_hash=$(_build_image_hash_for_yaml "$yaml_path" 2>/dev/null) || build_hash=""
  if [[ "${FLASH_ERASE:-0}" != "1" \
     && $FLASH_ASSESS_FLASH_CURRENT -eq 0 \
     && -n "$mdns_hash" && -n "$build_hash" && "$mdns_hash" == "$build_hash" ]]; then
    FLASH_ASSESS_FLASH_CURRENT=1
    running_hash="$mdns_hash"
  fi

  if [[ "${FLASH_ERASE:-0}" == "1" ]]; then
    if [[ -n "$mdns_hash" && -n "$build_hash" && "$mdns_hash" == "$build_hash" ]]; then
      info "Production: matches build (config_hash ${mdns_hash}) -- --erase will wipe and reflash"
    else
      info "Production: --erase will wipe and reflash"
    fi
  elif [[ $FLASH_ASSESS_FLASH_CURRENT -eq 1 ]]; then
    if [[ "${FLASH_ON_FLASH_VERIFY:-0}" == "1" ]]; then
      if [[ -n "$build_hash" ]]; then
        info "On-flash production: matches build (image ${running_hash}, config_hash ${build_hash})"
      else
        info "On-flash production: matches build (image ${running_hash})"
      fi
    elif [[ -n "$mdns_hash" && -n "$build_hash" ]]; then
      info "Production: matches build (config_hash ${mdns_hash})"
    else
      info "Production: matches build"
    fi
  elif [[ "${FLASH_ON_FLASH_VERIFY:-0}" == "1" && -n "$local_image_hash" && "$running_hash" != "unknown" ]]; then
    if [[ -n "$mdns_hash" && "$mdns_hash" == "$build_hash" ]]; then
      info "On-flash production: image ${running_hash} != build image ${local_image_hash} (runtime config_hash ${mdns_hash} matches build)"
    else
      info "On-flash production: image ${running_hash} != build image ${local_image_hash} (config_hash ${build_hash:-unknown})"
    fi
  elif [[ -n "$mdns_hash" && -n "$build_hash" ]]; then
    info "Production: runtime config_hash ${mdns_hash} != build config_hash ${build_hash}"
  elif [[ -n "$build_hash" ]]; then
    info "Production: differs from build (config_hash ${build_hash}; runtime hash unavailable)"
  else
    info "Production: differs from build"
  fi

  if [[ "${FLASH_ERASE:-0}" == "1" && $FLASH_ASSESS_PROD_ONLINE -eq 1 ]]; then
    info "Action: erase flash (due to --erase), then install bootstrap via USB, then ${assess_role} via OTA."
  elif [[ $FLASH_ASSESS_FLASH_CURRENT -eq 1 && $FLASH_ASSESS_PROD_ONLINE -eq 1 ]]; then
    local want_cols want_rows want_w want_h cur_cols cur_rows cur_w cur_h
    if _flash_matrix_layout_applicable "$assess_role" ""; then
      _flash_resolve_matrix_layout "$assess_role" want_cols want_rows want_w want_h
      if _flash_read_matrix_layout_from_device "$prod_hostname" "$device_mac" "$assess_role" \
          cur_cols cur_rows cur_w cur_h; then
        info "Matrix layout (runtime): ${cur_cols}x${cur_rows} panel(s), ${cur_w}x${cur_h} px"
        if [[ "$cur_cols" != "$want_cols" || "$cur_rows" != "$want_rows" || "$cur_w" != "$want_w" || "$cur_h" != "$want_h" ]]; then
          info "Matrix layout (target): ${want_cols}x${want_rows} panel(s), ${want_w}x${want_h} px"
          info "Action: update matrix layout on device (firmware is current)"
        else
          info "Action: none required -- device is current"
        fi
      elif _flash_matrix_layout_flags_set; then
        info "Matrix layout (target): ${want_cols}x${want_rows} panel(s), ${want_w}x${want_h} px"
        info "Action: update matrix layout on device (firmware is current)"
      else
        info "Action: none required -- device is current"
      fi
    else
      info "Action: none required -- device is current"
    fi
  elif [[ $FLASH_ASSESS_PROD_ONLINE -eq 1 ]]; then
    info "Action: reboot into bootstrap to perform update of production partition"
  elif [[ $FLASH_ASSESS_PROD_MDNS -eq 1 ]]; then
    info "Action: serial bootstrap path (mDNS visible, API unreachable), then OTA production image"
  elif [[ $FLASH_ASSESS_BOOTSTRAP_ONLINE -eq 1 ]]; then
    info "Action: refresh bootstrap on serial if needed, then OTA production image"
  else
    info "Action: flash bootstrap via serial, then OTA production image"
  fi
}

_flash_report_device_assessment() {
  # Full assessment (runtime + on-flash/action). Used when state may have changed mid-flow.
  local tty_device="$1"
  local yaml_path="$2"
  local device_mac="$3"
  local prod_hostname="$4"

  _flash_assess_device_runtime "$device_mac" "$prod_hostname" "$tty_device" 0
  _flash_assess_device_on_flash_action "$tty_device" "$yaml_path" "$device_mac" "$prod_hostname"
}

_yaml_device_role() {
  local yaml_file="$1"
  local role
  role=$(grep -E '^\s*device_role:\s*' "$yaml_file" | head -1 | sed -E 's/^\s*device_role:\s*"?([^"]*)"?/\1/')
  if [[ -n "$role" ]]; then
    echo "$role"
  else
    basename "$yaml_file" .yaml
  fi
}

_update_args_include_dry_run() {
  local arg
  for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && return 0
  done
  return 1
}

_ensure_device_on_bootstrap() {
  # Switch a production device into bootstrap and wait for its OTA service.
  local mac="$1"
  local is_dry_run="${2:-false}"
  local tty_device="${3:-}"
  local production_role="${4:-}"
  local switch_failed=false
  local wait_timeout=90
  if [[ "$is_dry_run" == true ]]; then
    return 0
  fi

  if _bootstrap_ota_reachable "$mac" || _device_on_bootstrap "$mac"; then
    info "[$mac] already on bootstrap"
  else
    local production_hostname
    production_hostname=$(_find_production_hostname_for_mac "$mac" || true)
    if [[ -n "$production_hostname" ]]; then
      if _production_api_reachable "$production_hostname"; then
        info "[$mac] 1/4 switching $production_hostname to bootstrap..."
        local attempt
        for attempt in 1 2 3; do
          if _call_production_api_service "$production_hostname" "$mac" switch_to_bootstrap "$tty_device"; then
            switch_failed=false
            break
          fi
          switch_failed=true
          (( attempt < 3 )) && sleep 5
        done
        [[ "$switch_failed" == true ]] && warn "[$mac] switch_to_bootstrap failed after 3 attempts"
      else
        switch_failed=true
        warn "[$mac] production API unreachable -- cannot call switch_to_bootstrap"
      fi
    else
      switch_failed=true
      warn "[$mac] not found in production mDNS"
    fi
  fi

  if [[ "$switch_failed" == true ]]; then
    if [[ -n "$tty_device" ]]; then
      info "[$mac] USB serial fallback -- refreshing bootstrap firmware on ${tty_device}..."
      _flash_bootstrap_to_tty "$tty_device" "" "$production_role" || return 1
      switch_failed=false
    else
      # Nothing can move this device into bootstrap: it is not already there, the
      # production API switch did not happen (see the warning above), and no USB
      # port was given for a serial refresh. Waiting for bootstrap-$mac to appear
      # would just stall for the timeout and then fail, so fail fast instead.
      warn "[$mac] no path to bootstrap and no USB port given -- pass a /dev/tty* to force a serial bootstrap refresh"
      return 1
    fi
  fi

  info "[$mac] 2/4 waiting for bootstrap-$mac on the network..."
  if ! _wait_for_device "$(iotstack_bootstrap_hostname "$mac")" "$wait_timeout"; then
    if [[ -n "$tty_device" ]]; then
      warn "[$mac] bootstrap-$mac did not appear -- use USB serial fallback"
      _flash_warn_start_serial_logs "$tty_device"
    else
      warn "[$mac] bootstrap-$mac did not appear"
    fi
    return 1
  fi

  info "[$mac] 3/4 waiting for bootstrap OTA service..."
  if ! _wait_for_ota_service "$(iotstack_bootstrap_hostname "$mac")" 90; then
    warn "[$mac] bootstrap-$mac OTA service not reachable"
    _flash_warn_start_serial_logs "$tty_device"
    return 1
  fi
  sleep 2
  return 0
}

_bootstrap_update_nvs_device_role() {
  # Partial NVS update: device_role only (roles.conf name for USB auto-identify).
  local device_mac="$1"
  local role="$2"
  local json_vars

  json_vars=$(
    DEVICE_ROLE="$role" python3 - <<'PY'
import json, os
print(json.dumps({
    "wifi_ssid": "",
    "wifi_password": "",
    "ota_password": "",
    "api_key": "",
    "thread_tlv": "",
    "matrix_cols": "",
    "matrix_rows": "",
    "matrix_panel_w": "",
    "matrix_panel_h": "",
    "device_role": os.environ["DEVICE_ROLE"],
    "git_commit": "",
}))
PY
  ) || return 1
  _nvs_update_via_bootstrap_api "$device_mac" "$json_vars"
}

_resolve_flash_tty_for_role() {
  # Auto-pick USB tty for a roles.conf role (NVS device_role, else lone chip variant).
  local role="$1"
  local resolved="" expected_variant variant port
  local -a variant_ports=()

  # shellcheck source=scripts/esp-serial.sh
  source "${SCRIPT_DIR}/scripts/esp-serial.sh"
  # shellcheck source=scripts/yaml-info.sh
  source "${SCRIPT_DIR}/scripts/yaml-info.sh"

  if resolved=$(esp_tty_for_role "$role" 2>/dev/null); then
    info "Resolved role '$role' to $resolved (NVS device_role)"
    printf '%s\n' "$resolved"
    return 0
  fi

  expected_variant=$(yaml_variant_for_role "$role" 2>/dev/null) || expected_variant=""
  if [[ -n "$expected_variant" ]]; then
    while IFS= read -r port; do
      [[ -z "$port" ]] && continue
      variant=$(esp_detect_chip "$port" 2>/dev/null) || continue
      [[ "$variant" == "$expected_variant" ]] && variant_ports+=("$port")
    done < <(esp_serial_ports)
    if [[ ${#variant_ports[@]} -eq 1 ]]; then
      resolved="${variant_ports[0]}"
      info "Resolved role '$role' to $resolved (${expected_variant}; NVS device_role not set)"
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  return 1
}

_ota_via_bootstrap() {
  # OTA into the production slot via bootstrap (partition-safe path).
  # Usage: _ota_via_bootstrap <mac> <yaml_file> <ota_password> <post_ota_hostname> [tty_device] [update_args...]
  local mac="$1"
  local yaml_file="$2"
  local ota_password="$3"
  local post_ota_hostname="$4"
  shift 4
  local tty_device=""
  if [[ "${1:-}" == /dev/* ]]; then
    tty_device="$1"
    shift
  fi
  declare -a ota_update_args=("$@")

  local is_dry_run=false
  if _update_args_include_dry_run "${ota_update_args[@]}"; then
    is_dry_run=true
  fi

  local conf_role
  conf_role=$(basename "$yaml_file" .yaml)
  if ! _ensure_device_on_bootstrap "$mac" "$is_dry_run" "$tty_device" "$conf_role"; then
    return 1
  fi

  if [[ "$is_dry_run" != true ]]; then
    if _bootstrap_update_nvs_device_role "$mac" "$conf_role"; then
      debug "[$mac] NVS device_role set to $conf_role"
      # NVS update triggers safe_reboot() on bootstrap; wait for it to reconnect.
      local bs_host
      bs_host=$(iotstack_bootstrap_hostname "$mac")
      info "[$mac] Waiting for $bs_host to reconnect after NVS reboot..."
      if ! _wait_for_device "$bs_host" 60; then
        warn "[$mac] $bs_host did not reappear after NVS update reboot"
        return 1
      fi
      if ! _wait_for_ota_service "$bs_host" 30; then
        warn "[$mac] $bs_host OTA service not reachable after NVS reboot"
        return 1
      fi
    else
      debug "[$mac] NVS device_role not updated via API (may be set on next USB provision)"
    fi
  fi

  info "[$mac] 4/4 OTA into production slot..."
  declare -a _ota_args=()
  mapfile -t _ota_inherited < <(_update_devices_inherited_flags)
  [[ ${#_ota_inherited[@]} -gt 0 ]] && _ota_args+=("${_ota_inherited[@]}")
  _ota_args+=(--reassign "$mac" "$yaml_file" --ota-password "$ota_password" --jobs 1)
  _ota_args+=("${ota_update_args[@]}")
  if ! _run_update_devices "${_ota_args[@]}"; then
    warn "[$mac] OTA failed"
    return 1
  fi

  if [[ "$is_dry_run" != true && -n "$post_ota_hostname" ]]; then
    local network_type
    network_type=$(get_yaml_device_info "$yaml_file" | cut -d'|' -f3)
    if [[ "$network_type" == "thread" ]]; then
      ok "[$mac] OTA complete; Thread device rebooting as $post_ota_hostname (mesh, not WiFi mDNS)"
      # Thread devices never reappear on WiFi mDNS, so there is no
      # _wait_for_production_online gate here -- but HA registration still
      # applies (HA reaches the device over Thread via a border router), so
      # invoke it too. Honors PERFORM_HA_DEVICE_REGISTRATION like the WiFi path;
      # a no-op when HA is unconfigured and registration is not required.
      _ha_after_production_online "$yaml_file" "$post_ota_hostname"
    elif _wait_for_production_online "$post_ota_hostname" 90; then
      ok "[$mac] reassigned and back as $post_ota_hostname"
      _ha_after_production_online "$yaml_file" "$post_ota_hostname"
    else
      warn "[$mac] not seen as $post_ota_hostname yet (may still be booting)"
    fi
  fi
  return 0
}

_reassign_devices_via_bootstrap() {
  # Reassign one or more devices to a new role/YAML via the bootstrap partition.
  # Usage: _reassign_devices_via_bootstrap <yaml_file> <ota_password> <mac...> -- [update_args...]
  local yaml_file="$1"
  local ota_password="$2"
  shift 2
  local -a macs=()
  local -a ota_update_args=()
  local seen_sep=false
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
      seen_sep=true
      continue
    fi
    if [[ "$seen_sep" == true ]]; then
      ota_update_args+=("$arg")
    else
      macs+=("$arg")
    fi
  done

  if [[ ${#macs[@]} -eq 0 ]]; then
    err "No MAC suffixes provided for reassignment"
  fi

  if [[ -z "$ota_password" ]]; then
    if ! iotstack_bootstrap_pass_ota_read &>/dev/null; then
      err "Bootstrap role OTA password not found in pass (provision a device first)."
    fi
  fi

  local target_role
  target_role=$(_yaml_device_role "$yaml_file")

  info "Reassigning ${#macs[@]} device(s) to '$target_role' via bootstrap..."
  local failed=0 mac dev_pwd
  for mac in "${macs[@]}"; do
    echo ""
    dev_pwd="$ota_password"
    if [[ -z "$dev_pwd" ]]; then
      dev_pwd=$(_bootstrap_device_ota_password "$mac") || err "Could not derive bootstrap OTA password for $mac"
      echo "  OTA Password: (derived from bootstrap role secret)"
    fi
    if ! _ota_via_bootstrap "$mac" "$yaml_file" "$dev_pwd" "${target_role}-${mac}" "${ota_update_args[@]}"; then
      failed=$((failed + 1))
    fi
  done

  echo ""
  if [[ $failed -eq 0 ]]; then
    ok "All device(s) reassigned via bootstrap"
    return 0
  fi
  warn "$failed device(s) failed to reassign"
  return 1
}

_update_via_bootstrap() {
  # iotstack update core path: switch to bootstrap if needed, OTA into production slot.
  # OTA never overwrites the bootstrap partition. Used by cmd_update and iotstack flash.
  #
  # Usage: _update_via_bootstrap <role> <yaml_file> [mac ...] [-- <update_args...>]
  #   update_args may include --upgrade-delta, --jobs N, and /dev/tty* (USB fallback).
  #   Explicit MACs are used directly (device may be bootstrap-only during first flash).
  local role="$1"
  local yaml_file="$2"
  shift 2
  local -a want_macs=()
  local -a ota_update_args=()
  local tty_device=""
  local seen_sep=false
  local arg

  while [[ $# -gt 0 ]]; do
    arg="$1"
    if [[ "$arg" == "--" ]]; then
      seen_sep=true
      shift
      continue
    fi
    if [[ "$seen_sep" == true ]]; then
      if [[ "$arg" == /dev/* ]]; then
        tty_device="$arg"
        shift
        continue
      fi
      ota_update_args+=("$arg")
      if [[ "$arg" == "--jobs" ]]; then
        shift
        [[ $# -gt 0 ]] && ota_update_args+=("$1")
      fi
      shift
      continue
    fi
    if [[ "$arg" =~ ^[0-9a-fA-F]{6}$ ]]; then
      want_macs+=("${arg,,}")
    fi
    shift
  done

  local -a macs=()
  if [[ ${#want_macs[@]} -gt 0 ]]; then
    macs=("${want_macs[@]}")
  else
    local line
    while IFS= read -r line; do
      if [[ "$line" =~ ${role}-([0-9a-f]{6}) ]]; then
        macs+=("${BASH_REMATCH[1]}")
      fi
    done < <(avahi-browse -t -r _esphomelib._tcp 2>/dev/null)
    [[ ${#macs[@]} -gt 0 ]] && mapfile -t macs < <(printf '%s\n' "${macs[@]}" | sort -u)
  fi

  if [[ ${#macs[@]} -eq 0 ]]; then
    err "No '$role' device(s) to update."
  fi

  local fs_secret
  fs_secret=$(iotstack_bootstrap_pass_ota_read) \
    || err "Bootstrap role OTA password not found in pass (provision a device first)."

  info "iotstack update: ${#macs[@]} '$role' device(s) via bootstrap..."
  local failed=0 mac dev_pwd
  for mac in "${macs[@]}"; do
    echo ""
    dev_pwd=$(echo -n "${fs_secret}|${mac}" | sha256sum | cut -c1-32)
    if [[ -n "$tty_device" ]]; then
      _ota_via_bootstrap "$mac" "$yaml_file" "$dev_pwd" "${role}-${mac}" "$tty_device" "${ota_update_args[@]}" \
        || failed=$((failed + 1))
    elif ! _ota_via_bootstrap "$mac" "$yaml_file" "$dev_pwd" "${role}-${mac}" "${ota_update_args[@]}"; then
      failed=$((failed + 1))
    fi
  done

  echo ""
  if [[ $failed -eq 0 ]]; then
    ok "All '$role' device(s) updated via bootstrap"
  else
    warn "$failed '$role' device(s) failed to update"
    return 1
  fi
}

# -- Command Handlers ---------------------------------------------------------

cmd_update() {
  _iotstack_command_help_if_requested update "$@" && return 0

  local device_or_yaml=""
  local ota_password=""
  declare -a update_args=()
  declare -a mac_suffixes=()

  # Parse arguments - collect MACs (6-digit hex), options, and device name
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ota-password)
        ota_password="$2"
        shift 2
        ;;
      --dry-run|--jobs)
        update_args+=("$1")
        if [[ "$1" == "--jobs" ]]; then
          shift
          update_args+=("$1")
        fi
        shift
        ;;
      --erase)
        err "--erase is not valid for 'iotstack update'; use 'iotstack flash' to erase and reinstall from USB"
        exit 1
        ;;
      all)
        if [[ -z "$device_or_yaml" ]]; then
          device_or_yaml="all"
        fi
        shift
        ;;
      *)
        # Check if it's a MAC suffix (6 hex digits) or device name
        if [[ "$1" =~ ^[0-9a-fA-F]{6}$ ]]; then
          # It's a MAC suffix
          mac_suffixes+=("$1")
          shift
        elif [[ -z "$device_or_yaml" ]]; then
          # First non-MAC argument is the device/yaml
          device_or_yaml="$1"
          shift
        else
          # Unknown argument
          shift
        fi
        ;;
    esac
  done

  if [[ -z "$device_or_yaml" ]]; then
    help_update
    exit 1
  fi

  # Resolve device name to YAML if needed
  local yaml_file
  if [[ "$device_or_yaml" == "all" ]]; then
    yaml_file="all"
  elif [[ -f "$device_or_yaml" ]]; then
    # Already a file path
    yaml_file="$device_or_yaml"
  else
    # Try to resolve as device name
    yaml_file=$(resolve_device "$device_or_yaml")
  fi

  # Handle normal update mode
  if [[ "$yaml_file" == "all" ]]; then
    info "Updating all device configurations..."
    echo

    found=0
    failed=0
    # Parse roles from roles.conf (format: role=yamls/role.yaml)
    while IFS='=' read -r role yaml_path; do
      # Skip empty lines and comments
      [[ -z "$role" ]] && continue
      [[ "$role" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$yaml_path" ]] && continue

      # Resolve full path
      yaml="${SCRIPT_DIR}/$yaml_path"

      # Verify file exists and is valid ESPHome YAML
      if [[ -f "$yaml" ]] && grep -q '^esphome:' "$yaml" 2>/dev/null; then
        # Build update command with MACs and OTA password if specified
        declare -a cmd=()
        mapfile -t _inh < <(_update_devices_inherited_flags)
        [[ ${#_inh[@]} -gt 0 ]] && cmd+=("${_inh[@]}")
        cmd+=("${update_args[@]}")
        [[ -n "$ota_password" ]] && cmd+=("--ota-password" "$ota_password")
        [[ ${#mac_suffixes[@]} -gt 0 ]] && cmd+=("--macs" "${mac_suffixes[@]}")
        cmd+=("$yaml")

        if _run_update_devices "${cmd[@]}"; then
          found=$((found + 1))
        else
          failed=$((failed + 1))
        fi
        echo
      fi
    done < <(cat "$ROLES_CONF" 2>/dev/null || echo "")

    echo "------------------------------------------------------------"
    if [[ $failed -eq 0 ]]; then
      ok "Updated $found device configuration(s)"
    else
      warn "Updated $found configuration(s), $failed FAILED"
      return 1
    fi
  else
    # Single yaml file
    if [[ ! -f "$yaml_file" ]]; then
      err "File not found: $yaml_file"
    fi

    # For a known production role (not a raw yaml path, not the bootstrap role,
    # not a dry run), update via bootstrap so the OTA can never overwrite the
    # bootstrap image. Otherwise fall back to a direct OTA.
    local _dry_run=0 _arg
    for _arg in ${update_args[@]+"${update_args[@]}"}; do
      [[ "$_arg" == "--dry-run" ]] && _dry_run=1
    done
    if [[ $_dry_run -eq 0 && "$device_or_yaml" != "bootstrap" ]] && is_valid_role "$device_or_yaml"; then
      if [[ ${#mac_suffixes[@]} -gt 0 ]]; then
        _update_via_bootstrap "$device_or_yaml" "$yaml_file" "${mac_suffixes[@]}" -- "${update_args[@]}"
      else
        _update_via_bootstrap "$device_or_yaml" "$yaml_file" -- "${update_args[@]}"
      fi
      return $?
    fi

    # Build update command with OTA password and MACs if specified
    declare -a cmd=()
    mapfile -t _inh < <(_update_devices_inherited_flags)
    [[ ${#_inh[@]} -gt 0 ]] && cmd+=("${_inh[@]}")
    cmd+=("${update_args[@]}")
    [[ -n "$ota_password" ]] && cmd+=("--ota-password" "$ota_password")
    [[ ${#mac_suffixes[@]} -gt 0 ]] && cmd+=("--macs" "${mac_suffixes[@]}")
    cmd+=("$yaml_file")

    _run_update_devices "${cmd[@]}"
  fi
}

cmd_reassign() {
  _iotstack_command_help_if_requested reassign "$@" && return 0

  local api_key=""
  declare -a update_args=()
  declare -a positional_args=()

  # Separate options from positional arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ota-password)
        api_key="$2"
        shift 2
        ;;
      --dry-run)
        update_args+=("$1")
        shift
        ;;
      --jobs)
        update_args+=("$1" "$2")
        shift 2
        ;;
      --)
        shift
        positional_args+=("$@")
        break
        ;;
      -*)
        err "Unknown option: $1"
        ;;
      *)
        positional_args+=("$1")
        shift
        ;;
    esac
  done

  # Last positional is the target device/yaml, rest are MACs
  if [[ ${#positional_args[@]} -lt 2 ]]; then
    help_reassign
    exit 1
  fi

  local device_or_yaml="${positional_args[-1]}"
  declare -a reassign_macs=("${positional_args[@]:0:${#positional_args[@]}-1}")

  # Resolve device name to YAML if needed
  local yaml_file
  if [[ -f "$device_or_yaml" ]]; then
    yaml_file="$device_or_yaml"
  else
    yaml_file=$(resolve_device "$device_or_yaml")
  fi

  # Early sanity check: verify devices aren't already the target role
  local target_role
  if [[ -f "$device_or_yaml" ]]; then
    target_role=$(_yaml_device_role "$yaml_file")
  else
    target_role="$device_or_yaml"
  fi
  for mac in "${reassign_macs[@]}"; do
    local device_info
    device_info=$(avahi-browse -t -r _esphomelib._tcp 2>/dev/null | grep -i "$mac" | head -1)
    if [[ -n "$device_info" ]]; then
      local device_name
      device_name=$(echo "$device_info" | awk -F' ' '{print $4}' | cut -d'.' -f1)
      local current_role="${device_name%-"$mac"}"
      if [[ "$current_role" == "$target_role" ]]; then
        ok "Device $device_name is already assigned to $target_role -- no reassign needed."
        return 0
      fi
    fi
  done

  info "Reassigning devices..."
  echo "  MACs: ${reassign_macs[*]}"

  # Confirm before reassigning multiple devices
  confirm_multi_device ${#reassign_macs[@]} "$(printf '%s\n' "${reassign_macs[@]}")"

  if _update_args_include_dry_run "${update_args[@]}"; then
    info "Dry run: will compile target firmware (device need not be on bootstrap yet)"
  fi

  if [[ -n "$api_key" ]]; then
    echo "  OTA Password: (provided)"
  else
    echo "  OTA Password: (will derive from bootstrap role secret per device)"
  fi
  echo

  _reassign_devices_via_bootstrap "$yaml_file" "$api_key" "${reassign_macs[@]}" -- "${update_args[@]}"
}

cmd_verify() {
  _iotstack_command_help_if_requested verify "$@" && return 0

  local device_or_yaml=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      all)
        device_or_yaml="all"
        shift
        ;;
      *)
        if [[ -z "$device_or_yaml" ]]; then
          device_or_yaml="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$device_or_yaml" ]]; then
    help_verify
    exit 1
  fi

  # Resolve device name to YAML if needed
  local yaml_file
  if [[ "$device_or_yaml" == "all" ]]; then
    yaml_file="all"
  elif [[ -f "$device_or_yaml" ]]; then
    yaml_file="$device_or_yaml"
  else
    yaml_file=$(resolve_device "$device_or_yaml")
  fi

  if [[ "$yaml_file" == "all" ]]; then
    info "Verifying all device configurations..."
    echo

    found=0
    failed=0
    while IFS= read -r yaml; do
      if grep -q '^esphome:' "$yaml" 2>/dev/null; then
        echo "------------------------------------------------------------"
        info "Verifying: $yaml"
        echo "------------------------------------------------------------"
        declare -a _verify_cmd=()
        mapfile -t _verify_inh < <(_update_devices_inherited_flags)
        [[ ${#_verify_inh[@]} -gt 0 ]] && _verify_cmd+=("${_verify_inh[@]}")
        _verify_cmd+=(--verify "$yaml")
        if _run_update_devices "${_verify_cmd[@]}"; then
          found=$((found + 1))
        else
          failed=$((failed + 1))
        fi
        echo
      fi
    done < <(find . -maxdepth 3 -name "*.yaml" -type f | sort)

    echo "------------------------------------------------------------"
    if [[ $failed -eq 0 ]]; then
      ok "Verified $found device configuration(s)"
    else
      warn "Verified $found configuration(s), $failed FAILED"
      return 1
    fi
  else
    if [[ ! -f "$yaml_file" ]]; then
      err "File not found: $yaml_file"
    fi

    info "Verifying: $yaml_file"
    declare -a _verify_cmd=()
    mapfile -t _verify_inh < <(_update_devices_inherited_flags)
    [[ ${#_verify_inh[@]} -gt 0 ]] && _verify_cmd+=("${_verify_inh[@]}")
    _verify_cmd+=(--verify "$yaml_file")
    _run_update_devices "${_verify_cmd[@]}"
  fi
}

cmd_verify_flash() {
  if [[ "${1:-}" == "help" ]]; then
    help_verify_flash
    return 0
  fi

  local role="${1:-}"
  local tty="${2:-}"
  if [[ -z "$role" || -z "$tty" ]]; then
    help_verify_flash
    exit 1
  fi
  if [[ ! -e "$tty" ]]; then
    err "TTY device not found: $tty"
  fi

  local variant
  variant=$(yaml_variant_for_role "$role" 2>/dev/null) || variant=""
  if [[ -z "$variant" ]]; then
    variant=$(esp_detect_chip "$tty" 2>/dev/null) || variant=""
  fi
  case "$variant" in
    esp32c6) export ESP_VERIFY_CHIP=esp32c6 ;;
    esp32s3) export ESP_VERIFY_CHIP=esp32s3 ;;
  esac

  info "Verifying on-device flash checksums: ${role} @ ${tty}"
  if create_log_child_output_piped; then
    create_log_run "verify-flash.sh" bash "${SCRIPTS_DIR}/verify-flash.sh" "$tty" "$role"
    return $?
  fi
  bash "${SCRIPTS_DIR}/verify-flash.sh" "$tty" "$role"
}

cmd_query() {
  # Handle help request
  if [[ "${1:-}" == "help" ]]; then
    help_query
    return 0
  fi

  # Query Home Assistant device/entity registry via WebSocket
  local query_script="${SCRIPT_DIR}/scripts/ha-websocket-query.sh"

  if [[ ! -f "$query_script" ]]; then
    err "Query script not found: $query_script"
  fi

  # Delegate to WebSocket query script (with env vars already set)
  "$query_script" "$@"
}

cmd_list() {
  # Shared implementation for the top-level `devices` and `roles` commands.
  # Always invoked as `cmd_list devices [...]` or `cmd_list roles [...]`.
  local output_format="text"
  local subcommand=""
  local filter_role=""
  local suffix_only=false
  local device_mode="all"  # all | production | bootstrap

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bootstrap)
        [[ "$device_mode" == "production" ]] && err "--production and --bootstrap are mutually exclusive"
        device_mode="bootstrap"
        shift
        ;;
      --production)
        [[ "$device_mode" == "bootstrap" ]] && err "--production and --bootstrap are mutually exclusive"
        device_mode="production"
        shift
        ;;
      --csv)
        if [[ "$output_format" != "text" ]]; then
          err "Only one output format allowed (--csv or --json)"
        fi
        output_format="csv"
        shift
        ;;
      --json)
        if [[ "$output_format" != "text" ]]; then
          err "Only one output format allowed (--csv or --json)"
        fi
        output_format="json"
        shift
        ;;
      --id)
        suffix_only=true
        shift
        ;;
      help)
        # Support `iotstack devices help` / `iotstack bootstrap help` / `iotstack roles help`
        case "$subcommand" in
          roles) help_roles ;;
          devices)
            if [[ "$device_mode" == "bootstrap" ]]; then
              help_bootstrap
            else
              help_devices
            fi
            ;;
          *) help_devices ;;
        esac
        return 0
        ;;
      devices|roles)
        subcommand="$1"
        shift
        # For devices subcommand, next argument might be a role filter
        if [[ "$subcommand" == "devices" && $# -gt 0 && "$1" != --* && "$1" != "help" ]]; then
          filter_role="$1"
          shift
        fi
        ;;
      *)
        err "Unknown argument: $1"
        ;;
    esac
  done

  if [[ "$device_mode" != "all" && "$subcommand" != "devices" ]]; then
    err "--production and --bootstrap are only valid with: iotstack devices"
  fi

  case "$subcommand" in
    devices)
      list_devices "$output_format" "$filter_role" "$suffix_only" "$device_mode"
      ;;
    roles)
      list_roles "$output_format" "$suffix_only"
      ;;
    *)
      err "Unknown subcommand: $subcommand. Try 'iotstack devices' or 'iotstack roles'"
      ;;
  esac
}

cmd_device() {
  if [[ "${1:-}" == "help" ]]; then
    help_device
    return 0
  fi

  local subcommand="${1:-}"
  shift || true

  case "$subcommand" in
    get)
      local print_all=0
      local keys=()
      local target=""

      while [[ $# -gt 0 ]]; do
        case "$1" in
          --all)
            print_all=1
            shift
            ;;
          *)
            if [[ -z "$target" && $# -eq 1 ]]; then
              target="$1"
              shift
            elif [[ "$1" =~ ^/dev/ ]]; then
              target="$1"
              shift
            elif [[ "$1" =~ ^[0-9a-fA-F]{6}$ ]]; then
              target="$1"
              shift
            else
              keys+=("$1")
              shift
            fi
            ;;
        esac
      done

      if [[ -z "$target" ]]; then
        help_device
        exit 1
      fi

      if [[ $print_all -eq 0 && ${#keys[@]} -eq 0 ]]; then
        help_device
        exit 1
      fi

      local tty_device=""
      if [[ "$target" =~ ^/dev/ ]]; then
        tty_device="$target"
      else
        # shellcheck source=scripts/esp-serial.sh
        source "${SCRIPT_DIR}/scripts/esp-serial.sh"
        local mac_lower
        mac_lower=$(echo "$target" | tr '[:upper:]' '[:lower:]')
        tty_device=$(esp_tty_for_mac_suffix "$mac_lower") || \
          err "No USB device found with MAC suffix $mac_lower (NVS read requires serial connection)"
        info "Resolved MAC $mac_lower to $tty_device"
      fi

      local read_args=()
      if [[ $print_all -eq 1 ]]; then
        read_args+=(--all)
      else
        read_args+=("${keys[@]}")
      fi
      read_args+=("$tty_device")

      "$SCRIPT_DIR/scripts/read-nvs-secrets.sh" "${read_args[@]}"
      ;;
    *)
      help_device
      exit 1
      ;;
  esac
}

cmd_secret() {
  # Handle help request
  if [[ "${1:-}" == "help" ]]; then
    help_secret
    return 0
  fi

  local command="$1"
  local role="$2"
  local secret_type="$3"
  local value="${4:-}"

  # GNUPGHOME/PASSWORD_STORE_DIR are exported by config.sh (honoring .env).

  if [[ -z "$command" ]]; then
    help_secret
    exit 1
  fi

  case "$command" in
    get)
      if [[ -z "$role" || -z "$secret_type" ]]; then
        help_secret
        exit 1
      fi
      "$SCRIPT_DIR/scripts/iotstack-secrets" get "$role" "$secret_type" "$value"
      ;;
    *)
      help_secret
      exit 1
      ;;
  esac
}

cmd_rotate_secrets() {
  # Handle help request
  if [[ "${1:-}" == "help" ]]; then
    help_rotate_secrets
    return 0
  fi

  local role="$1"
  local new_password="${2:-}"

  if [[ -z "$role" ]]; then
    help_rotate_secrets
    exit 1
  fi

  # Verify role exists (check if YAML file exists)
  if [[ ! -f "${YAMLS_DIR}/${role}.yaml" ]]; then
    err "Unknown role: $role (expected: ${YAMLS_DIR}/${role}.yaml)"
  fi

  local ha_url=""
  local ha_token=""
  local ha_configured=false
  if _load_ha_credentials_optional; then
    ha_url="$HA_URL"
    ha_token="$HA_TOKEN"
    ha_configured=true
  fi

  info "Rotating secrets for role: $role"
  echo "[INFO] - OTA password: Always rotated (required)"
  if [[ "$ha_configured" == true ]]; then
    echo "[INFO] - API encryption key: Will be rotated (HA configured)"
  else
    echo "[INFO] - API encryption key: Skipped (HA not configured)"
  fi
  echo

  # Ensure the role already has an OTA password in pass (will be versioned on success).
  echo "[INFO] Verifying current OTA password exists in pass..."
  if ! cmd_secret get "$role" ota &>/dev/null; then
    err "No password found in pass. Ensure role '$role' has an OTA password configured."
  fi

  # If no new password provided, generate a cryptographically secure one
  if [[ -z "$new_password" ]]; then
    echo "[INFO] Generating cryptographically secure password..."
    # Generate 32 bytes of random data, encode as base64, remove padding/special chars for compatibility
    new_password=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
    echo "[OK] Generated cryptographically secure password (32 chars)"
    echo
    read -p "Use this password? (Y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
      echo "[INFO] Using interactive password entry instead..."
      read -p "Enter new OTA password for '$role': " -rs new_password
      echo
      if [[ -z "$new_password" ]]; then
        err "New password cannot be empty"
      fi
    fi
  fi

  # Discover all devices with this role
  echo "[INFO] Discovering devices with role '$role'..."
  local mac_suffixes=()
  local mac_line

  # Discover all MACs for this role (--id outputs space-separated on one line)
  mac_line=$(iotstack devices "$role" --production --id 2>/dev/null)
  read -ra mac_suffixes <<< "$mac_line"

  if [[ ${#mac_suffixes[@]} -eq 0 ]]; then
    warn "No devices found for role: $role"
    return 1
  fi

  echo "[OK] Found ${#mac_suffixes[@]} device(s) for role '$role': ${mac_suffixes[*]}"
  echo

  # Confirm before proceeding
  read -p "Proceed with secret rotation for ${#mac_suffixes[@]} device(s)? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Secret rotation cancelled"
    return 0
  fi

  # OTA each device via bootstrap so the production slot is updated safely.
  # Devices authenticate OTA with sha256(bootstrap_role_secret | mac) from NVS.
  local yaml_file
  yaml_file=$(resolve_device "$role")

  echo "[INFO] Flashing devices via bootstrap (partition-safe OTA)..."
  echo

  local success_count=0
  local fail_count=0
  declare -a failed_macs=()
  local mac dev_pwd

  for mac in "${mac_suffixes[@]}"; do
    dev_pwd=$(_bootstrap_device_ota_password "$mac") || err "Could not derive bootstrap OTA password for $mac"
    if _ota_via_bootstrap "$mac" "$yaml_file" "$dev_pwd" "${role}-${mac}"; then
      success_count=$((success_count + 1))
    else
      fail_count=$((fail_count + 1))
      failed_macs+=("$mac")
    fi
  done

  echo
  echo "========================================================"
  echo "[INFO] Secret Rotation Summary"
  echo "========================================================"
  echo "  Role: $role"
  echo "  Total: ${#mac_suffixes[@]}"
  echo "  Success: $success_count"
  echo "  Failed: $fail_count"

  if [[ $fail_count -gt 0 ]]; then
    echo "  Failed MACs: ${failed_macs[*]}"
    echo
    warn "Some devices failed. Retry with:"
    echo "  iotstack rotate-secrets $role"
    echo "  # or: iotstack reassign ${failed_macs[*]} $role"
  fi

  # Only update password manager if all succeeded
  if [[ $fail_count -eq 0 ]]; then
    echo "[INFO] All devices flashed successfully"
    echo

    echo "[INFO] Updating password manager with versioned secrets..."
    "$SCRIPT_DIR/scripts/iotstack-secrets" set "$role" ota "$new_password"

    # Only rotate API key if HA is configured
    if [[ "$ha_configured" == true ]]; then
      # Generate and set new API key
      local new_api_key
      echo "[INFO] Generating new API encryption key..."
      new_api_key=$(openssl rand -base64 32 | tr -d '=+/')
      "$SCRIPT_DIR/scripts/iotstack-secrets" set "$role" api "$new_api_key"
      echo "[OK] API encryption key rotated"
    fi

    echo
    ok "Secret rotation complete!"
  else
    warn "Secret rotation incomplete due to failures"
    warn "Do not update password manager yet - some devices may not have new password"
    return 1
  fi
}

list_roles() {
  local output_format="${1:-text}"
  local id_only="${2:-false}"

  if [[ "$id_only" == "true" ]]; then
    case "$output_format" in
      csv)
        echo "Role"
        list_roles_from_conf
        return 0
        ;;
      json)
        _iotstack_require_jq
        list_roles_from_conf | jq -R -s 'split("\n") | map(select(length > 0))' | _iotstack_format_json
        return 0
        ;;
      *)
        list_roles_from_conf
        return 0
        ;;
    esac
  fi

  if [[ "$output_format" == "csv" ]]; then
    echo "Role,Board,Variant,Network,Config"
    # Collect roles and sort by role name
    {
      list_roles_from_conf | while read -r device; do
        local yaml_file board variant network_type config_file device_info
        yaml_file="${YAMLS_DIR}/${device}.yaml"

        if [[ -f "$yaml_file" ]]; then
          device_info=$(get_yaml_device_info "$yaml_file")
          board=$(echo "$device_info" | cut -d'|' -f1)
          variant=$(echo "$device_info" | cut -d'|' -f2)
          network_type=$(echo "$device_info" | cut -d'|' -f3)
          config_file=$(basename "$yaml_file")
        else
          board=""
          variant=""
          network_type=""
          config_file=""
        fi

        printf "%s,%s,%s,%s,%s\n" "$device" "$board" "$variant" "$network_type" "$config_file"
      done
    } | sort
  elif [[ "$output_format" == "json" ]]; then
    {
      list_roles_from_conf | while read -r device; do
        local yaml_file board variant network_type config_file device_info
        yaml_file="${YAMLS_DIR}/${device}.yaml"

        if [[ -f "$yaml_file" ]]; then
          device_info=$(get_yaml_device_info "$yaml_file")
          board=$(echo "$device_info" | cut -d'|' -f1)
          variant=$(echo "$device_info" | cut -d'|' -f2)
          network_type=$(echo "$device_info" | cut -d'|' -f3)
          config_file=$(basename "$yaml_file")
        else
          board=""
          variant=""
          network_type=""
          config_file=""
        fi

        printf "%s|%s|%s|%s|%s\n" "$device" "$board" "$variant" "$network_type" "$config_file"
      done
    } | sort | while IFS='|' read -r device board variant network_type config_file; do
      jq -nc \
        --arg role "$device" \
        --arg board "$board" \
        --arg variant "$variant" \
        --arg network "$network_type" \
        --arg config "$config_file" \
        '{role: $role, board: $board, variant: $variant, network: $network, config: $config}'
    done | _iotstack_json_slurp
  else
    # Text format - gather data first
    local margin=2
    local temp_data temp_unsorted
    temp_data=$(mktemp)
    temp_unsorted=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$temp_data' '$temp_unsorted'" RETURN

    while IFS= read -r device; do
      local yaml_file board variant network_type config_display device_info
      yaml_file="${YAMLS_DIR}/${device}.yaml"

      if [[ -f "$yaml_file" ]]; then
        device_info=$(get_yaml_device_info "$yaml_file")
        board=$(echo "$device_info" | cut -d'|' -f1)
        variant=$(echo "$device_info" | cut -d'|' -f2)
        network_type=$(echo "$device_info" | cut -d'|' -f3)
        config_display=$(basename "$yaml_file")
      else
        board=""
        variant=""
        network_type=""
        config_display=""
      fi

      printf "%s|%s|%s|%s|%s\n" "$device" "$board" "$variant" "$network_type" "$config_display" >> "$temp_unsorted"
    done < <(list_roles_from_conf)

    # Sort by role name
    sort "$temp_unsorted" > "$temp_data"

    # Calculate column widths
    local header_role="iotstack Role"
    local header_board="Board Name"
    local header_variant="Hardware Variant"
    local header_network="Network Type"
    local header_config="Config Path"

    local w_role=$(( ${#header_role} + margin ))
    local w_board=$(( ${#header_board} + margin ))
    local w_variant=$(( ${#header_variant} + margin ))
    local w_network=$(( ${#header_network} + margin ))
    local w_config=$(( ${#header_config} + margin ))

    while IFS='|' read -r device board variant network_type config_display; do
      (( ${#device} + margin > w_role )) && w_role=$(( ${#device} + margin ))
      (( ${#board} + margin > w_board )) && w_board=$(( ${#board} + margin ))
      (( ${#variant} + margin > w_variant )) && w_variant=$(( ${#variant} + margin ))
      (( ${#network_type} + margin > w_network )) && w_network=$(( ${#network_type} + margin ))
      (( ${#config_display} + margin > w_config )) && w_config=$(( ${#config_display} + margin ))
    done < "$temp_data"

    info "Available device roles:"
    echo

    # Print headers
    printf "  ${GRN}%-${w_role}s %-${w_board}s %-${w_variant}s %-${w_network}s %-${w_config}s${RST}\n" \
      "$header_role" "$header_board" "$header_variant" "$header_network" "$header_config"

    # Print separator
    _print_table_rule "$w_role" "$w_board" "$w_variant" "$w_network" "$w_config"

    # Print data rows
    while IFS='|' read -r device board variant network_type config_display; do
      printf "  ${GRN}%-${w_role}s${RST} %-${w_board}s %-${w_variant}s %-${w_network}s %-${w_config}s\n" \
        "$device" "$board" "$variant" "$network_type" "$config_display"
    done < "$temp_data"


    echo
    ok Consider running 'iotstack devices' next.
    echo
  fi
}

# -- HA device registration --------------------------------------------------

_ha_after_production_online() {
  # Home Assistant work runs only after production firmware is online -- never
  # while the device is still advertising as bootstrap-*.
  local yaml_path="$1"
  local prod_hostname="$2"

  if [[ "${PERFORM_HA_DEVICE_REGISTRATION:-0}" == "1" ]]; then
    # Registration is mandatory: prompt for and verify HA URL/token instead of
    # silently skipping, so ha_token=CONFIGURE_ME triggers the token flow rather
    # than a no-op. ensure_ha_integration re-prompts on a rejected token and
    # aborts on unrecoverable failure -- correct when HA work is required.
    # shellcheck source=scripts/ensure-integration-secrets.sh
    source "${SCRIPT_DIR}/scripts/ensure-integration-secrets.sh"
    ensure_ha_integration
  else
    # HA is an optional integration here; skip quietly when unconfigured.
    _load_ha_credentials_optional || return 0
    [[ -z "$HA_URL" || -z "$HA_TOKEN" ]] && return 0
  fi

  # HA registration failure is non-fatal (device is flashed and running); only
  # run ha-finalize when registration actually completed. Always return 0 so a
  # failed/optional HA step never aborts the flash under set -e.
  if _ha_register_esphome_device "$prod_hostname" "$yaml_path"; then
    _run_update_devices --ha-finalize "$prod_hostname" "$yaml_path"
  fi
  return 0
}

_derive_device_api_encryption_key() {
  # Device-specific API key: sha256(role_secret | mac) -- same as write-nvs-secrets.sh
  local role="$1"
  local mac="$2"
  local base
  base=$(pass show "iotstack/roles/${role}/api_encryption_key" 2>/dev/null) || return 1
  echo -n "${base}|${mac}" | sha256sum | cut -c1-64
}

_device_api_noise_psk_b64() {
  # Base64 noise_psk for aioesphomeapi (same encoding as HA config-flow registration).
  local role="$1"
  local mac="$2"
  local hex
  hex=$(_derive_device_api_encryption_key "$role" "$mac") || return 1
  python3 -c "import binascii,base64,sys; print(base64.b64encode(binascii.unhexlify(sys.argv[1])).decode())" "$hex"
}

_device_api_noise_psk_from_nvs_tty() {
  # prod_api_key from device NVS (USB). Fallback when pass-derived key mismatches.
  local tty_device="$1"
  local hex
  hex=$("$SCRIPT_DIR/scripts/read-nvs-secrets.sh" prod_api_key "$tty_device" 2>/dev/null) || return 1
  hex=$(echo "$hex" | tr -d '[:space:]')
  [[ "$hex" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  python3 -c "import binascii,base64,sys; print(base64.b64encode(binascii.unhexlify(sys.argv[1])).decode())" "$hex"
}

_invoke_production_api_service() {
  local api_host="$1"
  local service="$2"
  local noise_psk="${3:-}"
  local api_src="esphome:api:${service}"

  if [[ -n "$noise_psk" ]]; then
    if create_log_child_output_piped; then
      IOTSTACK_API_NOISE_PSK="$noise_psk" \
        create_log_run "$api_src" "$SCRIPT_DIR/scripts/esphome-service.sh" "$api_host" "$service"
      return $?
    fi
    IOTSTACK_API_NOISE_PSK="$noise_psk" \
      "$SCRIPT_DIR/scripts/esphome-service.sh" "$api_host" "$service"
    return $?
  fi
  if create_log_child_output_piped; then
    create_log_run "$api_src" "$SCRIPT_DIR/scripts/esphome-service.sh" "$api_host" "$service"
    return $?
  fi
  "$SCRIPT_DIR/scripts/esphome-service.sh" "$api_host" "$service"
}

_call_production_api_service() {
  # Invoke a native-API user service on a running production device.
  local production_hostname="$1"
  local mac="$2"
  local service="$3"
  local tty_device="${4:-}"
  local role noise_psk nvs_psk api_host

  role="${production_hostname%-${mac}}"
  api_host="${production_hostname}.local"
  noise_psk=$(_device_api_noise_psk_b64 "$role" "$mac" 2>/dev/null) || true
  if [[ -n "$noise_psk" ]]; then
    if _invoke_production_api_service "$api_host" "$service" "$noise_psk"; then
      return 0
    fi
    if [[ -n "$tty_device" ]]; then
      nvs_psk=$(_device_api_noise_psk_from_nvs_tty "$tty_device" 2>/dev/null) || nvs_psk=""
      if [[ -n "$nvs_psk" && "$nvs_psk" != "$noise_psk" ]]; then
        debug "[$mac] retrying ${service} with prod_api_key from device NVS"
        _invoke_production_api_service "$api_host" "$service" "$nvs_psk"
        return $?
      fi
    fi
    return 1
  fi
  warn "[$mac] no API encryption key in pass for role ${role}; trying plaintext API"
  _invoke_production_api_service "$api_host" "$service" ""
}

_ha_register_esphome_device() {
  # Register production device in Home Assistant when PERFORM_HA_DEVICE_REGISTRATION=1.
  # Uses WebSocket API to find the zeroconf flow and the device api_encryption_key
  # (derived from pass + MAC) to complete the ESPHome config flow.
  #
  # Usage: _ha_register_esphome_device <hostname> <yaml_path>
  local hostname="$1"
  local yaml_path="$2"

  # shellcheck source=scripts/ensure-integration-secrets.sh
  source "${SCRIPT_DIR}/scripts/ensure-integration-secrets.sh"

  if [[ "${PERFORM_HA_DEVICE_REGISTRATION:-0}" != "1" ]]; then
    return 0
  fi

  local mac role api_key_hex noise_psk_b64
  mac=$(echo "$hostname" | grep -oE '[0-9a-f]{6}$' | tr '[:upper:]' '[:lower:]')
  role=$(_yaml_device_role "$yaml_path")
  if [[ -z "$mac" || -z "$role" ]]; then
    err "Cannot derive role/MAC for HA registration of $hostname"
  fi

  api_key_hex=$(_derive_device_api_encryption_key "$role" "$mac") || {
    err "API encryption key not found in pass for role: $role"
  }

  noise_psk_b64=$(python3 -c "import binascii,base64,sys; print(base64.b64encode(binascii.unhexlify(sys.argv[1])).decode())" "$api_key_hex")

  info "Registering $hostname in Home Assistant (PERFORM_HA_DEVICE_REGISTRATION=1)..."
  local reg_out reg_rc=0
  reg_out=$(python3 "${SCRIPT_DIR}/scripts/ha_websocket.py" \
      --ha-url "$HA_URL" \
      --ha-token "$HA_TOKEN" \
      register-esphome \
      --hostname "$hostname" \
      --noise-psk "$noise_psk_b64" 2>&1) || reg_rc=$?
  if [[ $reg_rc -eq 0 ]]; then
    if echo "$reg_out" | grep -qi 'already has'; then
      ok "Home Assistant already has $hostname"
    else
      echo "$reg_out" | grep -E '^\[OK\]' || ok "Home Assistant registration complete for $hostname"
    fi
    return 0
  fi

  # Log the failure reason into the session log (ha_websocket.py prints a clean
  # one-line "[error] ..." on failure) rather than only echoing to the console, so
  # the log shows WHY registration did not complete.
  if [[ -n "$reg_out" ]]; then
    while IFS= read -r _reg_line; do
      [[ -n "$_reg_line" ]] && warn "  ${_reg_line}"
    done <<< "$reg_out"
  fi
  # Registration failing is not fatal to the flash: the device is already
  # flashed, running, and reachable -- only the optional HA auto-registration did
  # not complete (e.g. a Thread device whose SRP service has not propagated to HA
  # yet). Warn instead of err/exit so the flash finishes cleanly; the human can
  # finish from the HA dashboard. Return non-zero so the caller skips ha-finalize.
  if invalidate_ha_token_if_auth_failure "$reg_out"; then
    warn "Home Assistant access token is invalid -- iotstack/common/ha_token reset to CONFIGURE_ME. Configure a new token and re-run to register $hostname."
    return 1
  fi
  warn "Home Assistant registration for $hostname did not complete -- finish manually: ${HA_URL}/config/integrations/dashboard"
  return 1
}

# -- Flash command: serial/USB flashing -------------------------------------
cmd_set_boot() {
  # Set boot partition for a specific device
  # Usage: iotstack set-boot <device> <recovery|production>
  #   device: MAC suffix (1af95c) or serial device (/dev/ttyACM0)
  #   partition: recovery or production
  local device="${1:-}"
  local partition="${2:-}"

  if [[ -z "$device" || -z "$partition" ]]; then
    cat << 'EOF'
Usage: iotstack set-boot <device> <bootstrap|production>

Set which partition a bootstrap device boots into.

Arguments:
  <device>      MAC suffix (e.g., 1af95c) OR serial device (e.g., /dev/ttyACM0)
  <partition>   bootstrap or production

Examples:
  Network device (by MAC):
    iotstack set-boot 1af95c bootstrap          # Set bootstrap-1af95c -> bootstrap
    iotstack set-boot 9019c8 production        # Set bootstrap-9019c8 -> production

  USB-connected device:
    iotstack set-boot /dev/ttyACM0 bootstrap    # Set /dev/ttyACM0 -> bootstrap
    iotstack set-boot /dev/ttyUSB0 production  # Set /dev/ttyUSB0 -> production
EOF
    exit 1
  fi

  if [[ ! "$partition" =~ ^(bootstrap|production)$ ]]; then
    err "Partition must be 'bootstrap' or 'production'"
  fi

  # Determine if device is serial (USB) or MAC (network)
  if [[ "$device" =~ ^/dev/ ]]; then
    # Serial device
    if [[ ! -e "$device" ]]; then
      err "Device not found: $device"
    fi
    info "Setting $device to boot: $partition"
    _boot_partition_usb "$device" "$partition"
  else
    # MAC suffix
    info "Setting bootstrap-$device to boot: $partition"
    _boot_partition_network "$partition" "$device"
  fi
}

_boot_partition_usb() {
  # Set boot partition on USB-connected device
  local device="$1"
  local partition="$2"

  # Device must be running bootstrap-wifi firmware for this to work
  info "Toggling boot partition..."
  if timeout 5 curl -s -X POST "http://localhost:6053/api/services/button/press" \
    -H "Content-Type: application/json" \
    -d '{"entity_id": "button.bootstrap_toggle_boot_partition"}' >/dev/null 2>&1; then
    ok "Boot partition toggled to: $partition"
  else
    err "Could not communicate with device. Ensure it's running and connected."
  fi
}

_boot_partition_network() {
  # Toggle boot partition on a network device identified by MAC suffix.
  # Tries bootstrap-<mac> first, then any known production role hostname.
  local target_partition="$1"
  local mac="$2"
  local mac_lower host entity_id

  mac_lower=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
  info "Setting device ${mac_lower} to boot: $target_partition..."

  local -a hosts=("$(iotstack_bootstrap_hostname "$mac_lower")")
  local role
  while IFS='=' read -r role _yaml; do
    [[ -z "$role" || "$role" =~ ^[[:space:]]*# ]] && continue
    hosts+=("${role}-${mac_lower}")
  done < "$ROLES_CONF"

  for host in "${hosts[@]}"; do
    entity_id="button.${host//-/_}_toggle_boot_partition"
    if curl -s -X POST "http://${host}.local/api/services/button/press" \
      -H "Content-Type: application/json" \
      -d "{\"entity_id\": \"${entity_id}\"}" \
      --max-time 5 >/dev/null 2>&1; then
      ok "  Boot partition toggled via ${host}.local ($target_partition requested)"
      return 0
    fi
  done

  err "Could not reach device ${mac_lower} on network (tried bootstrap + production hostnames)"
}

_boot_partition_single() {
  _boot_partition_network "$1" "$2"
}

_boot_to_production_via_bootstrap() {
  # Toggle a device (currently on bootstrap) back to its production partition
  # WITHOUT re-OTAing. Used when the production slot already holds the matching
  # image, so a full OTA would be wasted work. Non-fatal: returns 0 if the toggle
  # was delivered, 1 otherwise, so callers can fall back to OTA. (Mirrors the
  # bootstrap-host branch of _boot_partition_network, which err-exits on failure.)
  local mac="$1"
  local mac_lower host entity_id
  mac_lower=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
  host="$(iotstack_bootstrap_hostname "$mac_lower")"
  entity_id="button.${host//-/_}_toggle_boot_partition"
  curl -s -X POST "http://${host}.local/api/services/button/press" \
    -H "Content-Type: application/json" \
    -d "{\"entity_id\": \"${entity_id}\"}" \
    --max-time 5 >/dev/null 2>&1
}

_flash_matrix_layout_applicable() {
  # Matrix NVS layout options apply to matrixdisplay production flashes only.
  local device="$1"
  local second="${2:-}"
  [[ "$device" == "matrixdisplay" ]] && return 0
  [[ "$device" == "bootstrap" && "$second" == "matrixdisplay" ]] && return 0
  return 1
}

_flash_matrix_layout_flags_set() {
  [[ -n "${MATRIX_COLS}${MATRIX_ROWS}${MATRIX_PANEL_W}${MATRIX_PANEL_H}" ]]
}

_flash_resolve_matrix_layout() {
  # Resolve target panel layout (flags -> pass -> defaults). Sets named refs.
  # cols = horizontal panels (side by side); rows = vertical panels (stacked).
  local role="$1"
  local -n _cols_ref="$2"
  local -n _rows_ref="$3"
  local -n _w_ref="$4"
  local -n _h_ref="$5"

  _cols_ref="${MATRIX_COLS:-}"
  _rows_ref="${MATRIX_ROWS:-}"
  _w_ref="${MATRIX_PANEL_W:-}"
  _h_ref="${MATRIX_PANEL_H:-}"
  if [[ -n "$role" ]]; then
    [[ -z "$_cols_ref" ]] && _cols_ref=$(pass show "iotstack/roles/${role}/matrix_cols" 2>/dev/null || echo "")
    [[ -z "$_rows_ref" ]] && _rows_ref=$(pass show "iotstack/roles/${role}/matrix_rows" 2>/dev/null || echo "")
    [[ -z "$_w_ref" ]] && _w_ref=$(pass show "iotstack/roles/${role}/matrix_panel_w" 2>/dev/null || echo "")
    [[ -z "$_h_ref" ]] && _h_ref=$(pass show "iotstack/roles/${role}/matrix_panel_h" 2>/dev/null || echo "")
  fi
  _cols_ref="${_cols_ref:-1}"
  _rows_ref="${_rows_ref:-1}"
  _w_ref="${_w_ref:-64}"
  _h_ref="${_h_ref:-32}"
  if [[ "$_cols_ref" != "1" && "$_cols_ref" != "2" ]]; then
    err "Horizontal panel count must be 1 or 2 (got: $_cols_ref)"
  fi
  if [[ "$_rows_ref" != "1" && "$_rows_ref" != "2" ]]; then
    err "Vertical panel count must be 1 or 2 (got: $_rows_ref)"
  fi
}

_flash_read_matrix_layout_from_device() {
  # Read active matrix layout from production text_sensors. Sets named refs; returns 0 on success.
  local prod_hostname="$1"
  local mac="$2"
  local role="$3"
  local -n _cols_ref="$4"
  local -n _rows_ref="$5"
  local -n _w_ref="$6"
  local -n _h_ref="$7"
  local api_host="${prod_hostname}.local"
  local noise_psk output line key val

  _cols_ref="" _rows_ref="" _w_ref="" _h_ref=""
  noise_psk=$(_device_api_noise_psk_b64 "$role" "$mac" 2>/dev/null) || true
  local -a _layout_sensor_ids=(panel_count panel_rows matrix_panel_width matrix_panel_height)
  if [[ -n "$noise_psk" ]]; then
    output=$(IOTSTACK_API_NOISE_PSK="$noise_psk" \
      "$SCRIPT_DIR/scripts/esphome_text_sensors.py" "$api_host" \
      "${_layout_sensor_ids[@]}" 2>/dev/null) || output=""
  else
    output=$("$SCRIPT_DIR/scripts/esphome_text_sensors.py" "$api_host" \
      "${_layout_sensor_ids[@]}" 2>/dev/null) || output=""
  fi

  while IFS= read -r line; do
    [[ "$line" != *"="* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      panel_count) _cols_ref="$val" ;;
      panel_rows) _rows_ref="$val" ;;
      matrix_panel_width) _w_ref="$val" ;;
      matrix_panel_height) _h_ref="$val" ;;
    esac
  done <<< "$output"

  # Firmware predating vertical stacking has no panel_rows sensor -- treat as 1
  # row so a layout comparison against a rows=1 target still matches.
  [[ -z "$_rows_ref" ]] && _rows_ref="1"

  # Pre-rename firmware used object_id matrix_panel_columns for the same sensor.
  if [[ -z "$_cols_ref" ]]; then
    local legacy_output
    if [[ -n "$noise_psk" ]]; then
      legacy_output=$(IOTSTACK_API_NOISE_PSK="$noise_psk" \
        "$SCRIPT_DIR/scripts/esphome_text_sensors.py" "$api_host" \
        matrix_panel_columns 2>/dev/null) || legacy_output=""
    else
      legacy_output=$("$SCRIPT_DIR/scripts/esphome_text_sensors.py" "$api_host" \
        matrix_panel_columns 2>/dev/null) || legacy_output=""
    fi
    _cols_ref="${legacy_output#matrix_panel_columns=}"
    [[ "$_cols_ref" == "$legacy_output" ]] && _cols_ref=""
  fi

  [[ -n "$_cols_ref" && -n "$_w_ref" && -n "$_h_ref" ]]
}

# -- NVS update policy --------------------------------------------------------
# Prefer bootstrap update_nvs_secrets over WiFi/API. The bootstrap API is
# ENCRYPTED (noise PSK = per-device boot_api_key); the tooling connects with
# that PSK and never in plaintext. USB (write-nvs-secrets.sh) is used only when
# the encrypted bootstrap API is unreachable -- typical on first serial provision
# before WiFi/boot_api_key exist in NVS, when bootstrap lacks the API
# service, or when the device predates bootstrap encryption (USB reflash).

_bootstrap_api_noise_psk_b64() {
  # Base64 noise PSK for the encrypted bootstrap API (port 6053), derived from
  # the per-device boot_api_key. Non-zero (no output) when the role master
  # secret is absent -- callers must not fall back to plaintext.
  local mac="$1" hex
  hex=$(iotstack_bootstrap_device_api_key "$mac") || return 1
  [[ "$hex" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  python3 -c "import binascii,base64,sys; print(base64.b64encode(binascii.unhexlify(sys.argv[1])).decode())" "$hex"
}

_call_bootstrap_api_service() {
  # Invoke a native-API user service on bootstrap firmware over the ENCRYPTED
  # API (noise PSK = per-device boot_api_key). Zero-trust: never connect in
  # plaintext -- if the PSK cannot be derived, return failure so the caller falls
  # back to USB provisioning (the trusted out-of-band channel).
  local device_mac="$1"
  local service="$2"
  local json_vars="${3:-}"
  local api_host="$(iotstack_bootstrap_hostname "$device_mac").local"
  local api_src="esphome:api:${service}"
  local noise_psk

  noise_psk=$(_bootstrap_api_noise_psk_b64 "$device_mac" 2>/dev/null) || noise_psk=""
  if [[ -z "$noise_psk" ]]; then
    warn "[$device_mac] no bootstrap API key in pass; refusing plaintext bootstrap API (use USB)"
    return 1
  fi

  # IOTSTACK_API_REQUIRE_NOISE=1 forbids any plaintext downgrade: bootstrap calls
  # carry secrets, so a failed encrypted handshake must fail closed (-> USB), not
  # retry in cleartext.
  if create_log_child_output_piped; then
    IOTSTACK_API_NOISE_PSK="$noise_psk" IOTSTACK_API_REQUIRE_NOISE=1 \
      create_log_run "$api_src" "$SCRIPT_DIR/scripts/esphome-service.sh" \
      "$api_host" "$service" "" "$json_vars"
    return $?
  fi
  IOTSTACK_API_NOISE_PSK="$noise_psk" IOTSTACK_API_REQUIRE_NOISE=1 \
    "$SCRIPT_DIR/scripts/esphome-service.sh" "$api_host" "$service" "" "$json_vars"
}

_nvs_secrets_api_json_payload() {
  # Build update_nvs_secrets JSON (stdout only). Uses pass + env (MATRIX_* flags).
  local device_mac="$1"
  local production_role="${2:-}"
  "$SCRIPT_DIR/scripts/write-nvs-secrets.sh" --print-api-json "$device_mac" "$production_role"
}

_bootstrap_api_reachable() {
  local device_mac="$1"
  _production_api_reachable "$(iotstack_bootstrap_hostname "$device_mac")"
}

_nvs_update_via_bootstrap_api() {
  # Call update_nvs_secrets on bootstrap-<mac>.local. Returns 0 on success.
  local device_mac="$1"
  local json_vars="$2"
  local bootstrap_host="$(iotstack_bootstrap_hostname "$device_mac")"

  if ! _bootstrap_api_reachable "$device_mac"; then
    return 1
  fi
  info "Updating NVS via ${bootstrap_host}.local (update_nvs_secrets API)..."
  _call_bootstrap_api_service "$device_mac" update_nvs_secrets "$json_vars"
}

_provision_device_nvs() {
  # Write device NVS: API first when bootstrap is already on WiFi; USB otherwise.
  # --erase: bootstrap cannot reach the API until WiFi creds exist in NVS, so USB
  # is required before the bootstrap image is flashed and the device boots.
  # USB fallback warning is deferred until bootstrap WiFi init times out
  # (_flash_bootstrap_await_wifi), except on --erase where USB is expected.
  local tty_device="${1:-}"
  local device_mac="$2"
  local production_role="${3:-}"
  local json_vars
  local defer_hard_reset=0

  IOTSTACK_NVS_PROVISIONED_VIA_USB=0
  json_vars=$(_nvs_secrets_api_json_payload "$device_mac" "$production_role") || return 1

  if [[ "${FLASH_ERASE:-0}" != "1" ]] && _nvs_update_via_bootstrap_api "$device_mac" "$json_vars"; then
    ok "NVS updated via bootstrap API (device rebooting)"
    sleep 5
    _wait_for_device "$(iotstack_bootstrap_hostname "$device_mac")" 60 || true
    return 0
  fi

  if [[ -z "$tty_device" ]]; then
    debug "NVS API update failed and no USB device provided"
    return 1
  fi

  if [[ "${FLASH_ERASE:-0}" == "1" ]]; then
    info "NVS USB write required before bootstrap boot (--erase: WiFi credentials must be in NVS first)"
    defer_hard_reset=1
  fi

  IOTSTACK_NVS_PROVISIONED_VIA_USB=1
  _flash_write_nvs_secrets_usb "$tty_device" "$device_mac" "$production_role" "$defer_hard_reset"
}

_bootstrap_update_nvs_matrix_layout() {
  # Partial update: matrix_cols / matrix_rows / matrix_panel_w / matrix_panel_h only.
  local device_mac="$1"
  local cols="$2"
  local rows="$3"
  local w="$4"
  local h="$5"
  local json_vars

  json_vars=$(
    MATRIX_COLS="$cols" MATRIX_ROWS="$rows" MATRIX_PANEL_W="$w" MATRIX_PANEL_H="$h" python3 - <<'PY'
import json, os
print(json.dumps({
    "wifi_ssid": "",
    "wifi_password": "",
    "ota_password": "",
    "api_key": "",
    "thread_tlv": "",
    "matrix_cols": os.environ["MATRIX_COLS"],
    "matrix_rows": os.environ["MATRIX_ROWS"],
    "matrix_panel_w": os.environ["MATRIX_PANEL_W"],
    "matrix_panel_h": os.environ["MATRIX_PANEL_H"],
    "device_role": "",
    "git_commit": "",
}))
PY
  ) || return 1

  _nvs_update_via_bootstrap_api "$device_mac" "$json_vars"
}

_flash_write_nvs_secrets_usb() {
  local tty_device="$1"
  local device_mac="$2"
  local production_role="${3:-}"
  local defer_hard_reset="${4:-0}"
  local -a nvs_args=()

  [[ "$defer_hard_reset" == "1" ]] && nvs_args+=(--no-hard-reset)

  info "Writing device-specific secrets to NVS via USB..."
  create_log_serial_capture_pause
  if create_log_child_output_piped; then
    create_log_run "write-nvs-secrets" "$SCRIPT_DIR/scripts/write-nvs-secrets.sh" \
      "${nvs_args[@]}" "$tty_device" "$device_mac" "$production_role" \
      || err "Failed to write NVS secrets to device"
  else
    "$SCRIPT_DIR/scripts/write-nvs-secrets.sh" \
      "${nvs_args[@]}" "$tty_device" "$device_mac" "$production_role" \
      || err "Failed to write NVS secrets to device"
  fi
  ok "NVS secrets written successfully via USB"
  create_log_serial_capture_resume
}

# Back-compat alias
_flash_write_nvs_secrets() {
  _flash_write_nvs_secrets_usb "$@"
}

_flash_store_matrix_layout_pass() {
  local role="$1"
  local cols="$2"
  local rows="$3"
  local w="$4"
  local h="$5"

  [[ "${MATRIX_COLS_EXPLICIT:-0}" == "1" ]] && \
    printf '%s' "$cols" | pass insert -f "iotstack/roles/${role}/matrix_cols" 2>/dev/null || true
  [[ "${MATRIX_ROWS_EXPLICIT:-0}" == "1" ]] && \
    printf '%s' "$rows" | pass insert -f "iotstack/roles/${role}/matrix_rows" 2>/dev/null || true
  [[ "${MATRIX_PANEL_W_EXPLICIT:-0}" == "1" ]] && \
    printf '%s' "$w" | pass insert -f "iotstack/roles/${role}/matrix_panel_w" 2>/dev/null || true
  [[ "${MATRIX_PANEL_H_EXPLICIT:-0}" == "1" ]] && \
    printf '%s' "$h" | pass insert -f "iotstack/roles/${role}/matrix_panel_h" 2>/dev/null || true
}

_flash_matrix_layout_mismatch() {
  # Compare target layout (flags -> pass -> defaults) to production API text_sensors.
  # Returns 0 when layouts match or check not applicable; 1 when NVS update is needed.
  local device="$1"
  local device_mac="$2"
  local prod_hostname="$3"
  local want_cols want_rows want_w want_h cur_cols cur_rows cur_w cur_h

  _flash_matrix_layout_applicable "$device" "" || return 0
  _flash_resolve_matrix_layout "$device" want_cols want_rows want_w want_h

  if _flash_read_matrix_layout_from_device "$prod_hostname" "$device_mac" "$device" \
      cur_cols cur_rows cur_w cur_h; then
    [[ "$cur_cols" == "$want_cols" && "$cur_rows" == "$want_rows" && "$cur_w" == "$want_w" && "$cur_h" == "$want_h" ]] && return 0
    return 1
  fi

  # Runtime sensors unavailable -- only update when layout flags were passed explicitly.
  if _flash_matrix_layout_flags_set; then
    return 1
  fi
  return 0
}

_flash_matrix_layout_update_via_bootstrap_if_needed() {
  # Query production API sensors; on mismatch, switch to bootstrap and update NVS
  # via update_nvs_secrets API (USB esptool write is fallback only).
  # Returns 0 if unchanged, 2 if NVS was updated, 1 on failure.
  local device="$1"
  local tty_device="$2"
  local device_mac="$3"
  local prod_hostname="$4"
  local want_cols want_rows want_w want_h cur_cols cur_rows cur_w cur_h
  local verify_cols verify_rows verify_w verify_h

  # _flash_matrix_layout_mismatch returns 0 when no NVS update is needed (layouts
  # already match, OR this is not a matrix-display role) and 1 when an update is
  # needed. Only proceed when an update is actually needed -- otherwise this would
  # write matrix_* keys to non-matrix devices (e.g. bleproxy).
  if _flash_matrix_layout_mismatch "$device" "$device_mac" "$prod_hostname"; then
    return 0
  fi
  _flash_resolve_matrix_layout "$device" want_cols want_rows want_w want_h

  if _flash_read_matrix_layout_from_device "$prod_hostname" "$device_mac" "$device" \
      cur_cols cur_rows cur_w cur_h; then
    if [[ "$cur_cols" == "$want_cols" && "$cur_rows" == "$want_rows" && "$cur_w" == "$want_w" && "$cur_h" == "$want_h" ]]; then
      return 0
    fi
    info "Matrix layout mismatch: runtime ${cur_cols}x${cur_rows} panel(s) ${cur_w}x${cur_h} px -> target ${want_cols}x${want_rows} panel(s) ${want_w}x${want_h} px"
  else
    info "Matrix layout: writing target ${want_cols}x${want_rows} panel(s), ${want_w}x${want_h} px to NVS"
  fi

  info "Step 1: Preparing ${prod_hostname} for layout update..."
  if ! _ensure_device_on_bootstrap "$device_mac" false "$tty_device" "$device"; then
    if [[ -n "$tty_device" ]]; then
      warn "Network layout update failed -- preparing device on ${tty_device}..."
      local _mac_file
      _mac_file=$(mktemp)
      _flash_bootstrap_to_tty "$tty_device" "$_mac_file" "$device" \
        || { rm -f "$_mac_file"; return 1; }
      rm -f "$_mac_file"
      if ! _wait_for_device "$(iotstack_bootstrap_hostname "$device_mac")" 90; then
        warn "$(iotstack_bootstrap_hostname "$device_mac") did not appear after serial refresh"
        _flash_warn_start_serial_logs "$tty_device"
        return 1
      fi
    else
      return 1
    fi
  fi

  info "Step 2: Updating matrix layout in NVS..."
  if _bootstrap_update_nvs_matrix_layout "$device_mac" "$want_cols" "$want_rows" "$want_w" "$want_h"; then
    ok "Matrix layout NVS updated via bootstrap API (device rebooting)"
    sleep 5
    _wait_for_device "$(iotstack_bootstrap_hostname "$device_mac")" 60 || true
  elif [[ -n "$tty_device" ]]; then
    warn "Bootstrap API unavailable -- writing matrix layout NVS via USB on ${tty_device}"
    export MATRIX_COLS="$want_cols" MATRIX_ROWS="$want_rows" MATRIX_PANEL_W="$want_w" MATRIX_PANEL_H="$want_h"
    _flash_write_nvs_secrets_usb "$tty_device" "$device_mac" "$device"
  else
    err "Bootstrap API NVS update failed and no USB device was provided"
    return 1
  fi
  _flash_store_matrix_layout_pass "$device" "$want_cols" "$want_rows" "$want_w" "$want_h"

  info "Step 3: Booting production firmware with updated NVS..."
  # This code path runs only when the on-flash production image already matched the
  # build (FLASH_ASSESS_FLASH_CURRENT), so the production partition still holds the
  # correct image -- re-OTAing it is wasted work. Toggle the boot partition back to
  # production instead; fall back to OTA only if the toggle can't be delivered.
  if _boot_to_production_via_bootstrap "$device_mac"; then
    ok "Boot partition toggled to production (OTA skipped -- image already current)"
  else
    warn "Boot-partition toggle unreachable -- falling back to production OTA"
    local _layout_yaml
    _layout_yaml=$(resolve_device "$device" false 2>/dev/null) || _layout_yaml=""
    if [[ -n "$_layout_yaml" ]]; then
      _flash_invoke_update "$device_mac" "$_layout_yaml" "$device" "$tty_device"
    else
      warn "Could not resolve yaml for ${device} -- try: iotstack flash ${device} ${tty_device}"
      return 1
    fi
  fi

  if _wait_for_production_online "$prod_hostname" 90; then
    if _flash_read_matrix_layout_from_device "$prod_hostname" "$device_mac" "$device" \
        verify_cols verify_rows verify_w verify_h \
        && [[ "$verify_cols" == "$want_cols" && "$verify_rows" == "$want_rows" && "$verify_w" == "$want_w" && "$verify_h" == "$want_h" ]]; then
      ok "Matrix layout verified via API: ${verify_cols}x${verify_rows} panel(s), ${verify_w}x${verify_h} px"
    else
      ok "Production firmware online -- matrix layout NVS written (re-query sensors if needed)"
    fi
  else
    warn "Production ${prod_hostname} did not reappear within 90s -- NVS was written on bootstrap"
  fi
  return 2
}

_flash_serial_batch() {
  # Flash a list of EXPLICIT tty devices one at a time (serially, never in
  # parallel): each device runs its full flash cycle to completion before the
  # next begins. Mirrors the auto-detect multi-device loop -- failures are
  # collected and reported at the end rather than aborting the batch.
  # Usage: _flash_serial_batch <label> <mode:production|bootstrap> <role> \
  #          <skip_recovery> <tty>...
  local label="$1" mode="$2" role="$3" skip_recovery="$4"
  shift 4
  local -a ttys=("$@")
  local total=${#ttys[@]} idx=0 failed=0 t rc
  info "Serial flash: ${total} device(s), one at a time (never in parallel)"
  for t in "${ttys[@]}"; do
    idx=$((idx + 1))
    echo ""
    info "===== Device ${idx}/${total}: ${label} on ${t} ====="
    echo "========================================================"
    rc=0
    if [[ "$mode" == "bootstrap" ]]; then
      _flash_recovery "$t" || rc=$?
    else
      _flash_production_smart "$role" "$t" "$skip_recovery" || rc=$?
    fi
    echo "========================================================"
    if [[ $rc -eq 0 ]]; then
      ok "Device ${idx}/${total} on ${t}: complete"
    else
      warn "Device ${idx}/${total} on ${t}: FAILED (rc=${rc})"
      failed=$((failed + 1))
    fi
  done
  if [[ $failed -gt 0 ]]; then
    err "Serial flash: ${failed}/${total} device(s) failed"
  fi
  ok "Serial flash complete: ${total}/${total} device(s)"
}

cmd_flash() {
  _iotstack_command_help_if_requested flash "$@" && return 0

  export IOTSTACK_FLASH_SESSION_PID=$$

  local device="" tty_device_or_role="" skip_recovery=""
  local -a tty_args=()
  export FLASH_ERASE=0
  export FLASH_ON_FLASH_VERIFY=0
  export MATRIX_COLS=""
  export MATRIX_ROWS=""
  export MATRIX_PANEL_W=""
  export MATRIX_PANEL_H=""
  export MATRIX_COLS_EXPLICIT=0
  export MATRIX_ROWS_EXPLICIT=0
  export MATRIX_PANEL_W_EXPLICIT=0
  export MATRIX_PANEL_H_EXPLICIT=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ota-only)
        skip_recovery="--ota-only"
        shift
        ;;
      --on-flash-verify)
        FLASH_ON_FLASH_VERIFY=1
        shift
        ;;
      --erase)
        export FLASH_ERASE=1
        shift
        ;;
      --horizontal-panel-count=*|--panel-count=*)
        # --panel-count is the deprecated pre-vertical-stacking name.
        MATRIX_COLS="${1#*=}"
        MATRIX_COLS_EXPLICIT=1
        shift
        ;;
      --horizontal-panel-count|--panel-count)
        [[ $# -lt 2 ]] && err "Missing value for ${1}"
        MATRIX_COLS="$2"
        MATRIX_COLS_EXPLICIT=1
        shift 2
        ;;
      --vertical-panel-count=*)
        MATRIX_ROWS="${1#*=}"
        MATRIX_ROWS_EXPLICIT=1
        shift
        ;;
      --vertical-panel-count)
        [[ $# -lt 2 ]] && err "Missing value for --vertical-panel-count"
        MATRIX_ROWS="$2"
        MATRIX_ROWS_EXPLICIT=1
        shift 2
        ;;
      --matrix-panel-width=*)
        MATRIX_PANEL_W="${1#*=}"
        MATRIX_PANEL_W_EXPLICIT=1
        shift
        ;;
      --matrix-panel-width)
        [[ $# -lt 2 ]] && err "Missing value for --matrix-panel-width"
        MATRIX_PANEL_W="$2"
        MATRIX_PANEL_W_EXPLICIT=1
        shift 2
        ;;
      --matrix-panel-height=*)
        MATRIX_PANEL_H="${1#*=}"
        MATRIX_PANEL_H_EXPLICIT=1
        shift
        ;;
      --matrix-panel-height)
        [[ $# -lt 2 ]] && err "Missing value for --matrix-panel-height"
        MATRIX_PANEL_H="$2"
        MATRIX_PANEL_H_EXPLICIT=1
        shift 2
        ;;
      *)
        if [[ -z "$device" ]]; then
          device="$1"
        else
          # All positionals after the role are tty devices (or, for the
          # "flash bootstrap <role>" dual form, a single production role).
          # Multiple ttys are flashed serially (see dispatch below).
          tty_args+=("$1")
        fi
        shift
        ;;
    esac
  done

  # First tty positional feeds the existing single-device paths (matrix check,
  # bootstrap-vs-role detection, auto-resolve when omitted).
  tty_device_or_role="${tty_args[0]:-}"

  if [[ -z "$device" ]]; then
    help_flash
    exit 1
  fi

  if [[ -n "$MATRIX_COLS$MATRIX_ROWS$MATRIX_PANEL_W$MATRIX_PANEL_H" ]]; then
    if ! _flash_matrix_layout_applicable "$device" "$tty_device_or_role"; then
      warn "Matrix layout options (--horizontal-panel-count, --vertical-panel-count, --matrix-panel-width, --matrix-panel-height) apply only to matrixdisplay; ignoring"
      MATRIX_COLS=""
      MATRIX_ROWS=""
      MATRIX_PANEL_W=""
      MATRIX_PANEL_H=""
    fi
  fi

  # Special handling for "bootstrap" role
  if [[ "$device" == "bootstrap" ]]; then
    # Check if second arg is a production role (dual-flash mode)
    if [[ -n "$tty_device_or_role" && ! "$tty_device_or_role" =~ ^/dev/ ]]; then
      # Dual-flash: bootstrap + production role
      local production_role="$tty_device_or_role"
      _flash_recovery_dual "$production_role"
    elif [[ ${#tty_args[@]} -gt 1 ]]; then
      # Multiple explicit ttys: flash bootstrap to each, one at a time.
      _flash_serial_batch "bootstrap" bootstrap "" "" "${tty_args[@]}"
    else
      # Single flash: bootstrap only (auto-detect when tty omitted)
      _flash_recovery "$tty_device_or_role"
    fi
    return
  fi

  # For production roles: auto-resolve USB tty when omitted (NVS device_role, else chip variant).
  if [[ -z "$tty_device_or_role" ]]; then
    local resolved_tty=""
    if resolved_tty=$(_resolve_flash_tty_for_role "$device" 2>/dev/null); then
      tty_device_or_role="$resolved_tty"
    fi
  fi

  # Production roles: serial = partition table + bootstrap only; production via OTA.
  # Multiple explicit tty devices are flashed one at a time (serially), never in
  # parallel -- each device completes its full bootstrap+OTA cycle before the next.
  if [[ ${#tty_args[@]} -gt 1 ]]; then
    _flash_serial_batch "$device" production "$device" "$skip_recovery" "${tty_args[@]}"
    return
  fi
  _flash_production_smart "$device" "$tty_device_or_role" "$skip_recovery"
}

_flash_serial_log_teardown() {
  create_log_serial_capture_stop
}

_flash_serial_log_setup() {
  # With --create-log, capture firmware serial output to iotstack-<guid>-serial.log.
  local tty="$1"
  local variant="${2:-}"
  create_log_serial_capture_enabled || return 0
  [[ -n "$tty" && -e "$tty" ]] || return 0

  export IOTSTACK_FLASH_SERIAL_VARIANT="${variant:-${IOTSTACK_ESPTOOL_CHIP:-unknown}}"
  export IOTSTACK_FLASH_SERIAL_LABEL="bootstrap"

  if [[ -z "${_FLASH_SERIAL_LOG_TRAP_REGISTERED:-}" ]]; then
    local prior_cmd=""
    if trap -p EXIT 2>/dev/null | grep -q .; then
      prior_cmd=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")
    fi
    if [[ -n "$prior_cmd" ]]; then
      # shellcheck disable=SC2064
      trap '_flash_serial_log_teardown; eval "$_FLASH_SERIAL_LOG_PRIOR_EXIT"' EXIT
      export _FLASH_SERIAL_LOG_PRIOR_EXIT="$prior_cmd"
    else
      trap '_flash_serial_log_teardown' EXIT
    fi
    export _FLASH_SERIAL_LOG_TRAP_REGISTERED=1
  fi

  create_log_serial_capture_start "$tty" "$IOTSTACK_FLASH_SERIAL_VARIANT"
  if [[ -z "${_FLASH_SERIAL_LOG_ANNOUNCED:-}" && -n "${IOTSTACK_SERIAL_LOG_FILE:-}" ]]; then
    info "Device serial log: ${IOTSTACK_SERIAL_LOG_FILE}"
    export _FLASH_SERIAL_LOG_ANNOUNCED=1
  fi
}

_flash_warn_start_serial_logs() {
  # Bootstrap did not reach WiFi/OTA -- serial output shows boot, NVS, and WiFi errors.
  local tty_device="$1"
  [[ -n "$tty_device" ]] || return 0
  [[ $QUIET -eq 0 ]] || return 0
  if [[ -n "${IOTSTACK_SERIAL_LOG_FILE:-}" && -f "${IOTSTACK_SERIAL_LOG_FILE}" ]]; then
    warn "Review captured device serial log: ${IOTSTACK_SERIAL_LOG_FILE}"
    return 0
  fi
  local msg="WARNING: START 'iotstack logs ${tty_device}' IN ANOTHER TERMINAL NOW TO DIAGNOSE BOOT / WIFI / NVS"
  _iotstack_log_plain "WARN" "$msg"
  _iotstack_echo stderr "${YLW}[WARN]${RST} ${RED}${msg}${RST}"
}

_flash_bootstrap_await_wifi() {
  # Wait for bootstrap OTA on WiFi after a serial flash. The XIAO ESP32-C6
  # USB-Serial/JTAG auto-reset is unreliable (a single reset boots the app only
  # ~half the time), so on timeout we re-issue the reset and re-check several
  # times before asking for a manual RESET -- driving the manual-RESET
  # probability under 1% (see _BOOTSTRAP_REBOOT_RETRIES). Only re-reset while the
  # device has NOT appeared, and give each boot enough time to reach WiFi so a
  # device that was about to come up is not knocked back into the bootloader.
  local device_mac="$1"
  local tty_device="$2"
  local hostname
  hostname=$(iotstack_bootstrap_hostname "$device_mac")

  info "Waiting for ${hostname} on WiFi (OTA port 3232)..."
  if _wait_for_ota_service "$hostname" "$_BOOTSTRAP_WIFI_READY_TIMEOUT_SEC"; then
    ok "Bootstrap OTA service reachable on WiFi"
    return 0
  fi

  if [[ -n "$tty_device" ]]; then
    local chip="${IOTSTACK_ESPTOOL_CHIP:-esp32c6}"
    local attempt reset_tty
    # esptool needs exclusive access to the port; pause serial-log capture for
    # the retry sequence (the device is not producing useful logs if it did not
    # boot anyway).
    create_log_serial_capture_pause
    for attempt in $(seq 1 "$_BOOTSTRAP_REBOOT_RETRIES"); do
      # The C6 re-enumerates on reset and can land on a different /dev/ttyACM*;
      # resolve the stable by-id node so the reset is never sent to a stale port.
      reset_tty=$(create_log_serial_stable_tty "$tty_device")
      # Report whether the reset actually reached the device (esp_esptool_hard_reset
      # returns non-zero if it could not connect) vs. reached it but did not boot --
      # the two failure modes need different fixes, so do not swallow the result.
      if esp_esptool_hard_reset "$reset_tty" "$chip"; then
        info "${hostname} not on WiFi -- reset delivered on ${reset_tty} (attempt ${attempt}/${_BOOTSTRAP_REBOOT_RETRIES}); waiting..."
      else
        warn "${hostname} not on WiFi -- reset could NOT reach the device on ${reset_tty} (attempt ${attempt}/${_BOOTSTRAP_REBOOT_RETRIES})"
      fi
      if _wait_for_ota_service "$hostname" "$_BOOTSTRAP_REBOOT_RETRY_TIMEOUT_SEC"; then
        create_log_serial_capture_resume
        ok "Bootstrap OTA service reachable on WiFi (after ${attempt} reset attempt(s))"
        return 0
      fi
    done
    warn "[ACTION REQUIRED] ${hostname} still not on WiFi after ${_BOOTSTRAP_REBOOT_RETRIES} auto-reset attempts -- press the RESET button on the board now."
    warn "  (XIAO ESP32-C6 USB auto-reset is unreliable. If it still will not connect: hold BOOT, tap RESET, release BOOT.)"
    if _wait_for_ota_service "$hostname" "$_BOOTSTRAP_MANUAL_RESET_TIMEOUT_SEC"; then
      create_log_serial_capture_resume
      ok "Bootstrap OTA service reachable on WiFi (after manual RESET)"
      return 0
    fi
    create_log_serial_capture_resume
  fi

  _flash_warn_start_serial_logs "$tty_device"
  if [[ "${IOTSTACK_NVS_PROVISIONED_VIA_USB:-0}" == "1" && "${FLASH_ERASE:-0}" != "1" ]]; then
    warn "Bootstrap API unavailable -- writing NVS via USB on ${tty_device} (required on first provision)"
  fi
  err "Bootstrap WiFi wait timed out -- ${hostname} OTA port 3232 not reachable after ${_BOOTSTRAP_REBOOT_RETRIES} auto-reset attempts and a manual RESET prompt"
}

# User-facing deploy sub-messages (indented under the active flash step).
_flash_msg_erase() {
  info "Erasing flash on ${1}..."
}

_flash_msg_prepare_usb() {
  local tty="$1" mac="${2:-}"
  if [[ -n "$mac" ]]; then
    info "Preparing device ${mac} on ${tty}..."
  else
    info "Preparing device on ${tty}..."
  fi
}

_flash_msg_wait_online() {
  info "Waiting for bootstrap-${1} on WiFi (OTA port 3232)..."
}

_flash_msg_ota_production() {
  info "iotstack update ${2} ${1} (production partition via bootstrap OTA)..."
}

_flash_msg_waiting_for_upload() {
  info "Waiting for bootstrap-${1} OTA service (port 3232)..."
}

_flash_bootstrap_esptool() {
  # Serial flash only: bootloader, partition table, boot_app0, bootstrap app.
  # Production partition is never written over USB (OTA after bootstrap boots).
  # Does not reset the chip -- write-nvs-secrets.sh or firmware write hard-resets.
  # Sets esptool_output. Usage: _flash_bootstrap_esptool <tty> <flash_log> <build_dir>
  #   <bootstrap_offset> [erase:0|1] [include_firmware:0|1]
  local tty_device="$1"
  local flash_log="$2"
  local build_dir="$3"
  local bootstrap_offset="$4"
  local erase_flash="${5:-1}"
  local include_firmware="${6:-1}"
  local esptool_chip="${IOTSTACK_ESPTOOL_CHIP:-esp32c6}"
  local flash_mode flash_freq flash_size
  local esptool_baud
  esptool_baud=$(esp_esptool_baud_for_chip "$esptool_chip")
  esp_esptool_flash_params_for_build "$build_dir" flash_mode flash_freq flash_size
  debug "esptool write-flash params: mode=${flash_mode} freq=${flash_freq} size=${flash_size}"

  local esptool_src="esptool:${esptool_chip}"

  create_log_serial_capture_pause

  if [[ "$erase_flash" == "1" ]]; then
    info "Erasing flash memory (${esptool_chip}, ${flash_size}, ${esptool_baud} baud)..."
    local erase_start=$SECONDS
    create_log_run_esptool "$esptool_src" "$flash_log" \
      --chip "$esptool_chip" --port "$tty_device" --baud "$esptool_baud" \
      --before default-reset --after no-reset erase-flash \
      || err "Erase failed"
    info "Flash erase completed in $((SECONDS - erase_start))s"
    sleep 3
  else
    warn "Skipping flash erase (not required for this update)"
  fi

  local ota_init_bin="" ota_init_label="ota_data_initial.bin"
  ota_init_bin=$(esp_ota_init_bin_for_build "$build_dir" 2>/dev/null) || true
  [[ -z "$ota_init_bin" ]] && warn "OTA init image not found (ota_data_initial.bin / boot_app0.bin) -- device may not boot into bootstrap OTA slot"
  [[ -n "$ota_init_bin" ]] && ota_init_label=$(esp_ota_init_bin_label "$ota_init_bin")

  local -a esptool_base_args=(
    --chip "$esptool_chip" --port "$tty_device" --baud "$esptool_baud"
  )
  local -a write_flash_opts=(
    write-flash --flash-mode "$flash_mode" --flash-size "$flash_size" --flash-freq "$flash_freq"
  )
  if [[ $VERBOSE -eq 1 ]] && ! create_log_enabled; then
    info "Detailed output: tail -f $flash_log"
  fi

  _flash_esptool_write_step() {
    local step_name="$1"
    local before_mode="$2"
    shift 2
    info "Writing ${step_name} (${esptool_chip}, ${esptool_baud} baud)..."
    local step_start=$SECONDS
    create_log_run_esptool "$esptool_src" "$flash_log" \
      "${esptool_base_args[@]}" \
      --before "$before_mode" --after no-reset \
      "${write_flash_opts[@]}" \
      "$@" \
      || err "${step_name} write failed"
    info "${step_name} write completed in $((SECONDS - step_start))s"
  }

  if esp_esptool_usb_cdc_chip "$esptool_chip"; then
    # USB CDC (S3/S2): batch layout images -- chained no-reset reconnects fail.
    local -a batch_args=(0x0 "$build_dir/bootloader.bin" 0x8000 "$build_dir/partitions.bin")
    local batch_label="bootloader.bin, partitions.bin"
    if [[ -n "$ota_init_bin" ]]; then
      batch_args+=(0xd000 "$ota_init_bin")
      batch_label+=", ${ota_init_label}"
    fi
    if [[ "$include_firmware" == "1" ]]; then
      batch_args+=("$bootstrap_offset" "$build_dir/firmware.bin")
      batch_label+=", firmware.bin"
    fi
    _flash_esptool_write_step "$batch_label" default-reset "${batch_args[@]}"
    [[ "$include_firmware" == "1" ]] && esptool_output="$create_log_esptool_output"
  else
    _flash_esptool_write_step "bootloader.bin" default-reset 0x0 "$build_dir/bootloader.bin"
    _flash_esptool_write_step "partitions.bin" no-reset 0x8000 "$build_dir/partitions.bin"
    if [[ -n "$ota_init_bin" ]]; then
      _flash_esptool_write_step "$ota_init_label" no-reset 0xd000 "$ota_init_bin"
    fi
    if [[ "$include_firmware" == "1" ]]; then
      _flash_esptool_write_step "firmware.bin" no-reset "$bootstrap_offset" "$build_dir/firmware.bin"
      esptool_output="$create_log_esptool_output"
    fi
  fi
  # Layout-only flash (--erase path): no firmware yet; device ROM-boot-loops. Keep
  # serial capture paused so esptool can run chip-id/NVS/firmware steps and the
  # serial log is not flooded with reset spam.
  if [[ "$include_firmware" == "1" ]]; then
    create_log_serial_capture_resume
  fi
}

_flash_bootstrap_esptool_write_firmware() {
  # Write bootstrap firmware.bin after NVS is populated (--erase first provision).
  # Usage: _flash_bootstrap_esptool_write_firmware <tty> <flash_log> <build_dir>
  #   <bootstrap_offset> [after_reset:no-reset|hard-reset]
  local tty_device="$1"
  local flash_log="$2"
  local build_dir="$3"
  local bootstrap_offset="$4"
  local after_reset="${5:-no-reset}"
  local esptool_chip="${IOTSTACK_ESPTOOL_CHIP:-esp32c6}"
  local flash_mode flash_freq flash_size
  local esptool_baud
  esptool_baud=$(esp_esptool_baud_for_chip "$esptool_chip")
  esp_esptool_flash_params_for_build "$build_dir" flash_mode flash_freq flash_size
  debug "esptool firmware write params: mode=${flash_mode} freq=${flash_freq} size=${flash_size}"
  local esptool_src="esptool:${esptool_chip}"
  local -a esptool_base_args=(
    --chip "$esptool_chip" --port "$tty_device" --baud "$esptool_baud"
  )
  local -a write_flash_opts=(
    write-flash --flash-mode "$flash_mode" --flash-size "$flash_size" --flash-freq "$flash_freq"
  )

  local before_mode
  before_mode=$(esp_esptool_chained_before_mode "$esptool_chip")

  # Booting the freshly written firmware on a USB-Serial/JTAG chip (C6): the
  # inline RTS hard-reset from the flasher stub does not reliably start the app
  # (and watchdog reset is unsupported on the C6). Write with no reset, then
  # reboot via esp_esptool_hard_reset -- a separate default-reset/hard-reset
  # cycle (with retries) that does boot these chips; it is the same reboot the
  # non-erase NVS path uses successfully. Other chips keep the inline reset.
  local reboot_via_helper=false
  if [[ "$after_reset" == "hard-reset" ]] && esp_esptool_usb_jtag_chip "$esptool_chip"; then
    after_reset=no-reset
    reboot_via_helper=true
  fi

  create_log_serial_capture_pause
  info "Writing firmware.bin (${esptool_chip}, ${esptool_baud} baud)..."
  local step_start=$SECONDS
  create_log_run_esptool "$esptool_src" "$flash_log" \
    "${esptool_base_args[@]}" \
    --before "$before_mode" --after "$after_reset" \
    "${write_flash_opts[@]}" \
    "$bootstrap_offset" "$build_dir/firmware.bin" \
    || err "firmware.bin write failed"
  info "firmware.bin write completed in $((SECONDS - step_start))s"
  esptool_output="$create_log_esptool_output"
  if [[ "$reboot_via_helper" == true ]]; then
    info "Rebooting ${esptool_chip} into firmware..."
    esp_esptool_hard_reset "$tty_device" "$esptool_chip" \
      || warn "reboot into firmware may not have taken -- device might need a manual RESET press"
  fi
  create_log_serial_capture_resume
}

_flash_prepare_builds() {
  # Compile bootstrap (and optionally production) for a USB port before device assessment.
  # Usage: _flash_prepare_builds <tty> [production_role] [production_yaml_path]
  local tty_device="$1"
  local production_role="${2:-}"
  local yaml_path="${3:-}"
  local profile variant board flash_size framework bootstrap_yaml build_name device_name

  [[ -n "$tty_device" && -e "$tty_device" ]] || {
    echo "TTY device not found: ${tty_device:-<unset>}" >&2
    return 1
  }

  # When production_role is known, profile comes from role YAML -- defer USB chip-id
  # until flash assessment so esptool does not leave S3 in bootloader during compile.
  if [[ -n "$production_role" ]]; then
    profile=$(bootstrap_profile_emit_from_role "$production_role") || return 1
  else
    profile=$(bootstrap_resolve_profile "$tty_device" "") || return 1
  fi
  bootstrap_apply_profile_to_env "$profile"
  variant=$(echo "$profile" | cut -d'|' -f1)
  board=$(echo "$profile" | cut -d'|' -f2)
  flash_size=$(echo "$profile" | cut -d'|' -f3)
  framework=$(echo "$profile" | cut -d'|' -f4)
  bootstrap_yaml="${YAMLS_DIR}/$(iotstack_bootstrap_artifact_name "$variant")"
  bootstrap_render_yaml "$variant" "$board" "$flash_size" "$framework" >/dev/null || return 1
  iotstack_register_yaml_cleanup_trap
  build_name="bootstrap"

  if [[ $CLEAN_BUILD_DIRECTORY -eq 1 ]]; then
    info "Cleaning build directory (CLEAN_BUILD_DIRECTORY=1)..."
    rm -rf "$ESPHOME_BUILD_DIR"
    ok "Build directory cleaned"
  fi

  info "Project version: $(iotstack_project_version)"

  if [[ -n "$yaml_path" ]]; then
    device_name=$(basename "$yaml_path" .yaml)
    debug "Compile bootstrap + ${device_name} for ${variant} (USB chip verify deferred until after build)"
  else
    debug "Compile bootstrap for ${variant} (USB chip verify deferred until after build)"
  fi

  smart_compile "$bootstrap_yaml" "$build_name" || return 1

  if [[ -n "$yaml_path" ]]; then
    info "Compiling production image (${device_name}); iotstack flash installs it via OTA (USB writes bootstrap only)"
    smart_compile "$yaml_path" "$device_name" || return 1
    _flash_sync_update_devices_cache "$yaml_path"
  fi

  return 0
}

_flash_prepare_builds_for_targets() {
  # Compile once per chip variant before flashing multiple USB devices.
  local production_role="$1"
  local yaml_path="${2:-}"
  shift 2 || true
  local -a targets=("$@")
  local -A variants_prepared=()
  local tty profile variant

  [[ ${#targets[@]} -gt 0 ]] || return 0

  if [[ -n "$production_role" ]]; then
    _flash_prepare_builds "${targets[0]}" "$production_role" "$yaml_path" || return 1
    return 0
  fi

  for tty in "${targets[@]}"; do
    profile=$(bootstrap_resolve_profile "$tty" "") || return 1
    variant=$(echo "$profile" | cut -d'|' -f1)
    [[ -n "${variants_prepared[$variant]:-}" ]] && continue
    _flash_prepare_builds "$tty" "" "$yaml_path" || return 1
    variants_prepared[$variant]=1
  done
}

_flash_bootstrap_to_tty() {
  # Serial: partition table + bootstrap partition, NVS over USB, wait for bootstrap WiFi.
  # Production is OTA-only (caller runs _flash_ota_step_begin afterward).
  # Returns MAC suffix via stdout or mac_return_file.
  local tty_device="$1"
  local mac_return_file="${2:-}"
  local production_role="${3:-}"
  local bootstrap_yaml build_name profile variant board flash_size framework

  profile=$(bootstrap_resolve_profile "$tty_device" "$production_role") || return 1
  bootstrap_apply_profile_to_env "$profile"
  variant=$(echo "$profile" | cut -d'|' -f1)
  board=$(echo "$profile" | cut -d'|' -f2)
  flash_size=$(echo "$profile" | cut -d'|' -f3)
  framework=$(echo "$profile" | cut -d'|' -f4)
  bootstrap_yaml="${YAMLS_DIR}/$(iotstack_bootstrap_artifact_name "$variant")"
  bootstrap_render_yaml "$variant" "$board" "$flash_size" "$framework" >/dev/null || return 1
  iotstack_register_yaml_cleanup_trap
  build_name="bootstrap"

  local build_dir_early="${YAMLS_DIR}/.esphome/build/${build_name}/.pioenvs/${build_name}"
  if [[ ! -f "${build_dir_early}/firmware.bin" ]]; then
    debug "Bootstrap firmware not pre-built -- compiling for ${variant}"
    smart_compile "$bootstrap_yaml" "$build_name" || return 1
  fi

  debug "Recovery image: ${variant} on ${tty_device}"
  debug "YAML: ${bootstrap_yaml#"${YAMLS_DIR%/*}/"}"

  local flash_log_dir="$HOME/.iotstack/logs/flash"
  mkdir -p "$flash_log_dir"
  local flash_log
  if create_log_enabled; then
    flash_log="${IOTSTACK_LOG_FILE}"
  else
    flash_log="$flash_log_dir/$(date +%Y%m%d_%H%M%S)-${variant}-$(basename "$tty_device").log"
  fi

  local build_dir="$YAMLS_DIR/.esphome/build/${build_name}/.pioenvs/${build_name}"
  [[ ! -d "$build_dir" ]] && err "Build directory not found: $build_dir"

  local bootstrap_offset
  bootstrap_offset=$(flash_partition_offset bootstrap 2>/dev/null) || true
  [[ -z "$bootstrap_offset" ]] && err "Could not resolve bootstrap partition offset (build bootstrap/partitions.csv or ${PARTITION_TABLE})"

  local esptool_chip="${IOTSTACK_ESPTOOL_CHIP:-$variant}"
  local device_mac=""
  device_mac=$(esp_mac_suffix_from_port "$tty_device" 2>/dev/null) || device_mac=""
  flash_assess_bootstrap_device "$tty_device" "$esptool_chip" "$build_dir" "$bootstrap_offset" "$device_mac"

  _flash_serial_log_setup "$tty_device" "$variant"
  _check_serial_port_in_use "$tty_device"

  local skip_serial="$FLASH_ASSESS_SKIP_SERIAL"
  if [[ "$skip_serial" -eq 1 ]]; then
    if [[ "${FLASH_ASSESS_VIA_MDNS:-0}" -eq 1 ]]; then
      info "Bootstrap image on device matches build (mDNS config_hash) -- serial upload not required"
    else
      info "Bootstrap image on device matches build -- serial upload not required"
    fi
    debug "On-device partition table also matches compiled build"
    device_mac=$(esp_mac_suffix_resolve "$tty_device") || err "Could not read chip MAC from $tty_device"
    ok "Device MAC: $device_mac"

    _flash_nvs_step_begin
    _provision_device_nvs "$tty_device" "$device_mac" "$production_role" || \
      err "Failed to provision device NVS"

    info "Waiting for device to boot..."
    sleep 3

    if [[ -n "$device_mac" ]]; then
      _flash_bootstrap_await_wifi "$device_mac" "$tty_device"
    fi
  else
    if [[ "${FLASH_ERASE:-0}" != "1" ]]; then
      if [[ "$FLASH_ASSESS_BOOTSTRAP_MATCH" -eq 0 ]]; then
        info "Bootstrap image on device differs from build -- serial upload required"
      elif [[ "$FLASH_ASSESS_PARTITION_MATCH" -eq 0 ]]; then
        info "On-device partition table differs from build -- serial upload required"
      fi
    fi
    if [[ "${FLASH_ERASE:-0}" == "1" ]]; then
      _flash_bootstrap_esptool "$tty_device" "$flash_log" "$build_dir" "$bootstrap_offset" \
        "$FLASH_ASSESS_NEED_ERASE" 0
      if [[ -z "$device_mac" ]]; then
        local _post_layout_timeout="${IOTSTACK_POST_LAYOUT_USB_TIMEOUT_SEC:-45}"
        local _post_layout_mac_rc=0
        info "Reading chip MAC from ${tty_device} after layout flash (timeout ${_post_layout_timeout}s)..."
        device_mac=$(esp_mac_suffix_resolve_timeout "$tty_device" "" "$_post_layout_timeout") \
          || _post_layout_mac_rc=$?
        if [[ -z "$device_mac" ]]; then
          if [[ $_post_layout_mac_rc -eq 124 ]]; then
            err "Timed out reading chip MAC from ${tty_device} after layout flash (${_post_layout_timeout}s)"
          fi
          err "Failed to extract MAC address from device (try: esptool --port $tty_device chip-id)"
        fi
      else
        debug "Reusing chip MAC ${device_mac} from preflight (skip chip-id after layout flash)"
      fi

      _flash_nvs_step_begin
      _provision_device_nvs "$tty_device" "$device_mac" "$production_role" || \
        err "Failed to provision device NVS"

      _flash_bootstrap_esptool_write_firmware "$tty_device" "$flash_log" "$build_dir" \
        "$bootstrap_offset" hard-reset
      ok "Device ${device_mac} prepared for firmware update"

      if [[ -n "$device_mac" ]]; then
        _flash_bootstrap_await_wifi "$device_mac" "$tty_device"
      else
        err "MAC unknown after serial bootstrap flash -- cannot verify bootstrap WiFi"
      fi
    else
      _flash_bootstrap_esptool "$tty_device" "$flash_log" "$build_dir" "$bootstrap_offset" \
        "$FLASH_ASSESS_NEED_ERASE"
      device_mac=$(esp_mac_suffix_resolve "$tty_device" "$create_log_esptool_output") \
        || err "Failed to extract MAC address from device (try: esptool --port $tty_device chip-id)"
      ok "Device ${device_mac} prepared for firmware update"

      _flash_nvs_step_begin
      _provision_device_nvs "$tty_device" "$device_mac" "$production_role" || \
        err "Failed to provision device NVS"

      info "Waiting for device to boot..."
      sleep 3

      if [[ -n "$device_mac" ]]; then
        _flash_bootstrap_await_wifi "$device_mac" "$tty_device"
      else
        err "MAC unknown after serial bootstrap flash -- cannot verify bootstrap WiFi"
      fi
    fi
  fi

  if [[ -n "$mac_return_file" ]]; then
    printf '%s' "$device_mac" > "$mac_return_file"
  else
    printf '%s' "$device_mac"
  fi
}

_flash_recovery() {
  # Flash recovery image via serial and return the device's MAC suffix.
  # When mac_return_file is provided the MAC is written there (allows calling
  # without command substitution so all user output reaches the terminal).
  # production_role is passed to write-nvs-secrets.sh so both bootstrap- and
  # production-derived secrets are written to NVS in a single flash.
  # Optional 4th arg "nested": skip banners/steps/prepare (caller already built).
  local tty_device="$1"
  local mac_return_file="${2:-}"
  local production_role="${3:-}"
  local nested="${4:-}"

  if [[ "$nested" != "nested" ]]; then
    _flash_step_reset
    info "Serial flash: partition table and bootstrap only (production via OTA)"
    echo ""
  fi

  if [[ ! -f "$BOOTSTRAP_TEMPLATE" && ! -f "${YAMLS_DIR}/bootstrap.yaml" ]]; then
    err "Bootstrap template not found: ${YAMLS_DIR}/bootstrap.yaml"
  fi

  local yaml_for_role=""
  if [[ -n "$production_role" ]]; then
    yaml_for_role=$(resolve_device "$production_role" false) || true
  fi

  if [[ -n "$tty_device" ]]; then
    if [[ ! -e "$tty_device" ]]; then
      err "TTY device not found: $tty_device"
    fi
    if [[ "$nested" != "nested" ]]; then
      _flash_step_begin "Build firmware"
      _flash_prepare_builds "$tty_device" "$production_role" "$yaml_for_role" \
        || err "Firmware build failed"
      ok "Firmware builds ready"
      _flash_serial_step_begin
      info "Target port: ${tty_device}"
    fi
    _flash_bootstrap_to_tty "$tty_device" "$mac_return_file" "$production_role"
    return
  fi

  # Auto-detect USB serial devices (per-port chip variant)
  local tty_devices=()
  local dev
  for dev in /dev/ttyACM* /dev/ttyUSB*; do
    [[ -e "$dev" ]] && tty_devices+=("$dev")
  done

  if [[ ${#tty_devices[@]} -eq 0 ]]; then
    local vm_warning=""
    if pgrep -l "VirtualBox|qemu|vboxheadless" >/dev/null 2>&1; then
      vm_warning=$'\n\n[WARN] Virtual machine(s) detected. USB devices may be passed through to a VM.\n   Stop the VM or disconnect devices from it to use them on the host.'
    fi
    err "No USB serial devices found. Plug in device(s) and try again.${vm_warning}"
  fi

  info "Found ${#tty_devices[@]} USB device(s): ${tty_devices[*]}"

  local expected_variant=""
  if [[ -n "$production_role" ]]; then
    expected_variant=$(yaml_variant_for_role "$production_role" 2>/dev/null) || true
    [[ -n "$expected_variant" ]] && info "Filtering for role '$production_role' (${expected_variant})"
  fi

  local -a targets=()
  local tty port_variant
  for tty in "${tty_devices[@]}"; do
    port_variant=$(esp_detect_chip "$tty" 2>/dev/null) || {
      warn "Skipping $tty (could not detect chip)"
      continue
    }
    if [[ -n "$expected_variant" && "$port_variant" != "$expected_variant" ]]; then
      info "Skipping $tty (${port_variant}) -- role '$production_role' needs ${expected_variant}"
      continue
    fi
    targets+=("$tty")
  done

  if [[ ${#targets[@]} -eq 0 ]]; then
    if [[ -n "$production_role" ]]; then
      err "No USB devices match role '${production_role}' (${expected_variant})"
    else
      err "No flashable USB devices found"
    fi
  fi

  confirm_multi_device ${#targets[@]} "$(printf '%s\n' "${targets[@]}")"

  _flash_step_begin "Build firmware"
  _flash_prepare_builds_for_targets "$production_role" "$yaml_for_role" "${targets[@]}" \
    || err "Firmware build failed"
  ok "Firmware builds ready"
  _flash_serial_step_begin

  local failed=0
  local successful_ttys=()
  for tty in "${targets[@]}"; do
    echo ""
    info "Flashing ${tty}..."
    echo "========================================================"
    if _flash_bootstrap_to_tty "$tty" "" "$production_role"; then
      successful_ttys+=("$tty")
    else
      warn "Recovery flash FAILED on $tty"
      failed=$((failed + 1))
    fi
    echo "========================================================"
  done

  if [[ $failed -gt 0 ]]; then
    err "Failed to flash recovery to $failed device(s)"
  fi

  ok "Bootstrap firmware flashed to ${#targets[@]} device(s)"
  if [[ ${#successful_ttys[@]} -gt 1 ]]; then
    echo ""
    info "Waiting 15s for ${#successful_ttys[@]} devices to connect..."
    sleep 15
  fi
}

_flash_recovery_dual() {
  # Dual-flash: recovery via serial + production role via OTA
  # Usage: iotstack flash recovery mmwave
  local production_role="$1"

  # First: flash recovery via serial (only USB ports matching production chip)
  _flash_recovery "" "" "$production_role"

  # Brief pause so mDNS advertisement propagates after WiFi connects.
  sleep 2

  _flash_ota_step_begin

  # Discover recovery devices (bootstrap advertises _iotstack-bootstrap._tcp)
  local recovery_macs=()
  while IFS= read -r line; do
    if [[ "$line" =~ bootstrap-([0-9a-f]+) ]]; then
      recovery_macs+=("${BASH_REMATCH[1]}")
    fi
  done < <(avahi-browse -t -r "$(iotstack_bootstrap_mdns_service)" 2>/dev/null)

  if [[ ${#recovery_macs[@]} -eq 0 ]]; then
    err "No recovery devices found on network. Check WiFi connection."
  fi

  local yaml_file
  yaml_file=$(resolve_device "$production_role" false) || err "Unknown role: $production_role"

  _update_via_bootstrap "$production_role" "$yaml_file" "${recovery_macs[@]}" -- --upgrade-delta \
    || err "iotstack update failed"

  _flash_step_begin "Set boot partition to production"
  info "Toggling boot partition on flashed devices..."

  # Discover recovery devices and toggle them (bootstrap advertises _iotstack-bootstrap._tcp)
  local recovery_devices=()
  while IFS= read -r line; do
    if [[ "$line" =~ bootstrap-([0-9a-f]+) ]]; then
      recovery_devices+=("${BASH_REMATCH[1]}")
    fi
  done < <(avahi-browse -t -r "$(iotstack_bootstrap_mdns_service)" 2>/dev/null)

  if [[ ${#recovery_devices[@]} -gt 0 ]]; then
    # Try to toggle via Home Assistant first
    local ha_url=""
    local ha_token=""
    if _load_ha_credentials_optional; then
      ha_url="$HA_URL"
      ha_token="$HA_TOKEN"
    fi

    if [[ -n "$ha_url" && -n "$ha_token" ]]; then
      export HA_URL="$ha_url"
      export HA_TOKEN="$ha_token"
      # Call the partition toggle button via Home Assistant WebSocket API
      for mac in "${recovery_devices[@]}"; do
        local device_name="$(iotstack_bootstrap_hostname "$mac")"
        local entity_id="button.${device_name,,}_toggle_boot_partition"

        info "Toggling partition on $device_name (via HA WebSocket)..."
        if _ha_websocket_call_service "button" "press" "{\"entity_id\": [\"$entity_id\"]}"; then
          ok "  Partition toggled, device rebooting..."
        else
          warn "  Could not toggle partition via HA (continuing anyway)"
        fi
      done
    else
      # Fallback: toggle via ESPHome API directly on device
      for mac in "${recovery_devices[@]}"; do
        local device_name="$(iotstack_bootstrap_hostname "$mac")"
        local device_host="${device_name}.local"

        info "Toggling partition on $device_name (via ESPHome API)..."

        # Try to reach the device and trigger the button via ESPHome's native API
        # This uses curl to POST to the button service on the device
        if curl -s -X POST "http://$device_host/api/services/button/press" \
          -H "Content-Type: application/json" \
          -d "{\"entity_id\": \"button.${device_name}_toggle_boot_partition\"}" \
          --max-time 5 >/dev/null 2>&1; then
          ok "  Partition toggled, device rebooting..."
        else
          # Last resort: manual instructions
          warn "  Could not reach device via API"
          warn "  Manual toggle: hold GPIO9 for 3+ seconds, or:"
          warn "  iotstack set-boot $mac production"
        fi
      done
    fi
  fi

  echo ""
  ok "Dual-flash complete: recovery + $production_role"
}

_flash_production_smart() {
  # iotstack flash never serial-writes production. USB writes partition table +
  # bootstrap only; production is always OTA after the device boots bootstrap.
  local device="$1"
  local tty_device="$2"
  local skip_recovery="$3"

  # Resolve device role to YAML path
  local yaml_path
  yaml_path=$(resolve_device "$device")

  # If TTY device specified: flash via serial (assume fresh device)
  if [[ -n "$tty_device" ]]; then
    if [[ ! -e "$tty_device" ]]; then
      err "TTY device not found: $tty_device"
    fi

    _flash_step_reset
    info "Flash target: ${device} on ${tty_device} (serial: bootstrap; production: OTA)"
    echo ""

    local conflict_pid=""
    conflict_pid=$(esp_flash_sessions_on_tty "$tty_device" | head -1) || true
    if [[ -n "$conflict_pid" ]]; then
      err "Another iotstack flash is already running on ${tty_device} (pid ${conflict_pid}). Wait for it to finish or stop it before starting a second flash."
    fi

    esp_serial_clear_tty_interference "$tty_device" "${IOTSTACK_FLASH_SESSION_PID:-}"
    esp_serial_wait_tty_free "$tty_device" 5 || true
    esp_serial_settle_tty "$tty_device" 2

    _flash_step_begin "Build firmware"
    if [[ "$skip_recovery" == "--ota-only" ]]; then
      info "Scope: production OTA only (--ota-only; no serial flash)"
      smart_compile "$yaml_path" "$device" || err "Production compile failed"
    else
      _flash_prepare_builds "$tty_device" "$device" "$yaml_path" || err "Firmware build failed"
    fi
    ok "Firmware builds ready (bootstrap serial + production OTA)"

    local device_mac="" prod_hostname=""
    if [[ "$skip_recovery" != "--ota-only" ]]; then
      _flash_step_begin "Assessing device"
      info "Port: ${tty_device}"
      # esptool chip-id needs exclusive TTY access; serial capture starts after MAC read.
      # One chip-id read yields both the MAC suffix and the connected chip variant.
      info "Reading chip MAC via USB..."
      local chipid_out=""
      chipid_out=$(esp_esptool_chip_id "$tty_device" 2>/dev/null) || chipid_out=""
      device_mac=$(esp_mac_from_esptool_output "$chipid_out" 2>/dev/null) || device_mac=""

      # Fail fast on a chip/role mismatch (e.g. an ESP32-C6 on the port for an
      # S3-only role): the role firmware is built for the wrong silicon and would
      # never run. The auto-discovery path filters ttys by variant; an explicitly
      # named tty bypasses that, so verify it here before any serial write.
      local expected_variant="" connected_variant=""
      expected_variant=$(yaml_variant_for_role "$device" 2>/dev/null) || expected_variant=""
      connected_variant=$(esp_variant_from_esptool_output "$chipid_out" 2>/dev/null) || connected_variant=""
      if [[ -n "$expected_variant" && -n "$connected_variant" \
            && "$connected_variant" != "$expected_variant" ]]; then
        err "Chip mismatch: ${tty_device} is a ${connected_variant}, but role '${device}' targets ${expected_variant}. Connect a ${expected_variant} board or check the port."
      fi

      if [[ -n "$device_mac" ]]; then
        prod_hostname="${device}-${device_mac}"
        if [[ "${FLASH_ERASE:-0}" == "1" ]]; then
          info "MAC suffix: ${device_mac}"
          info "Action: erase flash (due to --erase), then install bootstrap via USB, then ${device} via OTA."
        else
          _flash_assess_device_runtime "$device_mac" "$prod_hostname" "$tty_device"
          _flash_assess_device_on_flash_action "$tty_device" "$yaml_path" "$device_mac" "$prod_hostname"
        fi

        if [[ "${FLASH_ERASE:-0}" == "1" ]]; then
          _flash_serial_step_begin
          _flash_msg_erase "$tty_device"
          local _mac_file
          _mac_file=$(mktemp)
          _flash_bootstrap_to_tty "$tty_device" "$_mac_file" "$device" \
            || err "Serial erase/flash failed"
          if [[ -f "$_mac_file" ]]; then
            device_mac=$(tr -d '[:space:]' < "$_mac_file")
            rm -f "$_mac_file"
          fi
          FLASH_ASSESS_PROD_ONLINE=0
          FLASH_ASSESS_FLASH_CURRENT=0
          prod_hostname="${device}-${device_mac}"
        elif [[ $FLASH_ASSESS_FLASH_CURRENT -eq 1 && $FLASH_ASSESS_PROD_ONLINE -eq 1 ]]; then
          local img_hash layout_rc=0 want_cols want_rows want_w want_h
          set +e
          _flash_matrix_layout_update_via_bootstrap_if_needed "$device" "$tty_device" "$device_mac" "$prod_hostname"
          layout_rc=$?
          set -e
          if [[ $layout_rc -eq 1 ]]; then
            err "Matrix layout NVS update failed"
          fi
          _flash_resolve_matrix_layout "$device" want_cols want_rows want_w want_h
          img_hash=$(_production_running_image_hash "$prod_hostname" "$tty_device" "$yaml_path")
          if [[ $layout_rc -eq 2 ]]; then
            ok "Matrix layout updated on ${prod_hostname}: ${want_cols}x${want_rows} panel(s), ${want_w}x${want_h} px (config_hash ${img_hash})"
          else
            ok "Device ${prod_hostname} already running current ${device} firmware (config_hash ${img_hash})"
          fi
          _ha_after_production_online "$yaml_path" "$prod_hostname"
          ok "Production firmware setup complete!"
          return
        else
        local try_network_ota=false
        if _production_api_reachable "$prod_hostname"; then
          try_network_ota=true
        elif _wait_for_production_online "$prod_hostname" 15 && _production_api_reachable "$prod_hostname"; then
          try_network_ota=true
        fi

        if [[ "$try_network_ota" == true ]]; then
          if [[ $FLASH_ASSESS_FLASH_CURRENT -eq 1 && "${FLASH_ERASE:-0}" != "1" ]]; then
            local layout_rc=0 want_cols want_rows want_w want_h
            set +e
            _flash_matrix_layout_update_via_bootstrap_if_needed "$device" "$tty_device" "$device_mac" "$prod_hostname"
            layout_rc=$?
            set -e
            if [[ $layout_rc -eq 1 ]]; then
              err "Matrix layout NVS update failed"
            fi
            if [[ $layout_rc -eq 2 ]]; then
              _flash_resolve_matrix_layout "$device" want_cols want_rows want_w want_h
              ok "Matrix layout updated on ${prod_hostname}: ${want_cols}x${want_rows} panel(s), ${want_w}x${want_h} px"
            else
              ok "Production firmware already current -- OTA skipped"
            fi
            _ha_after_production_online "$yaml_path" "$prod_hostname"
            ok "Production firmware setup complete!"
            return
          fi
          _flash_ota_step_begin
          if _flash_invoke_update "$device_mac" "$yaml_path" "$device" "$tty_device"; then
            ok "Production firmware setup complete!"
            return
          fi
          warn "OTA failed -- serial bootstrap refresh on ${tty_device}"
          _flash_serial_step_begin
          _flash_msg_prepare_usb "$tty_device" "$device_mac"
          local _mac_file
          _mac_file=$(mktemp)
          _flash_bootstrap_to_tty "$tty_device" "$_mac_file" "$device" \
            || err "Serial flash failed"
          if [[ -f "$_mac_file" ]]; then
            device_mac=$(tr -d '[:space:]' < "$_mac_file")
            rm -f "$_mac_file"
          fi
        elif [[ $FLASH_ASSESS_PROD_MDNS -eq 1 ]] || _production_mdns_advertised "$prod_hostname"; then
          warn "Device visible on network but API unreachable -- serial bootstrap on ${tty_device}"
          _flash_serial_step_begin
          _flash_msg_prepare_usb "$tty_device" "$device_mac"
          local _mac_file
          _mac_file=$(mktemp)
          _flash_bootstrap_to_tty "$tty_device" "$_mac_file" "$device" \
            || err "Serial flash failed"
          if [[ -f "$_mac_file" ]]; then
            device_mac=$(tr -d '[:space:]' < "$_mac_file")
            rm -f "$_mac_file"
          fi
        elif [[ $FLASH_ASSESS_BOOTSTRAP_ONLINE -eq 1 ]] || _bootstrap_ota_reachable "$device_mac"; then
          info "Bootstrap-${device_mac} online -- refreshing serial layout if needed"
          _flash_serial_step_begin
          local _mac_file
          _mac_file=$(mktemp)
          _flash_bootstrap_to_tty "$tty_device" "$_mac_file" "$device" || rm -f "$_mac_file"
          if [[ -f "$_mac_file" ]]; then
            device_mac=$(tr -d '[:space:]' < "$_mac_file")
            rm -f "$_mac_file"
          fi
        else
          info "Device not on WiFi yet -- serial bootstrap provision on USB"
          _flash_serial_step_begin
          _flash_msg_prepare_usb "$tty_device" "$device_mac"
          local _mac_file
          _mac_file=$(mktemp)
          _flash_recovery "$tty_device" "$_mac_file" "$device" nested
          device_mac=$(tr -d '[:space:]' < "$_mac_file")
          rm -f "$_mac_file"
          _flash_msg_wait_online "$device_mac"
        fi
        fi
      else
        _flash_serial_step_begin
        info "Could not read device MAC -- serial bootstrap provision on USB"
        _flash_msg_prepare_usb "$tty_device"
        local _mac_file
        _mac_file=$(mktemp)
        _flash_recovery "$tty_device" "$_mac_file" "$device" nested
        device_mac=$(tr -d '[:space:]' < "$_mac_file")
        rm -f "$_mac_file"
        _flash_msg_wait_online "${device_mac:-unknown}"
      fi
    else
      info "Skipping device assessment (--ota-only flag)"
    fi

    # OTA production into the production partition (never serial).
    if [[ -n "$device_mac" ]]; then
      _flash_ota_step_begin
      device_mac=$(echo "$device_mac" | tr -d '[:space:]')
      local prod_hostname="${device}-${device_mac}"

      # Device may boot production while bootstrap partition on flash is unchanged
      # (skip-serial path). Never wait for bootstrap OTA in that case.
      if [[ "${FLASH_ERASE:-0}" != "1" ]] \
          && { [[ $FLASH_ASSESS_PROD_ONLINE -eq 1 ]] || _wait_for_production_online "$prod_hostname" 10; }; then
        if [[ $FLASH_ASSESS_FLASH_CURRENT -eq 0 ]]; then
          info "Reassessing device state..."
          _flash_report_device_assessment "$tty_device" "$yaml_path" "$device_mac" "$prod_hostname"
        fi
        if [[ $FLASH_ASSESS_FLASH_CURRENT -eq 1 ]]; then
          ok "Production firmware already current -- OTA skipped"
          _ha_after_production_online "$yaml_path" "$prod_hostname"
          ok "Production firmware setup complete!"
          return
        fi
        _flash_invoke_update "$device_mac" "$yaml_path" "$device" "$tty_device" \
          || err "iotstack update failed"
        ok "Production firmware setup complete!"
        return
      fi

      local production_build_name production_build_dir production_offset skip_update=0
      production_build_name=$(basename "$yaml_path" .yaml)
      debug "Using pre-built production firmware (${production_build_name})"
      production_build_dir="${YAMLS_DIR}/.esphome/build/${production_build_name}/.pioenvs/${production_build_name}"
      production_offset=$(awk -F',' '/^production[[:space:]]*,/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4}' "$PARTITION_TABLE" | head -1)

      if [[ "${FLASH_ON_FLASH_VERIFY:-0}" == "1" && -n "$production_offset" && -d "$production_build_dir" ]]; then
        local prod_chip="${IOTSTACK_ESPTOOL_CHIP:-}"
        [[ -z "$prod_chip" ]] && prod_chip=$(esp_detect_chip "$tty_device" 2>/dev/null) || true
        info "Reading on-flash production partition via USB (assessment only)..."
        if [[ -n "$prod_chip" ]] && flash_production_matches_device \
            "$tty_device" "$prod_chip" "$production_build_dir" "$production_offset"; then
          ok "Production partition matches build -- iotstack update skipped"
          skip_update=1
        fi
      elif [[ "${FLASH_ERASE:-0}" != "1" ]] \
          && _flash_production_matches_build "$prod_hostname" "$yaml_path" "$tty_device"; then
        ok "Production firmware already current -- iotstack update skipped"
        skip_update=1
      fi

      if [[ "$skip_update" -eq 1 ]]; then
        local network_type
        network_type=$(get_yaml_device_info "$yaml_path" | cut -d'|' -f3)
        if [[ "$network_type" == "thread" ]]; then
          info "Device already has current $device firmware (Thread mesh)"
        elif _wait_for_production_online "$prod_hostname" 30; then
          ok "Device online as $prod_hostname"
          _ha_after_production_online "$yaml_path" "$prod_hostname"
        else
          warn "Production firmware matches but $prod_hostname not on WiFi yet"
        fi
        ok "Production firmware setup complete!"
        return
      fi

      _flash_invoke_update "$device_mac" "$yaml_path" "$device" "$tty_device" \
        || err "iotstack update failed (device may still be booting; retry: iotstack update ${device} ${device_mac})"
    fi

    ok "Production firmware setup complete!"
    return
  fi

  # No TTY specified and auto-resolve failed
  err "Serial device required for flash command.
Usage: iotstack flash $device /dev/ttyUSB0

Auto-detect looks for NVS device_role on each USB port (set at first provision).
With multiple similar boards plugged in, specify the tty explicitly.
New/unprovisioned devices always need an explicit tty.

Note: Use 'iotstack update $device' for OTA flashing to devices already on network"
}

# -- Main ---------------------------------------------------------------------


verify_wifi_credentials() {
  # Check pass store for WiFi credentials
  # If missing, prompt user to provide them

  local has_ssid=false
  local has_password=false
  local wifi_ssid=""
  local wifi_password=""

  # Check pass store for WiFi SSID
  if pass show iotstack/common/wifi_ssid >/dev/null 2>&1; then
    wifi_ssid=$(pass show iotstack/common/wifi_ssid 2>/dev/null)
    has_ssid=true
    debug "Found WiFi SSID in pass store"
  fi

  # Check pass store for WiFi password
  if pass show iotstack/common/wifi_password >/dev/null 2>&1; then
    wifi_password=$(pass show iotstack/common/wifi_password 2>/dev/null)
    has_password=true
    debug "Found WiFi password in pass store"
  fi

  # If missing, prompt user
  if [[ "$has_ssid" == false ]] || [[ "$has_password" == false ]]; then
    warn "Missing WiFi credentials"
    echo ""

    if [[ "$has_ssid" == false ]]; then
      read -rp "Enter WiFi SSID: " wifi_ssid
      [[ -z "$wifi_ssid" ]] && err "WiFi SSID cannot be empty"
      { echo "$wifi_ssid"; echo "$wifi_ssid"; } | pass insert -f iotstack/common/wifi_ssid 2>&1 | grep -v "^mkdir:" || true
      debug "Stored WiFi SSID in pass store"
    fi

    if [[ "$has_password" == false ]]; then
      read -rsp "Enter WiFi password: " wifi_password
      echo ""
      [[ -z "$wifi_password" ]] && err "WiFi password cannot be empty"
      { echo "$wifi_password"; echo "$wifi_password"; } | pass insert -f iotstack/common/wifi_password 2>&1 | grep -v "^mkdir:" || true
      debug "Stored WiFi password in pass store"
    fi

    ok "WiFi credentials configured"
    echo ""
  fi
}

cmd_logs() {
  # Stream device logs.
  #   iotstack logs [-f] /dev/ttyACM0     -> raw serial (no YAML needed)
  #   iotstack logs [-f] <role>           -> all <role> devices, interleaved
  #   iotstack logs [-f] <mac> <role>     -> one device via the network API
  # Logs are inherently a live stream; -f/--follow is accepted for familiarity.
  if [[ "${1:-}" == "help" ]]; then
    help_logs
    return 0
  fi

  local -a pos=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--follow) shift ;;  # logs always follow; flag accepted for muscle memory
      help) help_logs; return 0 ;;
      *) pos+=("$1"); shift ;;
    esac
  done
  [[ ${#pos[@]} -eq 0 ]] && { help_logs; exit 1; }

  # -- Serial device: raw stream, no YAML --
  if [[ "${pos[0]}" == /dev/* ]]; then
    local port="${pos[0]}"
    [[ -e "$port" ]] || err "Serial device not found: $port"
    local py serial_source
    py=$(head -1 "$(command -v esphome)" 2>/dev/null | sed 's/^#!//')
    [[ -x "$py" ]] || py="python3"
    if create_log_child_output_piped; then
      serial_source=$(create_log_serial_source "$port")
      "$py" -u "${SCRIPT_DIR}/scripts/serial-logs.py" "$port" \
        | create_log_tee_console "$serial_source"
      exit "${PIPESTATUS[0]}"
    fi
    # No --create-log: auto-create a timestamped log file alongside other iotstack logs.
    local port_basename logs_file
    port_basename="${port##*/}"
    logs_file="${LOGS_DIR}/iotstack-logs-${port_basename}.log"
    info "Streaming serial logs from $port (Ctrl-C to stop)..."
    info "Log file: $logs_file"
    exec "$py" -u "${SCRIPT_DIR}/scripts/serial-logs.py" "$port" \
      --timestamps --log-file "$logs_file"
  fi

  # -- Network: [mac ...] <role> via esphome logs --
  local role="${pos[-1]}"
  local -a macs=("${pos[@]:0:${#pos[@]}-1}")
  if ! is_valid_role "$role"; then
    err "Unknown role: '$role' (give a defined role, or a /dev/... serial device)"
  fi
  local yaml_file="${YAMLS_DIR}/${role}.yaml"
  [[ -f "$yaml_file" ]] || err "YAML not found for role '$role': $yaml_file"

  # No MACs given: discover every <role>-<mac> on the network
  if [[ ${#macs[@]} -eq 0 ]]; then
    local line
    while IFS= read -r line; do
      [[ "$line" =~ ${role}-([0-9a-f]{6}) ]] && macs+=("${BASH_REMATCH[1]}")
    done < <(avahi-browse -t -r _esphomelib._tcp 2>/dev/null)
    [[ ${#macs[@]} -gt 0 ]] && mapfile -t macs < <(printf '%s\n' "${macs[@]}" | sort -u)
    [[ ${#macs[@]} -eq 0 ]] && err "No '$role' devices found on the network."
  fi

  # Single device: stream directly
  if [[ ${#macs[@]} -eq 1 ]]; then
    info "Streaming logs from ${role}-${macs[0]} (Ctrl-C to stop)..."
    exec esphome logs "$yaml_file" --device "${role}-${macs[0]}.local"
  fi

  # Multiple devices: run a logger per device in parallel, prefix each line with
  # the device name, and interleave to one stream.
  info "Streaming logs from ${#macs[@]} '$role' devices, interleaved (Ctrl-C to stop)..."
  trap 'jobs -p | xargs -r kill 2>/dev/null' INT TERM EXIT
  local mac
  for mac in "${macs[@]}"; do
    (
      PYTHONUNBUFFERED=1 esphome logs "$yaml_file" --device "${role}-${mac}.local" 2>&1 \
        | stdbuf -oL sed "s/^/[${role}-${mac}] /"
    ) &
  done
  wait
}

cmd_matter_commission() {
  # Commission a Matter device via QR image or manual pairing code
  # Usage: iotstack matter commission [-f] <qr-image>|<0000-000-0000>|<MT:payload>
  # Global -v: iotstack -v matter commission ...
  local matter_script="${SCRIPT_DIR}/scripts/matter-commission.sh"
  [[ ! -f "$matter_script" ]] && err "Matter commission script not found: $matter_script"

  local commission_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      help)
        help_matter_commission
        return 0
        ;;
      -f|--force)
        export IOTSTACK_MATTER_FORCE=1
        commission_args+=("$1")
        shift
        ;;
      *)
        commission_args+=("$1")
        shift
        ;;
    esac
  done

  [[ ${#commission_args[@]} -lt 1 ]] \
    && err "Usage: iotstack matter commission [-f] <qr-image>|<manual-pairing-code>|<MT:payload> (see: iotstack matter commission help)"

  if [[ $VERBOSE -eq 1 ]]; then
    export IOTSTACK_MATTER_VERBOSE=1
  fi

  "$matter_script" "${commission_args[@]}"
}

cmd_matter_configure_trust_store() {
  # Interactive Matter attestation trust store setup
  # Usage: iotstack matter configure-trust-store [manual-pairing-code|MT:payload]
  if [[ "${1:-}" == "help" ]]; then
    help_matter_configure_trust_store
    return 0
  fi

  local trust_script="${SCRIPT_DIR}/scripts/matter-configure-trust-store.sh"
  [[ ! -f "$trust_script" ]] && err "Matter trust store script not found: $trust_script"

  "$trust_script" "$@"
}

cmd_matter_decode_qr() {
  # Decode a Matter QR image and print the MT: payload to stdout.
  # Usage: iotstack matter decode-qr <path-to-image>
  if [[ "${1:-}" == "help" ]]; then
    cat "${SCRIPT_DIR}/docs/help/iotstack-matter-decode-qr.txt"
    return 0
  fi

  local decode_script="${SCRIPT_DIR}/scripts/matter-decode-qr.sh"
  [[ ! -f "$decode_script" ]] && err "Matter decode-qr script not found: $decode_script"
  [[ $# -lt 1 ]] && err "Usage: iotstack matter decode-qr <path-to-image> (see: iotstack matter decode-qr help)"

  "$decode_script" "$@"
}

cmd_matter_mdns() {
  # Show operational mDNS for one chip-tool fabric node (not all HA Matter devices).
  # Usage: iotstack matter mdns [node-id]
  if [[ "${1:-}" == "help" ]]; then
    cat "${SCRIPT_DIR}/docs/help/iotstack-matter-mdns.txt"
    return 0
  fi

  local node_id="${1:-1}"
  [[ "${node_id}" =~ ^[0-9]+$ ]] || err "Usage: iotstack matter mdns [node-id] (see: iotstack matter mdns help)"

  local instance=""
  instance="$(_chip_tool_operational_mdns_instance "${node_id}")" \
    || err "No chip-tool fabric ID saved. Commission once with iotstack matter commission, or save manually to $(resolve_chip_tool_storage_dir)/.compressed-fabric-id"

  info "iotstack chip-tool operational instance: ${instance}"
  info "Narrow browse: avahi-browse -t -r _matter._tcp 2>/dev/null | grep -F '${instance}'"
  if timeout 12 avahi-browse -r _matter._tcp 2>/dev/null | grep -F -- "${instance}"; then
    ok "Visible on this host"
  else
    warn "Not visible on this host yet (MYGGSPRAY awake? OTBR publishing mDNS to pangolin?)"
    return 1
  fi
}

_chip_tool_operational_mdns_instance() {
  # shellcheck source=scripts/ensure-chip-tool-storage.sh
  source "${SCRIPT_DIR}/scripts/ensure-chip-tool-storage.sh"
  chip_tool_operational_mdns_instance "$@"
}

cmd_matter() {
  [[ $# -lt 1 ]] && {
    help_matter
    return 1
  }

  case "$1" in
    help)
      shift
      help_matter "$@"
      ;;
    commission)
      shift
      cmd_matter_commission "$@"
      ;;
    configure-trust-store)
      shift
      cmd_matter_configure_trust_store "$@"
      ;;
    mdns)
      shift
      cmd_matter_mdns "$@"
      ;;
    decode-qr)
      shift
      cmd_matter_decode_qr "$@"
      ;;
    *)
      err "Unknown matter subcommand: $1. Try 'iotstack matter help'"
      ;;
  esac
}

cmd_commission() {
  warn "iotstack commission is deprecated; use: iotstack matter commission"
  cmd_matter_commission "$@"
}

help_matter() {
  local topic="${1:-}"
  case "$topic" in
    commission) help_matter_commission ;;
    configure-trust-store) help_matter_configure_trust_store ;;
    decode-qr) help_matter_decode_qr ;;
    mdns) cat "${SCRIPT_DIR}/docs/help/iotstack-matter-mdns.txt" ;;
    *) cat "${SCRIPT_DIR}/docs/help/iotstack-matter.txt" ;;
  esac
}

help_matter_commission() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-matter-commission.txt"
}

help_matter_configure_trust_store() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-matter-configure-trust-store.txt"
}

help_matter_decode_qr() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-matter-decode-qr.txt"
}

help_commission() {
  help_matter_commission
}

cmd_otbr() {
  # shellcheck source=otbr/otbr.sh
  source "${SCRIPT_DIR}/otbr/otbr.sh"
  cmd_otbr_dispatch "$@"
}

help_otbr() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-otbr.txt"
}

_cmd_clean_remove_path() {
  # Remove a file or directory; bump cleaned_count. Safe under set -e.
  local path="$1"
  local -n _count_ref="$2"
  local size

  [[ -e "$path" ]] || return 0
  if [[ -d "$path" ]]; then
    size=$(du -sh "$path" 2>/dev/null | awk '{print $1}' || echo "unknown")
    info "Removing directory: $path ($size)"
    rm -rf "$path"
  else
    info "Removing file: $path"
    rm -f "$path"
  fi
  _count_ref=$((_count_ref + 1))
}

_cmd_clean_remove_temp_yamls() {
  # Remove gitignored runtime YAML copies under yamls/ (.temp-compile-*, etc.).
  local -n clean_count_ref="$1"
  local yamls_dir="${YAMLS_DIR:-}" pattern path

  [[ -n "$yamls_dir" && -d "$yamls_dir" ]] || return 0
  declare -F iotstack_temp_yaml_patterns &>/dev/null || return 0

  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    shopt -s nullglob
    for path in "${yamls_dir}"/${pattern}; do
      [[ -f "$path" ]] || continue
      _cmd_clean_remove_path "$path" clean_count_ref
    done
    shopt -u nullglob
  done < <(iotstack_temp_yaml_patterns)
}

cmd_clean() {
  # Clean iotstack session logs and ~/.iotstack/artifacts.
  # Does not remove ESPHome build output, ~/.esphome/, or ~/.platformio/.cache.
  # Session log lines are buffered (IOTSTACK_LOG_BUFFER_FILE) and flushed on EXIT.
  info "Cleaning iotstack logs and artifacts..."

  local cleaned_count=0 item
  local logs_dir="${IOTSTACK_HOME}/logs"
  local artifacts_dir="${IOTSTACK_HOME}/artifacts"

  local -a items_to_clean=(
    "${logs_dir}"
    "${artifacts_dir}"
  )
  # Honor overrides from ~/.iotstack/.env when paths differ from defaults
  if [[ "${LOGS_DIR}" != "${logs_dir}" ]]; then
    items_to_clean+=("${LOGS_DIR}")
  fi
  if [[ "${ARTIFACTS_DIR}" != "${artifacts_dir}" ]]; then
    items_to_clean+=("${ARTIFACTS_DIR}")
  fi

  for item in "${items_to_clean[@]}"; do
    _cmd_clean_remove_path "$item" cleaned_count
  done

  _cmd_clean_remove_temp_yamls cleaned_count

  ok "Clean complete. Removed $cleaned_count item(s)"
  ok "Ready for next compilation"
}

help_clean() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-clean.txt"
}

help_ps() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-ps.txt"
}

help_kill() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-kill.txt"
}

cmd_kill() {
  if [[ "${1:-}" == "help" ]]; then
    help_kill
    return 0
  fi
  [[ $# -gt 0 ]] && err "Unknown option for kill: $1 (try 'iotstack kill help')"

  # shellcheck source=scripts/iotstack-ps.sh
  source "${SCRIPT_DIR}/scripts/iotstack-ps.sh"
  iotstack_ps_kill
}

cmd_ps() {
  local subcommand="${1:-}"

  case "$subcommand" in
    help)
      help_ps
      return 0
      ;;
    kill)
      shift
      [[ $# -gt 0 ]] && err "Unknown option for ps kill: $1 (try 'iotstack ps help')"
      # shellcheck source=scripts/iotstack-ps.sh
      source "${SCRIPT_DIR}/scripts/iotstack-ps.sh"
      iotstack_ps_kill
      ;;
    "")
      # shellcheck source=scripts/iotstack-ps.sh
      source "${SCRIPT_DIR}/scripts/iotstack-ps.sh"
      iotstack_ps
      ;;
    *)
      err "Unknown ps subcommand: $subcommand (try 'iotstack ps help')"
      ;;
  esac
}

help_tests() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-tests.txt"
}

cmd_tests() {
  local subcommand="${1:-}"
  local runner="${TESTS_DIR}/run_test_cases.sh"

  case "$subcommand" in
    help)
      help_tests
      return 0
      ;;
    list)
      shift
      "$runner" --list "$@"
      ;;
    ports)
      shift
      "$runner" --ports "$@"
      ;;
    run)
      shift
      "$runner" "$@"
      ;;
    "")
      help_tests
      exit 1
      ;;
    *)
      err "Unknown tests subcommand: $subcommand. Try 'iotstack tests help'"
      ;;
  esac
}

main() {
  local invocation_cmd="iotstack" arg
  for arg in "$@"; do
    invocation_cmd+=" $(printf '%q' "$arg")"
  done

  iotstack_parse_global_argv "$@"
  set -- "${IOTSTACK_ARGV[@]}"

  # Shared per-invocation preamble (agentstartstack): on a dirty canonical repo it
  # auto-commits the working tree so GIT HEAD documents the exact code that ran;
  # strict no-op in an agent session clone. Sets $AGENTSTARTSTACK_CLI_HEAD (run
  # provenance). This wiring line is permanently static -- policy lives upstream.
  eval "$(AGENTSTARTSTACK_CLI_TOOL=iotstack \
    "${PROJECT_ROOT}/.agentstartstack/scripts/cli-preamble.sh" "$PROJECT_ROOT")"

  local command="${1:-help}"
  create_log_setup "$command"

  if create_log_enabled; then
    info "Session log: tail -f ${IOTSTACK_LOG_FILE}"
    if [[ "$command" == "flash" ]] && create_log_serial_capture_enabled; then
      local _early_serial_log="${IOTSTACK_HOME}/logs/iotstack-${IOTSTACK_LOG_ID}-serial.log"
      export IOTSTACK_SERIAL_LOG_FILE="$_early_serial_log"
      export _FLASH_SERIAL_LOG_ANNOUNCED=1
      mkdir -p "$(dirname "$IOTSTACK_SERIAL_LOG_FILE")"
      touch "$IOTSTACK_SERIAL_LOG_FILE"
      info "Serial log:  tail -f ${IOTSTACK_SERIAL_LOG_FILE}"
    fi
  fi
  create_log_write_header "$command"
  create_log_watch_append "$invocation_cmd"

  if [[ "$command" == "flash" && "${2:-}" != "help" ]]; then
    _flash_preflight_step_begin
    info "iotstack git commit (HEAD): $(iotstack_git_commit_short)"
    # Surface the gpg/pass stores (paths, not secrets) so it's obvious which
    # isolated iotstack stores pass will use for OTA/API/bootstrap credentials.
    info "GNUPGHOME:          ${GNUPGHOME:-(unset)}"
    info "PASSWORD_STORE_DIR: ${PASSWORD_STORE_DIR:-(unset)}"
  fi

  # Load environment file if it exists
  if [[ -f "$ENV_FILE" ]]; then
    debug "Loading environment from: $ENV_FILE"
    set +u
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set -u
  fi

  # Ensure symlink from yamls/.iotstack -> ~/.iotstack exists
  local iotstack_link="${YAMLS_DIR}/.iotstack"
  local iotstack_home="${HOME}/.iotstack"

  if [[ ! -L "$iotstack_link" ]] || [[ "$(readlink "$iotstack_link")" != "$iotstack_home" ]]; then
    # Remove broken/wrong symlink if it exists
    [[ -e "$iotstack_link" || -L "$iotstack_link" ]] && rm -f "$iotstack_link"
    # Create correct symlink
    mkdir -p "$iotstack_home"
    ln -s "$iotstack_home" "$iotstack_link"
    debug "Restored .iotstack symlink: $iotstack_link -> $iotstack_home"
  fi

  _ensure_chip_tool_storage

  # Only verify WiFi credentials if it's an actual operation (not help)
  if [[ "${2:-}" != "help" ]]; then
    case "$command" in
      update|reassign|flash)
        # Check WiFi credentials exist, prompt if missing (needed for device flashing)
        verify_wifi_credentials
        ;;
      tests)
        if [[ "${2:-}" == "run" ]]; then
          verify_wifi_credentials
        fi
        ;;
    esac
  fi

  case "$command" in
    update)
      shift
      cmd_update "$@"
      ;;
    verify)
      shift
      cmd_verify "$@"
      ;;
    verify-flash)
      shift
      cmd_verify_flash "$@"
      ;;
    reassign)
      shift
      cmd_reassign "$@"
      ;;
    devices)
      shift
      cmd_list devices "$@"
      ;;
    bootstrap)
      shift
      if [[ "${1:-}" == "help" ]]; then
        help_bootstrap
      else
        cmd_list devices --bootstrap "$@"
      fi
      ;;
    roles)
      shift
      cmd_list roles "$@"
      ;;
    secret)
      shift
      cmd_secret "$@"
      ;;
    device)
      shift
      cmd_device "$@"
      ;;
    rotate-secrets)
      shift
      cmd_rotate_secrets "$@"
      ;;
    flash)
      shift
      cmd_flash "$@"
      ;;
    logs)
      shift
      cmd_logs "$@"
      ;;
    set-boot)
      shift
      cmd_set_boot "$@"
      ;;
    matter)
      shift
      cmd_matter "$@"
      ;;
    otbr)
      if [[ "$ENV_FILE" != "${HOME}/.iotstack/.env" ]]; then
        local _otbr_env_candidate
        _otbr_env_candidate="${HOME}/.otbrstack/env/$(basename "$ENV_FILE")"
        if [[ -f "$_otbr_env_candidate" ]]; then
          export IOTSTACK_OTBR_ENV_FILE="$_otbr_env_candidate"
        fi
      fi
      shift
      cmd_otbr "$@"
      ;;
    commission)
      shift
      cmd_commission "$@"
      ;;
    clean)
      shift
      cmd_clean "$@"
      ;;
    ps)
      shift
      cmd_ps "$@"
      ;;
    kill)
      shift
      cmd_kill "$@"
      ;;
    tests)
      shift
      cmd_tests "$@"
      ;;
    query)
      shift
      cmd_query "$@"
      ;;
    help)
      if [[ $# -gt 1 ]]; then
        if is_valid_role "$2"; then
          help_role "$2"
        else
        case "$2" in
          update)           help_update ;;
          verify)           help_verify ;;
          verify-flash)     help_verify_flash ;;
          reassign)         help_reassign ;;
          devices)          help_devices ;;
          bootstrap)         help_bootstrap ;;
          roles)            help_roles ;;
          flash)            help_flash ;;
          logs)             help_logs ;;
          set-boot)         cmd_set_boot help ;;
          matter)           help_matter "${3:-}" ;;
          otbr)             help_otbr ;;
          commission)       help_commission ;;
          clean)            help_clean ;;
          ps)               help_ps ;;
          kill)             help_kill ;;
          tests)            help_tests ;;
          query)            help_query ;;
          secret)           help_secret ;;
          device)           help_device ;;
          rotate-secrets)   help_rotate_secrets ;;
          *)                err "Unknown command: $2" ;;
        esac
        fi
      else
        usage
      fi
      ;;
    *)
      err "Unknown command: $command. Try 'iotstack help'"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
