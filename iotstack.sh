#!/bin/bash
# iotstack.sh -- CLI tool for managing iotstack ESPHome devices
# Wrapper around update_devices.sh with a cleaner interface

set -euo pipefail

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
debug() { [[ $VERBOSE -eq 1 ]] && [[ $QUIET -eq 0 ]] && echo -e "${DIM}[DEBUG]${RST} $*"; return 0; }

# Forward iotstack -v to update_devices.sh (--verbose).
_update_devices_inherited_flags() {
  [[ $VERBOSE -eq 1 ]] && printf '%s\n' --verbose
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

# -- Compilation Cache --------------------------------------------------------

_get_yaml_sha() {
  # SHA256 of the YAML plus the shared external_components and common/ package
  # includes, so a change to any of them invalidates the compile cache -- the
  # device YAML may reference them only via !include / packages:, so hashing the
  # YAML text alone would miss those changes and reuse a stale build.
  local yaml_file="$1"

  if [[ ! -f "$yaml_file" ]]; then
    echo ""
    return
  fi

  local combined_hash
  combined_hash=$(sha256sum "$yaml_file" | awk '{print $1}')

  # Fold in every file under external_components/ and common/ (sorted for a
  # stable order; __pycache__ excluded so regenerated .pyc don't churn the key).
  local dir dir_hash
  for dir in "${YAMLS_DIR}/external_components" "${YAMLS_DIR}/common"; do
    [[ -d "$dir" ]] || continue
    dir_hash=$(find "$dir" -type f ! -path '*__pycache__*' -print0 | sort -z | xargs -0 cat 2>/dev/null | sha256sum | awk '{print $1}')
    combined_hash=$(echo -n "${combined_hash}${dir_hash}" | sha256sum | awk '{print $1}')
  done

  combined_hash=$(echo -n "${combined_hash}$(iotstack_project_version)" | sha256sum | awk '{print $1}')

  echo "$combined_hash"
}

_get_binary_sha() {
  # Get SHA256 of compiled firmware binary
  local device_name="$1"
  local build_dir="${YAMLS_DIR}/.esphome/build/${device_name}/.pioenvs/${device_name}/firmware.bin"
  [[ -f "$build_dir" ]] && sha256sum "$build_dir" | awk '{print $1}' || echo ""
}

_normalize_compilation_cache() {
  # Upgrade legacy 3-column caches; dedupe rows (one row per yaml_name).
  [[ -f "$COMPILATION_CACHE" ]] || return 0
  local row_count unique_count tmp header
  header=$(head -1 "$COMPILATION_CACHE")
  row_count=$(tail -n +2 "$COMPILATION_CACHE" 2>/dev/null | wc -l)
  unique_count=$(tail -n +2 "$COMPILATION_CACHE" 2>/dev/null | cut -d, -f1 | sort -u | wc -l)

  if [[ "$header" != *config_hash* ]]; then
    tmp=$(mktemp)
    {
      echo "yaml_name,yaml_sha,binary_sha,config_hash"
      tail -n +2 "$COMPILATION_CACHE" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "${line},"
      done
    } > "$tmp"
    mv "$tmp" "$COMPILATION_CACHE"
    header="yaml_name,yaml_sha,binary_sha,config_hash"
  fi

  (( row_count == unique_count )) && return 0

  tmp=$(mktemp)
  {
    echo "$header"
    tail -n +2 "$COMPILATION_CACHE" | awk -F, '{ rows[$1]=$0 } END { for (n in rows) print rows[n] }' | sort -t, -k1,1
  } > "$tmp"
  mv "$tmp" "$COMPILATION_CACHE"
}

_compilation_cache_patch_config_hash() {
  # Set config_hash (column 4) on an existing compilation-cache.csv row.
  local yaml_name="$1"
  local config_hash="$2"
  local tmp
  [[ -f "$COMPILATION_CACHE" && -n "$yaml_name" && -n "$config_hash" ]] || return 1
  _normalize_compilation_cache
  tmp=$(mktemp)
  awk -F, -v OFS=',' -v name="$yaml_name" -v hash="$config_hash" '
    NR == 1 { print; next }
    $1 == name { print $1, $2, $3, hash; next }
    { print }
  ' "$COMPILATION_CACHE" > "$tmp"
  mv "$tmp" "$COMPILATION_CACHE"
}

_compilation_cache_backfill_config_hash() {
  # Ensure compilation-cache.csv has config_hash for a cached build (no recompile).
  local yaml_file="$1"
  local build_name="$2"
  local yaml_name hash
  yaml_name=$(basename "$yaml_file")
  hash=$(_compilation_cache_config_hash "$yaml_file" "$build_name" 2>/dev/null) || true
  [[ -n "$hash" ]] || return 1
  if awk -F, -v name="$yaml_name" '$1==name && $4!="" { found=1 } END { exit !found }' "$COMPILATION_CACHE" 2>/dev/null; then
    return 0
  fi
  _compilation_cache_patch_config_hash "$yaml_name" "$hash"
}

_check_compilation_cache() {
  # Check if we can skip compilation based on YAML SHA
  # Returns 0 (can skip) or 1 (must compile)
  local yaml_file="$1"
  local yaml_name yaml_sha cached_sha
  yaml_name=$(basename "$yaml_file")
  yaml_sha=$(_get_yaml_sha "$yaml_file")

  [[ ! -f "$COMPILATION_CACHE" ]] && return 1
  _normalize_compilation_cache

  cached_sha=$(awk -F, -v name="$yaml_name" '$1==name { sha=$2 } END { print sha }' "$COMPILATION_CACHE")
  [[ -n "$cached_sha" && "$cached_sha" == "$yaml_sha" ]]
}

_build_config_hash_from_build_dir() {
  # 8-char hex config_hash from ESPHome build_info.json (used when populating compilation-cache.csv).
  local build_name="$1"
  local build_info="${YAMLS_DIR}/.esphome/build/${build_name}/build_info.json"
  [[ -f "$build_info" ]] || return 1
  python3 -c "import json,sys; print(format(json.load(open(sys.argv[1]))['config_hash'], '08x'))" "$build_info"
}

_compilation_cache_config_hash() {
  # config_hash for a yaml row in ~/.iotstack/compilation-cache.csv (mDNS compare key).
  local yaml_file="$1"
  local build_name="${2:-$(basename "$yaml_file" .yaml)}"
  local yaml_name hash
  yaml_name=$(basename "$yaml_file")
  [[ -f "$COMPILATION_CACHE" ]] || return 1
  _normalize_compilation_cache
  hash=$(awk -F, -v name="$yaml_name" '$1==name && $4!="" { print $4 }' "$COMPILATION_CACHE" | tail -1)
  if [[ -z "$hash" ]]; then
    hash=$(_build_config_hash_from_build_dir "$build_name" 2>/dev/null) || true
    [[ -n "$hash" ]] && _compilation_cache_patch_config_hash "$yaml_name" "$hash"
  fi
  [[ -n "$hash" ]] && echo "$hash"
}

_update_compilation_cache() {
  # Upsert: one row per yaml_name (yaml_sha, binary_sha, config_hash).
  local yaml_file="$1"
  local binary_sha="$2"
  local build_name="${3:-}"
  local yaml_name yaml_sha config_hash tmp
  yaml_name=$(basename "$yaml_file")
  yaml_sha=$(_get_yaml_sha "$yaml_file")
  config_hash=""
  [[ -n "$build_name" ]] && config_hash=$(_build_config_hash_from_build_dir "$build_name" 2>/dev/null) || true

  mkdir -p "$(dirname "$COMPILATION_CACHE")"
  _normalize_compilation_cache
  tmp=$(mktemp)

  if [[ -f "$COMPILATION_CACHE" ]]; then
    {
      head -1 "$COMPILATION_CACHE"
      awk -F, -v name="$yaml_name" 'NR > 1 && $1 != name { print }' "$COMPILATION_CACHE"
    } > "$tmp"
  else
    echo "yaml_name,yaml_sha,binary_sha,config_hash" > "$tmp"
  fi
  echo "${yaml_name},${yaml_sha},${binary_sha},${config_hash}" >> "$tmp"
  mv "$tmp" "$COMPILATION_CACHE"
}

_check_serial_port_in_use() {
  # Check if serial port is already open by screen, minicom, picocom, or other tools
  local tty_device="$1"

  debug "_check_serial_port_in_use: checking $tty_device"

  # Try lsof first (most reliable)
  if command -v lsof &>/dev/null; then
    debug "_check_serial_port_in_use: lsof found"
    local processes
    debug "_check_serial_port_in_use: running lsof..."
    processes=$(lsof "$tty_device" 2>/dev/null | tail -n +2 || true)  # Skip header, allow failure
    debug "_check_serial_port_in_use: lsof completed, processes='$processes'"
    if [[ -n "$processes" ]]; then
      # Extract PID and command for better error message
      local pid
      pid=$(echo "$processes" | awk '{print $2}' | head -1)
      local cmd
      cmd=$(echo "$processes" | awk '{print $1}' | head -1)

      # If it's an iotstack logs session (serial-logs.py), kill it automatically
      # so flash can proceed without user intervention.
      local full_cmdline
      full_cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
      if [[ "$full_cmdline" == *"serial-logs.py"* ]]; then
        info "Killing iotstack logs on $tty_device (pid $pid) to free port for flash..."
        kill "$pid" 2>/dev/null || true
        sleep 1
        return 0
      fi

      local kill_cmd=""
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

  # Fallback to fuser if lsof is not available
  if command -v fuser &>/dev/null; then
    if fuser "$tty_device" >/dev/null 2>&1; then
      warn "Serial port $tty_device may be in use. Close any open terminal sessions before flashing."
    fi
    return 0
  fi
}

_hex_sizes_equal() {
  local a="${1,,}" b="${2,,}"
  [[ -n "$a" && "$a" == "$b" ]]
}

_partition_table_failsafe_size() {
  # Failsafe (ota_0) size from the persisted partition table artifact (~/.iotstack/artifacts/).
  # Survives `iotstack clean` (unlike compilation-cache.csv) so pass 1 can start exact.
  [[ -f "$PARTITION_TABLE" ]] || return 1
  local size
  size=$(awk -F, '
    $1 ~ /^[[:space:]]*failsafe[[:space:]]*$/ {
      gsub(/ /, "", $5)
      print $5
      exit
    }
  ' "$PARTITION_TABLE")
  [[ -n "$size" && "$size" =~ ^0x[0-9a-fA-F]+$ ]] || return 1
  printf '%s' "$size"
}

_sync_failsafe_partition_table_from_build() {
  local build_csv="${YAMLS_DIR}/.esphome/build/failsafe/partitions.csv"
  if [[ -f "$build_csv" ]] && grep -qE '^production,' "$build_csv" 2>/dev/null; then
    cp "$build_csv" "$PARTITION_TABLE"
    _ensure_partition_table_symlink "$PARTITION_TABLE"
    debug "Partition table synced from failsafe build (production offset $(flash_partition_offset production 2>/dev/null))"
  fi
}

_failsafe_part_size() {
  # Echo the failsafe (ota_0) partition size as hex for a given firmware.bin:
  # round_up_64KB(firmware_size + IOTSTACK_FAILSAFE_MARGIN). Falls back to
  # IOTSTACK_FAILSAFE_PART_SIZE if the binary cannot be measured.
  local bin="$1"
  local margin="${IOTSTACK_FAILSAFE_MARGIN:-0x10000}"
  local sz
  sz=$(stat -c%s "$bin" 2>/dev/null || stat -f%z "$bin" 2>/dev/null || echo 0)
  if (( sz <= 0 )); then
    printf '%s' "${IOTSTACK_FAILSAFE_PART_SIZE:-0xe0000}"
    return
  fi
  local total=$(( sz + margin ))
  (( total % 0x10000 != 0 )) && total=$(( (total / 0x10000 + 1) * 0x10000 ))
  printf '0x%x' "$total"
}

_esphome_compile() {
  # Run esphome compile, honoring VERBOSE
  local yaml_file="$1"
  local compile_yaml rc=0
  compile_yaml=$(iotstack_prepare_compile_yaml "$yaml_file") || return 1
  if [[ $VERBOSE -eq 1 ]]; then
    if create_log_child_output_piped; then
      create_log_run "esphome:compile" esphome compile "$compile_yaml" || rc=1
    else
      esphome compile "$compile_yaml" || rc=1
    fi
  else
    esphome compile "$compile_yaml" >/dev/null 2>&1 || rc=1
  fi
  iotstack_cleanup_compile_yaml "$compile_yaml" "$yaml_file"
  return $rc
}

_smart_compile_cache_hit_notice() {
  local device_name="$1"
  local firmware_kind="$2"  # e.g. production, failsafe
  info "Compilation cache hit -- ${firmware_kind} firmware (${device_name}) already built; compile skipped"
}

_smart_compile_cache_miss_notice() {
  # Log why smart_compile cannot reuse a cached build (called before esphome compile).
  local device_name="$1"
  local firmware_kind="$2"  # e.g. production, failsafe
  if [[ "${DISABLE_COMPILATION_CACHE:-0}" == "1" ]]; then
    info "Compilation cache disabled -- ${firmware_kind} firmware (${device_name}) must be compiled"
  else
    info "Compilation cache miss -- ${firmware_kind} firmware (${device_name}) must be compiled"
  fi
}

smart_compile() {
  # Smart compilation that uses cache to skip rebuilds.
  # Usage: smart_compile <yaml_file> [device_name_for_logging]
  # Environment variable: DISABLE_COMPILATION_CACHE=1 forces recompilation
  local yaml_file="$1"
  local device_name="${2:-unknown}"

  local yaml_sha
  yaml_sha=$(_get_yaml_sha "$yaml_file")
  [[ -z "$yaml_sha" ]] && err "Failed to compute SHA256 of $yaml_file"

  local firmware_bin="${YAMLS_DIR}/.esphome/build/${device_name}/.pioenvs/${device_name}/firmware.bin"
  local cached=0
  [[ "${DISABLE_COMPILATION_CACHE:-0}" != "1" ]] && _check_compilation_cache "$yaml_file" && cached=1
  [[ "${DISABLE_COMPILATION_CACHE:-0}" == "1" ]] && debug "Compilation cache disabled (DISABLE_COMPILATION_CACHE=1)"

  # -- Non-failsafe builds ----------------------------------------------------
  # Production firmware is OTA'd into the production partition and uses ESPHome's
  # default partition table for its build-size check, so the custom table size
  # is irrelevant to it. Just make sure a table exists, then compile.
  if ! _is_failsafe_yaml "$yaml_file"; then
    if [[ $cached -eq 1 ]]; then
      ensure_partition_table_artifact
      _compilation_cache_backfill_config_hash "$yaml_file" "$device_name" || true
      _smart_compile_cache_hit_notice "$device_name" "production"
      return 0
    fi
    _update_partition_table_file
    _smart_compile_cache_miss_notice "$device_name" "production"
    info "Compiling production firmware (${device_name})..."
    _esphome_compile "$yaml_file" || return 1
    local binary_sha; binary_sha=$(_get_binary_sha "$device_name")
    if [[ -n "$binary_sha" ]]; then
      _update_compilation_cache "$yaml_file" "$binary_sha" "$device_name"
      ok "Compilation cache updated"
    fi
    return 0
  fi

  # -- Failsafe: size its partition dynamically to the actual firmware ---------
  # The failsafe partition is sized to exactly what failsafe needs (+ margin);
  # production absorbs the rest. The partition size affects the flashed
  # partitions.bin (not the position-independent app image), so we compile,
  # measure, regenerate the table, then recompile so partitions.bin matches.
  if [[ $cached -eq 1 && -f "$firmware_bin" ]]; then
    _compilation_cache_backfill_config_hash "$yaml_file" "$device_name" || true
    _smart_compile_cache_hit_notice "$device_name" "failsafe"
    _sync_failsafe_partition_table_from_build \
      || { local fs_size; fs_size=$(_failsafe_part_size "$firmware_bin")
           IOTSTACK_FAILSAFE_PART_SIZE="$fs_size" _update_partition_table_file; }
    return 0
  fi

  # Pass 1: compile (prefer persisted partition size; fall back to generous default).
  local pass1_size fs_size fw_bytes partitions_bin
  _smart_compile_cache_miss_notice "$device_name" "failsafe"
  local generous_size="${IOTSTACK_FAILSAFE_PART_SIZE_GENEROUS:-0x180000}"
  pass1_size=$(_partition_table_failsafe_size 2>/dev/null) \
    || pass1_size="${IOTSTACK_FAILSAFE_PART_SIZE:-0xe0000}"
  export IOTSTACK_FAILSAFE_PART_SIZE="$pass1_size"
  _update_partition_table_file
  if _hex_sizes_equal "$pass1_size" "$generous_size"; then
    info "Compiling failsafe-wifi firmware (pass 1/2: measuring size)..."
  else
    info "Compiling failsafe-wifi firmware (pass 1: partition table ${pass1_size})..."
  fi
  if ! _esphome_compile "$yaml_file"; then
    if _hex_sizes_equal "$pass1_size" "$generous_size"; then
      return 1
    fi
    warn "Failsafe compile failed with partition ${pass1_size} -- retrying with generous ${generous_size}"
    export IOTSTACK_FAILSAFE_PART_SIZE="$generous_size"
    _update_partition_table_file
    info "Compiling failsafe-wifi firmware (pass 1/2: measuring size)..."
    _esphome_compile "$yaml_file" || return 1
  fi

  fs_size=$(_failsafe_part_size "$firmware_bin")
  fw_bytes=$(stat -c%s "$firmware_bin" 2>/dev/null || echo "?")
  info "Failsafe firmware ${fw_bytes} bytes -> failsafe partition ${fs_size}"
  partitions_bin="${YAMLS_DIR}/.esphome/build/failsafe/.pioenvs/failsafe/partitions.bin"

  if _hex_sizes_equal "$fs_size" "$IOTSTACK_FAILSAFE_PART_SIZE" && [[ -f "$partitions_bin" ]]; then
    _sync_failsafe_partition_table_from_build
    info "Failsafe partition table already exact (${fs_size}) -- skipping pass 2"
  else
    export IOTSTACK_FAILSAFE_PART_SIZE="$fs_size"
    _update_partition_table_file
    info "Compiling failsafe-wifi firmware (pass 2/2: applying exact partition table)..."
    _esphome_compile "$yaml_file" || return 1
    _sync_failsafe_partition_table_from_build
  fi

  local binary_sha; binary_sha=$(_get_binary_sha "$device_name")
  if [[ -n "$binary_sha" ]]; then
    _update_compilation_cache "$yaml_file" "$binary_sha" "$device_name"
    ok "Compilation cache updated"
  fi
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
# stdout stays on the tty. --log-id=<id> implies --create-log and -v; appends to iotstack-<id>.log.
_iotstack_log_plain() {
  local tag="$1"
  shift
  if create_log_enabled; then
    create_log_stamp_line "iotstack.sh" "[$tag] $*"
  fi
}

_iotstack_echo() {
  local stream="$1"
  shift
  local ts
  ts=$(iotstack_timestamp_prefix)
  if [[ "$stream" == "stderr" ]]; then
    echo -e "${ts}$*" >&2
  else
    echo -e "${ts}$*"
  fi
}

err()  { _iotstack_log_plain "ERROR" "$@"; _iotstack_echo stderr "${RED}[ERROR]${RST} $*"; exit 1; }
ok()   { [[ $QUIET -eq 0 ]] && { _iotstack_log_plain "OK" "$@"; _iotstack_echo stdout "${GRN}[OK]${RST} $*"; }; return 0; }
warn() { [[ $QUIET -eq 0 ]] && { _iotstack_log_plain "WARN" "$@"; _iotstack_echo stdout "${YLW}[WARN]${RST} $*"; }; return 0; }
info() { [[ $QUIET -eq 0 ]] && { _iotstack_log_plain "INFO" "$@"; _iotstack_echo stdout "${BLU}[INFO]${RST} $*"; }; return 0; }
debug() { [[ $VERBOSE -eq 1 && $QUIET -eq 0 ]] && { _iotstack_log_plain "DEBUG" "$@"; _iotstack_echo stdout "${DIM}[DEBUG]${RST} $*"; }; return 0; }

_run_update_devices() {
  if create_log_child_output_piped; then
    create_log_run "update_devices.sh" bash "$UPDATE_SCRIPT" "$@"
    return $?
  fi
  "$UPDATE_SCRIPT" "$@"
}

# partition-table.sh is sourced by config.sh (generate_partition_table, update_partition_table_file)
# shellcheck source=scripts/failsafe-yaml.sh
source "${SCRIPT_DIR}/scripts/failsafe-yaml.sh"
# shellcheck source=scripts/flash-compare.sh
source "${SCRIPT_DIR}/scripts/flash-compare.sh"

_is_failsafe_yaml() {
  failsafe_is_artifact_yaml "$1" || [[ "$(basename "$1")" == "failsafe.yaml" ]]
}

_update_partition_table_file() {
  debug "Generating local build partition table CSV: $PARTITION_TABLE"
  update_partition_table_file
  debug "Build partition table CSV ready (failsafe + production layout for compile -- not read from device)"
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
  local dev_status=""

  if [[ -f "$yaml_file" ]]; then
    # Extract board and variant from esp32 section
    board=$(grep -A5 "^esp32:" "$yaml_file" | grep -E "^\s*board:\s*" | head -1 | sed 's/.*board:\s*//; s/\s*$//')
    variant=$(grep -A5 "^esp32:" "$yaml_file" | grep -E "^\s*variant:\s*" | head -1 | sed 's/.*variant:\s*//; s/\s*$//')

    # Extract development_status from substitutions section
    dev_status=$(grep -E "^\s*development_status:\s*" "$yaml_file" | head -1 | sed 's/.*development_status:\s*//; s/"//g; s/\s*$//')

    # Determine network_type from presence of wifi or openthread sections
    if grep -q "^wifi:" "$yaml_file" 2>/dev/null; then
      network_type="wifi"
    elif grep -q "^openthread:" "$yaml_file" 2>/dev/null; then
      network_type="thread"
    fi
  fi

  echo "${board}|${variant}|${network_type}|${dev_status}"
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

help_failsafe() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-failsafe.txt"
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
  local yaml_file info board variant network dev_status friendly f

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
  IFS='|' read -r board variant network dev_status <<< "$info"
  friendly=$(yaml_friendly_name_from_file "$yaml_file" 2>/dev/null) || friendly="$role"

  cat <<EOF
iotstack ${role} -- ${friendly}

Config: yamls/${role}.yaml
Chip: ${variant:-unknown}${board:+ (${board})}
Network: ${network:-unknown}
Status: ${dev_status:-unknown}

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

list_devices() {
  local output_format="${1:-text}"
  local filter_role="${2:-}"
  local suffix_only="${3:-false}"
  local mdns_service="${4:-_esphomelib._tcp}"
  local current_hostname=""
  local current_friendly=""
  local current_project=""
  local current_version=""
  local current_hash=""

  # Gather device data into temp buffer
  local device_data
  device_data=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$device_data'" RETURN

  # Query mDNS and extract device data
  while IFS= read -r line; do
    if [[ $line =~ hostname\ =\ \[([^\]]+)\] ]]; then
      current_hostname="${BASH_REMATCH[1]%.local}"
    fi
    if [[ $line =~ txt\ = ]]; then
      if [[ $line =~ friendly_name=([^\"]*) ]]; then
        current_friendly="${BASH_REMATCH[1]}"
        # Remove trailing MAC suffix (last 6 hex chars)
        current_friendly="${current_friendly% [0-9a-f][0-9a-f]*}"
      fi
      [[ $line =~ project_name=([^\"]*) ]] && current_project="${BASH_REMATCH[1]}"
      [[ $line =~ project_version=([^\"]*) ]] && current_version="${BASH_REMATCH[1]}"
      [[ $line =~ config_hash=([^\"]*) ]] && current_hash="${BASH_REMATCH[1]}"

      if [[ -n "$current_hostname" ]]; then
        echo "$current_hostname|$current_friendly|$current_project|$current_version|$current_hash" >> "$device_data"
        current_hostname=""
        current_friendly=""
        current_project=""
        current_version=""
        current_hash=""
      fi
    fi
  done < <(avahi-browse -t -r "$mdns_service" 2>/dev/null)

  # Sort and deduplicate
  sort -u "$device_data" > "${device_data}.sorted"

  # Try to get Home Assistant area info (only for production devices).
  # Normalize to a single JSON object: get_ha_device_areas can emit more than
  # one document (e.g. an empty "{}" plus a fallback "{}"), and a multi-doc
  # input makes the per-row `jq -r` lookups emit one line per document -- which
  # would put an embedded newline into the area value and break table rows.
  local ha_areas="{}"
  if [[ "$mdns_service" == "_esphomelib._tcp" ]]; then
    if get_ha_device_areas > /tmp/ha_areas.json 2>/dev/null; then
      ha_areas=$(jq -cs 'reduce .[] as $o ({}; . * $o)' /tmp/ha_areas.json 2>/dev/null || echo '{}')
      [[ -z "$ha_areas" ]] && ha_areas="{}"
    fi
  fi

  # If ID-only mode, output device IDs in requested format
  if [[ "$suffix_only" == "true" ]]; then
    if [[ "$output_format" == "csv" ]]; then
      echo "ID"
      while IFS='|' read -r hostname friendly project version hash; do
        if [[ -n "$filter_role" ]]; then
          if [[ "$filter_role" == "other" ]]; then
            local matches_role=false
            for role in $(list_device_names); do
              if [[ "$project" == *"$role"* ]]; then
                matches_role=true
                break
              fi
            done
            [[ "$matches_role" == true ]] && continue
          else
            if [[ "$project" != *"$filter_role"* ]]; then
              continue
            fi
          fi
        fi
        suffix="${hostname##*-}"
        echo "$suffix"
      done < "${device_data}.sorted"
    elif [[ "$output_format" == "json" ]]; then
      (
        echo "["
        first=true
        while IFS='|' read -r hostname friendly project version hash; do
          if [[ -n "$filter_role" ]]; then
            if [[ "$filter_role" == "other" ]]; then
              local matches_role=false
              for role in $(list_device_names); do
                if [[ "$project" == *"$role"* ]]; then
                  matches_role=true
                  break
                fi
              done
              [[ "$matches_role" == true ]] && continue
            else
              if [[ "$project" != *"$filter_role"* ]]; then
                continue
              fi
            fi
          fi
          suffix="${hostname##*-}"
          [[ "$first" != true ]] && echo ","
          printf '  "%s"' "$suffix"
          first=false
        done < "${device_data}.sorted"
        echo
        echo "]"
      ) | _iotstack_format_json
    else
      # Text format: space-separated IDs
      local suffixes=()
      while IFS='|' read -r hostname friendly project version hash; do
        if [[ -n "$filter_role" ]]; then
          if [[ "$filter_role" == "other" ]]; then
            local matches_role=false
            for role in $(list_device_names); do
              if [[ "$project" == *"$role"* ]]; then
                matches_role=true
                break
              fi
            done
            [[ "$matches_role" == true ]] && continue
          else
            if [[ "$project" != *"$filter_role"* ]]; then
              continue
            fi
          fi
        fi
        suffix="${hostname##*-}"
        suffixes+=("$suffix")
      done < "${device_data}.sorted"

      if [[ ${#suffixes[@]} -eq 0 ]]; then
        if [[ -n "$filter_role" ]]; then
          warn "No devices found for role: $filter_role"
        elif [[ "$mdns_service" == "_iotstack-failsafe._tcp" ]]; then
          warn "No failsafe devices found on network"
        else
          warn "No ESPHome devices found on network"
        fi
      else
        echo "${suffixes[@]}"
      fi
    fi
    return
  fi

  if [[ "$output_format" == "csv" ]]; then
    echo "ID,Device,Friendly Name,Area,Project,Version,Hash"
    while IFS='|' read -r hostname friendly project version hash; do
      # Filter by role if specified
      if [[ -n "$filter_role" ]]; then
        if [[ "$filter_role" == "other" ]]; then
          # Match devices that don't match any defined role
          local matches_role=false
          for role in $(list_device_names); do
            if [[ "$project" == *"$role"* ]]; then
              matches_role=true
              break
            fi
          done
          [[ "$matches_role" == true ]] && continue
        else
          # Match role name in project field
          if [[ "$project" != *"$filter_role"* ]]; then
            continue
          fi
        fi
      fi
      id="${hostname##*-}"
      # Try to get area from HA (match by full hostname or base name)
      area=$(echo "$ha_areas" | jq -r ".[\"$hostname\"] // .[\"$friendly\"] // \"-\"" 2>/dev/null)
      [[ -z "$area" ]] && area="-"
      echo "$id,$hostname,$friendly,$area,$project,$version,$hash"
    done < "${device_data}.sorted"
  elif [[ "$output_format" == "json" ]]; then
    while IFS='|' read -r hostname friendly project version hash; do
      # Filter by role if specified
      if [[ -n "$filter_role" ]]; then
        if [[ "$filter_role" == "other" ]]; then
          local matches_role=false
          for role in $(list_device_names); do
            if [[ "$project" == *"$role"* ]]; then
              matches_role=true
              break
            fi
          done
          [[ "$matches_role" == true ]] && continue
        else
          if [[ "$project" != *"$filter_role"* ]]; then
            continue
          fi
        fi
      fi
      id="${hostname##*-}"
      area=$(echo "$ha_areas" | jq -r ".[\"$hostname\"] // .[\"$friendly\"] // empty" 2>/dev/null)
      jq -nc \
        --arg id "$id" \
        --arg device "$hostname" \
        --arg friendly_name "$friendly" \
        --arg area "$area" \
        --arg project "$project" \
        --arg version "$version" \
        --arg hash "$hash" \
        '{
          id: $id,
          device: $device,
          friendly_name: $friendly_name,
          area: (if $area == "" then null else $area end),
          project: $project,
          version: $version,
          hash: $hash
        }'
    done < "${device_data}.sorted" | _iotstack_json_slurp
  else
    # Text format - calculate column widths (all left-aligned)
    local margin=2
    local header_id="ID"
    local header_device="Device"
    local header_friendly="Friendly Name"
    local header_area="Area"
    local header_project="Project"
    local header_version="Version"
    local header_hash="Hash"

    local w_id=$(( ${#header_id} + margin ))
    local w_device=$(( ${#header_device} + margin ))
    local w_friendly=$(( ${#header_friendly} + margin ))
    local w_area=$(( ${#header_area} + margin ))
    local w_project=$(( ${#header_project} + margin ))
    local w_version=$(( ${#header_version} + margin ))
    local w_hash=$(( ${#header_hash} + margin ))

    # Scan data to find max widths
    while IFS='|' read -r hostname friendly project version hash; do
      id="${hostname##*-}"
      area=$(echo "$ha_areas" | jq -r ".[\"$hostname\"] // .[\"$friendly\"] // \"-\"" 2>/dev/null)
      [[ -z "$area" ]] && area="-"
      (( ${#id} + margin > w_id )) && w_id=$(( ${#id} + margin ))
      (( ${#hostname} + margin > w_device )) && w_device=$(( ${#hostname} + margin ))
      (( ${#friendly} + margin > w_friendly )) && w_friendly=$(( ${#friendly} + margin ))
      (( ${#area} + margin > w_area )) && w_area=$(( ${#area} + margin ))
      (( ${#project} + margin > w_project )) && w_project=$(( ${#project} + margin ))
      (( ${#version} + margin > w_version )) && w_version=$(( ${#version} + margin ))
      (( ${#hash} + margin > w_hash )) && w_hash=$(( ${#hash} + margin ))
    done < "${device_data}.sorted"

    if [[ "$mdns_service" == "_esphomelib._tcp" ]]; then
      info "Discovered ESPHome devices on network:"
    else
      info "Discovered failsafe devices on network:"
    fi
    echo

    # Print headers with calculated widths (all left-aligned with %)
    printf "  ${GRN}%-${w_id}s %-${w_device}s %-${w_friendly}s %-${w_area}s %-${w_project}s %-${w_version}s %-${w_hash}s${RST}\n" \
      "ID" "Device" "Friendly Name" "Area" "Project" "Version" "Hash"

    # Print separator
    _print_table_rule "$w_id" "$w_device" "$w_friendly" "$w_area" "$w_project" "$w_version" "$w_hash"

    # Print data rows with calculated widths
    local found=0
    while IFS='|' read -r hostname friendly project version hash; do
      # Filter by role if specified
      if [[ -n "$filter_role" ]]; then
        if [[ "$filter_role" == "other" ]]; then
          # Match devices that don't match any defined role
          local matches_role=false
          for role in $(list_device_names); do
            if [[ "$project" == *"$role"* ]]; then
              matches_role=true
              break
            fi
          done
          [[ "$matches_role" == true ]] && continue
        else
          # Match role name in project field
          if [[ "$project" != *"$filter_role"* ]]; then
            continue
          fi
        fi
      fi
      id="${hostname##*-}"
      # Try to get area from HA (match by full hostname or base name)
      area=$(echo "$ha_areas" | jq -r ".[\"$hostname\"] // .[\"$friendly\"] // \"-\"" 2>/dev/null)
      [[ -z "$area" ]] && area="-"
      printf "  ${GRN}%-${w_id}s${RST} %-${w_device}s %-${w_friendly}s %-${w_area}s %-${w_project}s %-${w_version}s %-${w_hash}s\n" \
        "$id" "$hostname" "$friendly" "$area" "$project" "$version" "$hash"
      found=$((found + 1))
    done < "${device_data}.sorted"

    echo
    if [[ $found -eq 0 ]]; then
      if [[ -n "$filter_role" ]]; then
        warn "No devices found for role: $filter_role"
      elif [[ "$mdns_service" == "_iotstack-failsafe._tcp" ]]; then
        warn "No failsafe devices found on network (devices booted to production are listed by: iotstack devices)"
      else
        warn "No ESPHome devices found on network"
      fi
    else
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

# -- Failsafe-mediated production updates -------------------------------------

_wait_for_device() {
  # Wait for an mDNS device name (e.g. failsafe-1a7cfc) to appear, up to timeout
  # seconds. Returns 0 if found, 1 on timeout.
  local name="$1"
  local timeout="${2:-60}"
  local waited=0
  # Failsafe devices advertise _iotstack-failsafe._tcp; production uses _esphomelib._tcp
  local mdns_svc="_esphomelib._tcp"
  [[ "$name" == failsafe-* ]] && mdns_svc="_iotstack-failsafe._tcp"
  while (( waited < timeout )); do
    if [[ "$name" == failsafe-* ]] && _iotstack_ota_tcp_open "$name" 3232; then
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
    if [[ "$hostname" =~ -${mac}$ ]] && [[ "$hostname" != failsafe-* ]]; then
      echo "$hostname"
      return 0
    fi
  done < <(avahi-browse -t -r _esphomelib._tcp 2>/dev/null)
  return 1
}

_device_on_failsafe() {
  local mac="$1"
  avahi-browse -t -r _iotstack-failsafe._tcp 2>/dev/null | grep -Fqi "failsafe-${mac}"
}

_failsafe_device_ota_password() {
  # NVS stores sha256(failsafe_role_secret | mac) -- used for OTA from failsafe.
  local mac="$1"
  local fs_secret
  fs_secret=$(pass show "iotstack/roles/failsafe/ota_password" 2>/dev/null)
  [[ -z "$fs_secret" ]] && return 1
  echo -n "${fs_secret}|${mac}" | sha256sum | cut -c1-32
}

_wait_for_ota_service() {
  # Wait for ESPHome OTA (port 3232) on a device hostname.
  local hostname="$1"
  local max_wait="${2:-90}"
  local waited=0
  while (( waited < max_wait )); do
    if timeout 3 bash -c "echo > /dev/tcp/${hostname}.local/3232" 2>/dev/null; then
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
    (( waited % 15 == 0 )) && info "  ...still waiting for ${hostname} OTA service ($waited/${max_wait}s)"
  done
  return 1
}

_iotstack_ota_tcp_open() {
  # Return 0 when hostname.local accepts a TCP connection on port.
  local hostname="$1"
  local port="$2"
  timeout 3 bash -c "echo > /dev/tcp/${hostname}.local/${port}" 2>/dev/null
}

_failsafe_ota_reachable() {
  # Failsafe firmware advertises failsafe-<mac> with OTA on 3232.
  local device_mac="$1"
  _iotstack_ota_tcp_open "failsafe-${device_mac}" 3232
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

_flash_production_ota_update() {
  # OTA into the production partition via failsafe (production images have no OTA server).
  # Usage: _flash_production_ota_update <mac_suffix> <yaml_path> [device_role] [tty_device]
  local device_mac="$1"
  local yaml_path="$2"
  local device_role="${3:-}"
  local tty_device="${4:-}"
  local dev_pwd prod_hostname
  [[ -z "$device_role" ]] && device_role=$(_yaml_device_role "$yaml_path")
  prod_hostname="${device_role}-${device_mac}"
  dev_pwd=$(_failsafe_device_ota_password "$device_mac") \
    || err "Could not derive failsafe OTA password for ${device_mac} (provision failsafe first?)"

  if ! _production_api_reachable "$prod_hostname" && ! _failsafe_ota_reachable "$device_mac"; then
    warn "Production API and failsafe OTA are unreachable -- network switch may fail"
  fi

  declare -a extra_args=(--upgrade-delta)
  [[ "${FLASH_ANYWAY:-0}" == "1" ]] && extra_args+=(--flash-anyway)
  if [[ -n "$tty_device" ]]; then
    _ota_via_failsafe "$device_mac" "$yaml_path" "$dev_pwd" "$prod_hostname" "$tty_device" "${extra_args[@]}"
  else
    _ota_via_failsafe "$device_mac" "$yaml_path" "$dev_pwd" "$prod_hostname" "${extra_args[@]}"
  fi
}

_wait_for_production_online() {
  # Wait for production firmware after OTA from failsafe.
  # Production images omit ota: (no port 3232). Detect the role hostname via API
  # (6053) and/or _esphomelib._tcp mDNS -- not the failsafe IP/OTA port.
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
  # ESPHome config_hash from mDNS TXT (same value shown in iotstack devices / failsafe).
  # Production: _esphomelib._tcp; failsafe recovery: _iotstack-failsafe._tcp.
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
  # Default: mDNS config_hash (fast, same as iotstack devices).
  # --on-flash-verify: full USB read-flash MD5 of the production partition.
  local prod_hostname="$1"
  local yaml_path="$2"
  local tty_device="${3:-}"

  [[ "${FLASH_ANYWAY:-0}" == "1" ]] && return 1

  if [[ "${FLASH_ON_FLASH_VERIFY:-0}" == "1" ]]; then
    [[ -n "$tty_device" ]] && _flash_production_firmware_current "$tty_device" "$yaml_path"
    return $?
  fi

  local mdns_hash build_hash
  mdns_hash=$(_mdns_config_hash_for_hostname "$prod_hostname" 2>/dev/null) || return 1
  build_hash=$(_build_config_hash_for_yaml "$yaml_path" 2>/dev/null) || return 1
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
    [[ "$_part_csv" == *"/build/failsafe/partitions.csv" ]] \
      && debug "On-flash production offset ${_FLASH_PROD_OFFSET} (from failsafe build partition table)"
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

_flash_failsafe_image_hash_on_device() {
  # First 8 hex chars of the failsafe-partition MD5 read from serial flash.
  local tty_device="$1"
  local build_dir="${YAMLS_DIR}/.esphome/build/failsafe/.pioenvs/failsafe"
  local firmware_file="${build_dir}/firmware.bin"
  local failsafe_offset chip file_size md5
  failsafe_offset=$(flash_partition_offset failsafe 2>/dev/null) || failsafe_offset=""
  [[ -f "$firmware_file" && -n "$failsafe_offset" ]] || return 1
  chip=$(esp_detect_chip "$tty_device" 2>/dev/null) || return 1
  file_size=$(stat -c%s "$firmware_file" 2>/dev/null) || return 1
  md5=$(flash_read_region_md5 "$tty_device" "$chip" "$failsafe_offset" "$file_size") || return 1
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
  local hostname="$1"
  timeout 3 bash -c "echo > /dev/tcp/${hostname}.local/6053" 2>/dev/null
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

_build_config_hash_for_yaml() {
  # config_hash for comparing device mDNS against the compiled build (8-char hex).
  # Primary source: compilation-cache.csv (same cache smart_compile maintains).
  local yaml_path="$1"
  local yaml_name cache_file hash latest_log
  yaml_name=$(basename "$yaml_path" .yaml)
  hash=$(_compilation_cache_config_hash "$yaml_path" "$yaml_name" 2>/dev/null) || true
  [[ -n "$hash" ]] && { echo "$hash"; return 0; }
  hash=$(_build_config_hash_from_build_dir "$yaml_name" 2>/dev/null) || true
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
FLASH_ASSESS_FAILSAFE_ONLINE=0
FLASH_ASSESS_FLASH_CURRENT=0

_flash_assess_device_runtime() {
  # Quick WiFi/runtime probe (no compile). Sets FLASH_ASSESS_PROD_ONLINE / FAILSAFE_ONLINE.
  local device_mac="$1"
  local prod_hostname="$2"
  local tty_device="${3:-}"
  local max_retry="${4:-12}"
  local waited=0 failsafe_hash failsafe_hostname

  FLASH_ASSESS_PROD_ONLINE=0
  FLASH_ASSESS_PROD_MDNS=0
  FLASH_ASSESS_FAILSAFE_ONLINE=0

  while true; do
    if _production_api_reachable "$prod_hostname"; then
      FLASH_ASSESS_PROD_ONLINE=1
      break
    fi
    if _failsafe_ota_reachable "$device_mac"; then
      FLASH_ASSESS_FAILSAFE_ONLINE=1
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

  info "Assessment result:"
  info "  MAC suffix: ${device_mac}"
  failsafe_hostname="failsafe-${device_mac}"
  if [[ "${FLASH_ON_FLASH_VERIFY:-0}" == "1" && -n "$tty_device" ]]; then
    info "  Reading on-flash failsafe partition via USB..."
    failsafe_hash=$(_flash_failsafe_image_hash_on_device "$tty_device" 2>/dev/null) || failsafe_hash="unknown"
    info "  On-flash failsafe: ${failsafe_hostname} (image hash ${failsafe_hash})"
  elif [[ $FLASH_ASSESS_FAILSAFE_ONLINE -eq 1 ]]; then
    failsafe_hash=$(_mdns_config_hash_for_hostname "$failsafe_hostname" "_iotstack-failsafe._tcp" 2>/dev/null) \
      || failsafe_hash="unknown"
    info "  Runtime failsafe: ${failsafe_hostname} (config_hash ${failsafe_hash})"
  elif [[ -n "$tty_device" ]]; then
    info "  Failsafe: not on WiFi (use --on-flash-verify for USB partition check)"
  fi
  if [[ $FLASH_ASSESS_PROD_ONLINE -eq 1 ]]; then
    local running_hash
    running_hash=$(_mdns_config_hash_for_hostname "$prod_hostname" 2>/dev/null) || running_hash="unknown"
    info "  Runtime: production API online (${prod_hostname}, config_hash ${running_hash})"
  elif [[ $FLASH_ASSESS_PROD_MDNS -eq 1 ]]; then
    local mdns_only_hash
    mdns_only_hash=$(_mdns_config_hash_for_hostname "$prod_hostname" 2>/dev/null) || mdns_only_hash="unknown"
    info "  Runtime: production on mDNS only (${prod_hostname}, config_hash ${mdns_only_hash}, API port 6053 not reachable)"
  elif [[ $FLASH_ASSESS_FAILSAFE_ONLINE -eq 1 ]]; then
    info "  Runtime: failsafe online (failsafe-${device_mac}, OTA port 3232)"
  else
    info "  Runtime: not reachable on WiFi (no production or failsafe mDNS/API)"
  fi
}

_flash_assess_device_on_flash_action() {
  # On-flash compare + recommended action (requires compiled build artifacts).
  local tty_device="$1"
  local yaml_path="$2"
  local device_mac="$3"
  local prod_hostname="$4"
  local running_hash build_hash mdns_hash device_md5 local_md5 local_image_hash firmware_file

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
      info "  Reading on-flash production partition via USB (offset ${_FLASH_PROD_OFFSET})..."
      device_md5=$(_flash_read_production_partition_md5 "$tty_device" "$yaml_path" 2>/dev/null) || device_md5=""
      if [[ -n "$device_md5" ]]; then
        running_hash="${device_md5:0:8}"
        if [[ "${FLASH_ANYWAY:-0}" != "1" && -n "$local_md5" && "$local_md5" == "$device_md5" ]]; then
          FLASH_ASSESS_FLASH_CURRENT=1
        fi
      fi
    fi
  elif [[ "${FLASH_ANYWAY:-0}" != "1" ]] \
     && _flash_production_matches_build "$prod_hostname" "$yaml_path" "$tty_device"; then
    FLASH_ASSESS_FLASH_CURRENT=1
    running_hash="${mdns_hash:-unknown}"
  fi

  build_hash=$(_build_config_hash_for_yaml "$yaml_path" 2>/dev/null) || build_hash=""
  if [[ "${FLASH_ANYWAY:-0}" != "1" \
     && $FLASH_ASSESS_FLASH_CURRENT -eq 0 \
     && -n "$mdns_hash" && -n "$build_hash" && "$mdns_hash" == "$build_hash" ]]; then
    FLASH_ASSESS_FLASH_CURRENT=1
    running_hash="$mdns_hash"
  fi

  if [[ "${FLASH_ANYWAY:-0}" == "1" ]]; then
    if [[ -n "$mdns_hash" && -n "$build_hash" && "$mdns_hash" == "$build_hash" ]]; then
      info "  Production: matches build (config_hash ${mdns_hash}) -- --flash-anyway will reflash"
    else
      info "  Production: --flash-anyway will reflash"
    fi
  elif [[ $FLASH_ASSESS_FLASH_CURRENT -eq 1 ]]; then
    if [[ "${FLASH_ON_FLASH_VERIFY:-0}" == "1" ]]; then
      if [[ -n "$build_hash" ]]; then
        info "  On-flash production: matches build (image ${running_hash}, config_hash ${build_hash})"
      else
        info "  On-flash production: matches build (image ${running_hash})"
      fi
    elif [[ -n "$mdns_hash" && -n "$build_hash" ]]; then
      info "  Production: matches build (config_hash ${mdns_hash})"
    else
      info "  Production: matches build"
    fi
  elif [[ "${FLASH_ON_FLASH_VERIFY:-0}" == "1" && -n "$local_image_hash" && "$running_hash" != "unknown" ]]; then
    if [[ -n "$mdns_hash" && "$mdns_hash" == "$build_hash" ]]; then
      info "  On-flash production: image ${running_hash} != build image ${local_image_hash} (runtime config_hash ${mdns_hash} matches build)"
    else
      info "  On-flash production: image ${running_hash} != build image ${local_image_hash} (config_hash ${build_hash:-unknown})"
    fi
  elif [[ -n "$mdns_hash" && -n "$build_hash" ]]; then
    info "  Production: runtime config_hash ${mdns_hash} != build config_hash ${build_hash}"
  elif [[ -n "$build_hash" ]]; then
    info "  Production: differs from build (config_hash ${build_hash}; runtime hash unavailable)"
  else
    info "  Production: differs from build"
  fi

  if [[ "${FLASH_ANYWAY:-0}" == "1" && $FLASH_ASSESS_PROD_ONLINE -eq 1 ]]; then
    info "  Action: force reflash production firmware (--flash-anyway)"
  elif [[ $FLASH_ASSESS_FLASH_CURRENT -eq 1 && $FLASH_ASSESS_PROD_ONLINE -eq 1 ]]; then
    local assess_role="${prod_hostname%-${device_mac}}"
    local want_cols want_w want_h cur_cols cur_w cur_h
    if _flash_matrix_layout_applicable "$assess_role" ""; then
      _flash_resolve_matrix_layout "$assess_role" want_cols want_w want_h
      if _flash_read_matrix_layout_from_device "$prod_hostname" "$device_mac" "$assess_role" \
          cur_cols cur_w cur_h; then
        info "  Matrix layout (runtime): ${cur_cols} panel(s), ${cur_w}x${cur_h} px"
        if [[ "$cur_cols" != "$want_cols" || "$cur_w" != "$want_w" || "$cur_h" != "$want_h" ]]; then
          info "  Matrix layout (target) : ${want_cols} panel(s), ${want_w}x${want_h} px"
          info "  Action: switch to failsafe and update matrix layout NVS (firmware is current)"
        else
          info "  Action: none required -- device is current"
        fi
      elif _flash_matrix_layout_flags_set; then
        info "  Matrix layout (target) : ${want_cols} panel(s), ${want_w}x${want_h} px"
        info "  Action: switch to failsafe and update matrix layout NVS (firmware is current)"
      else
        info "  Action: none required -- device is current"
      fi
    else
      info "  Action: none required -- device is current"
    fi
  elif [[ $FLASH_ASSESS_PROD_ONLINE -eq 1 ]]; then
    info "  Action: reboot into failsafe to perform update of production partition"
  elif [[ $FLASH_ASSESS_PROD_MDNS -eq 1 ]]; then
    info "  Action: serial failsafe path (mDNS visible, API unreachable), then OTA production image"
  elif [[ $FLASH_ASSESS_FAILSAFE_ONLINE -eq 1 ]]; then
    info "  Action: refresh failsafe on serial if needed, then OTA production image"
  else
    info "  Action: flash failsafe via serial, then OTA production image"
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

_ensure_device_on_failsafe() {
  # Switch a production device into failsafe and wait for its OTA service.
  local mac="$1"
  local is_dry_run="${2:-false}"
  local tty_device="${3:-}"
  local switch_failed=false
  local wait_timeout=90
  if [[ "$is_dry_run" == true ]]; then
    return 0
  fi

  if _failsafe_ota_reachable "$mac" || _device_on_failsafe "$mac"; then
    info "[$mac] already on failsafe"
  else
    local production_hostname
    production_hostname=$(_find_production_hostname_for_mac "$mac" || true)
    if [[ -n "$production_hostname" ]]; then
      if _production_api_reachable "$production_hostname"; then
        info "[$mac] 1/4 switching $production_hostname to failsafe..."
        local attempt
        for attempt in 1 2 3; do
          if _call_production_api_service "$production_hostname" "$mac" switch_to_failsafe; then
            switch_failed=false
            break
          fi
          switch_failed=true
          (( attempt < 3 )) && sleep 5
        done
        [[ "$switch_failed" == true ]] && warn "[$mac] switch_to_failsafe failed after 3 attempts"
      else
        switch_failed=true
        warn "[$mac] production API unreachable -- cannot call switch_to_failsafe"
      fi
    else
      switch_failed=true
      warn "[$mac] not found in production mDNS"
    fi
  fi

  if [[ "$switch_failed" == true ]]; then
    wait_timeout=30
    if [[ -n "$tty_device" ]]; then
      info "[$mac] 2/4 waiting ${wait_timeout}s for failsafe-$mac (then USB serial fallback)..."
    else
      info "[$mac] 2/4 waiting ${wait_timeout}s for failsafe-$mac on the network..."
    fi
  else
    info "[$mac] 2/4 waiting for failsafe-$mac on the network..."
  fi
  if ! _wait_for_device "failsafe-$mac" "$wait_timeout"; then
    if [[ -n "$tty_device" ]]; then
      warn "[$mac] failsafe-$mac did not appear -- use USB serial fallback"
    else
      warn "[$mac] failsafe-$mac did not appear"
    fi
    return 1
  fi

  info "[$mac] 3/4 waiting for failsafe OTA service..."
  if ! _wait_for_ota_service "failsafe-$mac" 90; then
    warn "[$mac] failsafe-$mac OTA service not reachable"
    return 1
  fi
  sleep 2
  return 0
}

_failsafe_update_nvs_device_role() {
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
    "matrix_panel_w": "",
    "matrix_panel_h": "",
    "device_role": os.environ["DEVICE_ROLE"],
}))
PY
  ) || return 1
  _nvs_update_via_failsafe_api "$device_mac" "$json_vars"
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

_ota_via_failsafe() {
  # OTA into the production slot via failsafe (partition-safe path).
  # Usage: _ota_via_failsafe <mac> <yaml_file> <ota_password> <post_ota_hostname> [tty_device] [update_args...]
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

  if ! _ensure_device_on_failsafe "$mac" "$is_dry_run" "$tty_device"; then
    return 1
  fi

  if [[ "$is_dry_run" != true ]]; then
    local conf_role
    conf_role=$(basename "$yaml_file" .yaml)
    if _failsafe_update_nvs_device_role "$mac" "$conf_role"; then
      debug "[$mac] NVS device_role set to $conf_role"
      sleep 3
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
    elif _wait_for_production_online "$post_ota_hostname" 90; then
      ok "[$mac] reassigned and back as $post_ota_hostname"
      _ha_after_production_online "$yaml_file" "$post_ota_hostname"
    else
      warn "[$mac] not seen as $post_ota_hostname yet (may still be booting)"
    fi
  fi
  return 0
}

_reassign_devices_via_failsafe() {
  # Reassign one or more devices to a new role/YAML via the failsafe partition.
  # Usage: _reassign_devices_via_failsafe <yaml_file> <ota_password> <mac...> -- [update_args...]
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
    if ! pass show "iotstack/roles/failsafe/ota_password" &>/dev/null; then
      err "Failsafe role OTA password not found in pass (provision a device first)."
    fi
  fi

  local target_role
  target_role=$(_yaml_device_role "$yaml_file")

  info "Reassigning ${#macs[@]} device(s) to '$target_role' via failsafe..."
  local failed=0 mac dev_pwd
  for mac in "${macs[@]}"; do
    echo ""
    dev_pwd="$ota_password"
    if [[ -z "$dev_pwd" ]]; then
      dev_pwd=$(_failsafe_device_ota_password "$mac") || err "Could not derive failsafe OTA password for $mac"
      echo "  OTA Password: (derived from failsafe role secret)"
    fi
    if ! _ota_via_failsafe "$mac" "$yaml_file" "$dev_pwd" "${target_role}-${mac}" "${ota_update_args[@]}"; then
      failed=$((failed + 1))
    fi
  done

  echo ""
  if [[ $failed -eq 0 ]]; then
    ok "All device(s) reassigned via failsafe"
    return 0
  fi
  warn "$failed device(s) failed to reassign"
  return 1
}

_update_via_failsafe() {
  # Update production devices the safe way: switch each into failsafe, then OTA
  # the new image into the production slot. OTA never writes the running
  # partition, so updating from failsafe always targets production (ota_1) and
  # the failsafe image (ota_0) is never overwritten. ESPHome's OTA auto-reboots
  # the device back into production when done.
  #
  # Usage: _update_via_failsafe <role> <yaml_file> [mac ...]
  local role="$1"
  local yaml_file="$2"
  shift 2
  local -a want_macs=("$@")

  # Discover role-<mac> devices currently on the network
  local -a macs=()
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ ${role}-([0-9a-f]{6}) ]]; then
      macs+=("${BASH_REMATCH[1]}")
    fi
  done < <(avahi-browse -t -r _esphomelib._tcp 2>/dev/null)
  [[ ${#macs[@]} -gt 0 ]] && mapfile -t macs < <(printf '%s\n' "${macs[@]}" | sort -u)

  # Filter to requested MAC suffixes if any were given
  if [[ ${#want_macs[@]} -gt 0 ]]; then
    local -a filtered=()
    local m w
    for m in "${macs[@]}"; do
      for w in "${want_macs[@]}"; do
        [[ "$m" == "$w" ]] && filtered+=("$m")
      done
    done
    macs=("${filtered[@]}")
  fi

  if [[ ${#macs[@]} -eq 0 ]]; then
    err "No '$role' device(s) found on the network."
  fi

  local fs_secret
  fs_secret=$(pass show "iotstack/roles/failsafe/ota_password" 2>/dev/null)
  [[ -z "$fs_secret" ]] && err "Failsafe role OTA password not found in pass (provision a device first)."

  info "Updating ${#macs[@]} '$role' device(s) via failsafe..."
  local failed=0 mac dev_pwd
  for mac in "${macs[@]}"; do
    echo ""
    dev_pwd=$(echo -n "${fs_secret}|${mac}" | sha256sum | cut -c1-32)
    if ! _ota_via_failsafe "$mac" "$yaml_file" "$dev_pwd" "${role}-${mac}"; then
      failed=$((failed + 1))
    fi
  done

  echo ""
  if [[ $failed -eq 0 ]]; then
    ok "All '$role' device(s) updated via failsafe"
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
      --dry-run|--flash-anyway|--jobs)
        update_args+=("$1")
        if [[ "$1" == "--jobs" ]]; then
          shift
          update_args+=("$1")
        fi
        shift
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

    # For a known production role (not a raw yaml path, not the failsafe role,
    # not a dry run), update via failsafe so the OTA can never overwrite the
    # failsafe image. Otherwise fall back to a direct OTA.
    local _dry_run=0 _arg
    for _arg in ${update_args[@]+"${update_args[@]}"}; do
      [[ "$_arg" == "--dry-run" ]] && _dry_run=1
    done
    if [[ $_dry_run -eq 0 && "$device_or_yaml" != "failsafe" ]] && is_valid_role "$device_or_yaml"; then
      _update_via_failsafe "$device_or_yaml" "$yaml_file" ${mac_suffixes[@]+"${mac_suffixes[@]}"}
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
    info "Dry run: will compile target firmware (device need not be on failsafe yet)"
  fi

  if [[ -n "$api_key" ]]; then
    echo "  OTA Password: (provided)"
  else
    echo "  OTA Password: (will derive from failsafe role secret per device)"
  fi
  echo

  _reassign_devices_via_failsafe "$yaml_file" "$api_key" "${reassign_macs[@]}" -- "${update_args[@]}"
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

  # Parse flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
        # Support `iotstack devices help` / `iotstack failsafe help` / `iotstack roles help`
        case "$subcommand" in
          roles)    help_roles ;;
          failsafe) help_failsafe ;;
          *)        help_devices ;;
        esac
        return 0
        ;;
      devices|roles|failsafe)
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

  case "$subcommand" in
    devices)
      list_devices "$output_format" "$filter_role" "$suffix_only"
      ;;
    failsafe)
      list_devices "$output_format" "" "$suffix_only" "_iotstack-failsafe._tcp"
      ;;
    roles)
      list_roles "$output_format" "$suffix_only"
      ;;
    *)
      err "Unknown subcommand: $subcommand. Try 'iotstack devices', 'iotstack failsafe', or 'iotstack roles'"
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

  # Export GPG and pass environment for iotstack-secrets
  export GNUPGHOME="${HOME}/.iotstack/.gnupg"
  export PASSWORD_STORE_DIR="${HOME}/.iotstack/.pass"

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
  mac_line=$(iotstack devices "$role" --id 2>/dev/null)
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

  # OTA each device via failsafe so the production slot is updated safely.
  # Devices authenticate OTA with sha256(failsafe_role_secret | mac) from NVS.
  local yaml_file
  yaml_file=$(resolve_device "$role")

  echo "[INFO] Flashing devices via failsafe (partition-safe OTA)..."
  echo

  local success_count=0
  local fail_count=0
  declare -a failed_macs=()
  local mac dev_pwd

  for mac in "${mac_suffixes[@]}"; do
    dev_pwd=$(_failsafe_device_ota_password "$mac") || err "Could not derive failsafe OTA password for $mac"
    if _ota_via_failsafe "$mac" "$yaml_file" "$dev_pwd" "${role}-${mac}"; then
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
    echo "Role,Board,Variant,Network,Status,Config"
    # Collect and sort roles by status (prod first) then by name
    {
      list_roles_from_conf | while read -r device; do
        local yaml_file board variant network_type dev_status config_file device_info
        yaml_file="${YAMLS_DIR}/${device}.yaml"

        if [[ -f "$yaml_file" ]]; then
          device_info=$(get_yaml_device_info "$yaml_file")
          board=$(echo "$device_info" | cut -d'|' -f1)
          variant=$(echo "$device_info" | cut -d'|' -f2)
          network_type=$(echo "$device_info" | cut -d'|' -f3)
          dev_status=$(echo "$device_info" | cut -d'|' -f4)
          config_file=$(basename "$yaml_file")
        else
          board=""
          variant=""
          network_type=""
          dev_status=""
          config_file=""
        fi

        # Add sort key: prod=0, dev=1, then role name
        local sort_key
        case "$dev_status" in
          prod) sort_key="0" ;;
          *) sort_key="1" ;;
        esac
        printf "%s_%s|%s,%s,%s,%s,%s,%s\n" "$sort_key" "$device" "$device" "$board" "$variant" "$network_type" "$dev_status" "$config_file"
      done
    } | sort -t_ -k1,1 -k2 | cut -d'|' -f2-
  elif [[ "$output_format" == "json" ]]; then
    {
      list_roles_from_conf | while read -r device; do
        local yaml_file board variant network_type dev_status config_file device_info
        yaml_file="${YAMLS_DIR}/${device}.yaml"

        if [[ -f "$yaml_file" ]]; then
          device_info=$(get_yaml_device_info "$yaml_file")
          board=$(echo "$device_info" | cut -d'|' -f1)
          variant=$(echo "$device_info" | cut -d'|' -f2)
          network_type=$(echo "$device_info" | cut -d'|' -f3)
          dev_status=$(echo "$device_info" | cut -d'|' -f4)
          config_file=$(basename "$yaml_file")
        else
          board=""
          variant=""
          network_type=""
          dev_status=""
          config_file=""
        fi

        local sort_key
        case "$dev_status" in
          prod) sort_key="0" ;;
          *) sort_key="1" ;;
        esac
        printf "%s_%s|%s|%s|%s|%s|%s|%s\n" "$sort_key" "$device" "$device" "$board" "$variant" "$network_type" "$dev_status" "$config_file"
      done
    } | sort -t_ -k1,1 -k2 | cut -d'|' -f2- | while IFS='|' read -r device board variant network_type dev_status config_file; do
      jq -nc \
        --arg role "$device" \
        --arg board "$board" \
        --arg variant "$variant" \
        --arg network "$network_type" \
        --arg status "$dev_status" \
        --arg config "$config_file" \
        '{role: $role, board: $board, variant: $variant, network: $network, status: $status, config: $config}'
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
      local yaml_file board variant network_type dev_status config_display device_info
      yaml_file="${YAMLS_DIR}/${device}.yaml"

      if [[ -f "$yaml_file" ]]; then
        device_info=$(get_yaml_device_info "$yaml_file")
        board=$(echo "$device_info" | cut -d'|' -f1)
        variant=$(echo "$device_info" | cut -d'|' -f2)
        network_type=$(echo "$device_info" | cut -d'|' -f3)
        dev_status=$(echo "$device_info" | cut -d'|' -f4)
        config_display=$(basename "$yaml_file")
      else
        board=""
        variant=""
        network_type=""
        dev_status=""
        config_display=""
      fi

      # Add sort key: prod=0, dev=1, then role name
      local sort_key
      case "$dev_status" in
        prod) sort_key="0" ;;
        *) sort_key="1" ;;
      esac
      printf "%s_%s|%s|%s|%s|%s|%s|%s\n" "$sort_key" "$device" "$device" "$board" "$variant" "$network_type" "$dev_status" "$config_display" >> "$temp_unsorted"
    done < <(list_roles_from_conf)

    # Sort by status (prod first) then by role name
    sort -t_ -k1,1 -k2 "$temp_unsorted" | cut -d'|' -f2- > "$temp_data"

    # Calculate column widths
    local header_role="Role"
    local header_board="Board"
    local header_variant="Variant"
    local header_network="Network"
    local header_status="Status"
    local header_config="Config"

    local w_role=$(( ${#header_role} + margin ))
    local w_board=$(( ${#header_board} + margin ))
    local w_variant=$(( ${#header_variant} + margin ))
    local w_network=$(( ${#header_network} + margin ))
    local w_status=$(( ${#header_status} + margin ))
    local w_config=$(( ${#header_config} + margin ))

    while IFS='|' read -r device board variant network_type dev_status config_display; do
      (( ${#device} + margin > w_role )) && w_role=$(( ${#device} + margin ))
      (( ${#board} + margin > w_board )) && w_board=$(( ${#board} + margin ))
      (( ${#variant} + margin > w_variant )) && w_variant=$(( ${#variant} + margin ))
      (( ${#network_type} + margin > w_network )) && w_network=$(( ${#network_type} + margin ))
      (( ${#dev_status} + margin > w_status )) && w_status=$(( ${#dev_status} + margin ))
      (( ${#config_display} + margin > w_config )) && w_config=$(( ${#config_display} + margin ))
    done < "$temp_data"

    info "Available device roles:"
    echo

    # Print headers
    printf "  ${GRN}%-${w_role}s %-${w_board}s %-${w_variant}s %-${w_network}s %-${w_status}s %-${w_config}s${RST}\n" \
      "$header_role" "$header_board" "$header_variant" "$header_network" "$header_status" "$header_config"

    # Print separator
    _print_table_rule "$w_role" "$w_board" "$w_variant" "$w_network" "$w_status" "$w_config"

    # Print data rows
    while IFS='|' read -r device board variant network_type dev_status config_display; do
      printf "  ${GRN}%-${w_role}s${RST} %-${w_board}s %-${w_variant}s %-${w_network}s %-${w_status}s %-${w_config}s\n" \
        "$device" "$board" "$variant" "$network_type" "$dev_status" "$config_display"
    done < "$temp_data"


    echo
    ok Consider running 'iotstack devices' next.
    echo
  fi
}

# -- HA device registration --------------------------------------------------

_ha_after_production_online() {
  # Home Assistant work runs only after production firmware is online -- never
  # while the device is still advertising as failsafe-*.
  local yaml_path="$1"
  local prod_hostname="$2"

  if ! _load_ha_credentials_optional; then
    return 0
  fi
  [[ -z "$HA_URL" || -z "$HA_TOKEN" ]] && return 0

  _ha_register_esphome_device "$prod_hostname" "$yaml_path"
  _run_update_devices --ha-finalize "$prod_hostname" "$yaml_path"
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

_call_production_api_service() {
  # Invoke a native-API user service on a running production device.
  local production_hostname="$1"
  local mac="$2"
  local service="$3"
  local role noise_psk api_host api_src

  role="${production_hostname%-${mac}}"
  api_host="${production_hostname}.local"
  api_src="esphome:api:${service}"
  noise_psk=$(_device_api_noise_psk_b64 "$role" "$mac" 2>/dev/null) || true
  if [[ -n "$noise_psk" ]]; then
    if create_log_child_output_piped; then
      IOTSTACK_API_NOISE_PSK="$noise_psk" \
        create_log_run "$api_src" "$SCRIPT_DIR/scripts/esphome-service.sh" "$api_host" "$service"
    else
      IOTSTACK_API_NOISE_PSK="$noise_psk" \
        "$SCRIPT_DIR/scripts/esphome-service.sh" "$api_host" "$service"
    fi
  else
    warn "[$mac] no API encryption key in pass for role ${role}; trying plaintext API"
    if create_log_child_output_piped; then
      create_log_run "$api_src" "$SCRIPT_DIR/scripts/esphome-service.sh" "$api_host" "$service"
    else
      "$SCRIPT_DIR/scripts/esphome-service.sh" "$api_host" "$service"
    fi
  fi
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

  echo "$reg_out" >&2
  if invalidate_ha_token_if_auth_failure "$reg_out"; then
    err "Home Assistant access token is invalid -- iotstack/common/ha_token reset to CONFIGURE_ME. Configure a new token and retry."
  fi
  err "Home Assistant registration failed for $hostname
Complete manually: ${HA_URL}/config/integrations/dashboard"
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
Usage: iotstack set-boot <device> <failsafe|production>

Set which partition a failsafe device boots into.

Arguments:
  <device>      MAC suffix (e.g., 1af95c) OR serial device (e.g., /dev/ttyACM0)
  <partition>   failsafe or production

Examples:
  Network device (by MAC):
    iotstack set-boot 1af95c failsafe          # Set failsafe-1af95c -> failsafe
    iotstack set-boot 9019c8 production        # Set failsafe-9019c8 -> production

  USB-connected device:
    iotstack set-boot /dev/ttyACM0 failsafe    # Set /dev/ttyACM0 -> failsafe
    iotstack set-boot /dev/ttyUSB0 production  # Set /dev/ttyUSB0 -> production
EOF
    exit 1
  fi

  if [[ ! "$partition" =~ ^(failsafe|production)$ ]]; then
    err "Partition must be 'failsafe' or 'production'"
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
    info "Setting failsafe-$device to boot: $partition"
    _boot_partition_network "$partition" "$device"
  fi
}

_boot_partition_usb() {
  # Set boot partition on USB-connected device
  local device="$1"
  local partition="$2"

  # Device must be running failsafe-wifi firmware for this to work
  info "Toggling boot partition..."
  if timeout 5 curl -s -X POST "http://localhost:6053/api/services/button/press" \
    -H "Content-Type: application/json" \
    -d '{"entity_id": "button.failsafe_toggle_boot_partition"}' >/dev/null 2>&1; then
    ok "Boot partition toggled to: $partition"
  else
    err "Could not communicate with device. Ensure it's running and connected."
  fi
}

_boot_partition_network() {
  # Toggle boot partition on a network device identified by MAC suffix.
  # Tries failsafe-<mac> first, then any known production role hostname.
  local target_partition="$1"
  local mac="$2"
  local mac_lower host entity_id

  mac_lower=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
  info "Setting device ${mac_lower} to boot: $target_partition..."

  local -a hosts=("failsafe-${mac_lower}")
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

  err "Could not reach device ${mac_lower} on network (tried failsafe + production hostnames)"
}

_boot_partition_single() {
  _boot_partition_network "$1" "$2"
}

_flash_matrix_layout_applicable() {
  # Matrix NVS layout options apply to matrixdisplay production flashes only.
  local device="$1"
  local second="${2:-}"
  [[ "$device" == "matrixdisplay" ]] && return 0
  [[ "$device" == "failsafe" && "$second" == "matrixdisplay" ]] && return 0
  return 1
}

_flash_matrix_layout_flags_set() {
  [[ -n "${MATRIX_COLS}${MATRIX_PANEL_W}${MATRIX_PANEL_H}" ]]
}

_flash_resolve_matrix_layout() {
  # Resolve target panel layout (flags -> pass -> defaults). Sets named refs.
  local role="$1"
  local -n _cols_ref="$2"
  local -n _w_ref="$3"
  local -n _h_ref="$4"

  _cols_ref="${MATRIX_COLS:-}"
  _w_ref="${MATRIX_PANEL_W:-}"
  _h_ref="${MATRIX_PANEL_H:-}"
  if [[ -n "$role" ]]; then
    [[ -z "$_cols_ref" ]] && _cols_ref=$(pass show "iotstack/roles/${role}/matrix_cols" 2>/dev/null || echo "")
    [[ -z "$_w_ref" ]] && _w_ref=$(pass show "iotstack/roles/${role}/matrix_panel_w" 2>/dev/null || echo "")
    [[ -z "$_h_ref" ]] && _h_ref=$(pass show "iotstack/roles/${role}/matrix_panel_h" 2>/dev/null || echo "")
  fi
  _cols_ref="${_cols_ref:-1}"
  _w_ref="${_w_ref:-64}"
  _h_ref="${_h_ref:-32}"
  if [[ "$_cols_ref" != "1" && "$_cols_ref" != "2" ]]; then
    err "Panel count must be 1 or 2 (got: $_cols_ref)"
  fi
}

_flash_read_matrix_layout_from_device() {
  # Read active matrix layout from production text_sensors. Sets named refs; returns 0 on success.
  local prod_hostname="$1"
  local mac="$2"
  local role="$3"
  local -n _cols_ref="$4"
  local -n _w_ref="$5"
  local -n _h_ref="$6"
  local api_host="${prod_hostname}.local"
  local noise_psk output line key val

  _cols_ref="" _w_ref="" _h_ref=""
  noise_psk=$(_device_api_noise_psk_b64 "$role" "$mac" 2>/dev/null) || true
  local -a _layout_sensor_ids=(panel_count matrix_panel_width matrix_panel_height)
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
      matrix_panel_width) _w_ref="$val" ;;
      matrix_panel_height) _h_ref="$val" ;;
    esac
  done <<< "$output"

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
# Prefer failsafe update_nvs_secrets over WiFi/API. USB (write-nvs-secrets.sh)
# is used only when failsafe is unreachable -- typical on first serial provision
# before WiFi credentials exist in NVS, or when failsafe lacks the API service.

_call_failsafe_api_service() {
  # Invoke a native-API user service on failsafe firmware (plaintext API, port 6053).
  local device_mac="$1"
  local service="$2"
  local json_vars="${3:-}"
  local api_host="failsafe-${device_mac}.local"
  local api_src="esphome:api:${service}"

  if create_log_child_output_piped; then
    create_log_run "$api_src" "$SCRIPT_DIR/scripts/esphome-service.sh" \
      "$api_host" "$service" "" "$json_vars"
    return $?
  fi
  "$SCRIPT_DIR/scripts/esphome-service.sh" "$api_host" "$service" "" "$json_vars"
}

_nvs_secrets_api_json_payload() {
  # Build update_nvs_secrets JSON (stdout only). Uses pass + env (MATRIX_* flags).
  local device_mac="$1"
  local production_role="${2:-}"
  "$SCRIPT_DIR/scripts/write-nvs-secrets.sh" --print-api-json "$device_mac" "$production_role"
}

_failsafe_api_reachable() {
  local device_mac="$1"
  _production_api_reachable "failsafe-${device_mac}"
}

_nvs_update_via_failsafe_api() {
  # Call update_nvs_secrets on failsafe-<mac>.local. Returns 0 on success.
  local device_mac="$1"
  local json_vars="$2"
  local failsafe_host="failsafe-${device_mac}"

  if ! _failsafe_api_reachable "$device_mac"; then
    return 1
  fi
  info "Updating NVS via ${failsafe_host}.local (update_nvs_secrets API)..."
  _call_failsafe_api_service "$device_mac" update_nvs_secrets "$json_vars"
}

_provision_device_nvs() {
  # Write device NVS: API first, USB only when network path is unavailable.
  local tty_device="${1:-}"
  local device_mac="$2"
  local production_role="${3:-}"
  local json_vars

  json_vars=$(_nvs_secrets_api_json_payload "$device_mac" "$production_role") || return 1

  if _nvs_update_via_failsafe_api "$device_mac" "$json_vars"; then
    ok "NVS updated via failsafe API (device rebooting)"
    sleep 5
    _wait_for_device "failsafe-${device_mac}" 60 || true
    return 0
  fi

  if [[ -z "$tty_device" ]]; then
    debug "NVS API update failed and no USB device provided"
    return 1
  fi

  warn "Failsafe API unavailable -- writing NVS via USB on ${tty_device} (required on first provision)"
  _flash_write_nvs_secrets_usb "$tty_device" "$device_mac" "$production_role"
}

_failsafe_update_nvs_matrix_layout() {
  # Partial update: matrix_cols / matrix_panel_w / matrix_panel_h only.
  local device_mac="$1"
  local cols="$2"
  local w="$3"
  local h="$4"
  local json_vars

  json_vars=$(
    MATRIX_COLS="$cols" MATRIX_PANEL_W="$w" MATRIX_PANEL_H="$h" python3 - <<'PY'
import json, os
print(json.dumps({
    "wifi_ssid": "",
    "wifi_password": "",
    "ota_password": "",
    "api_key": "",
    "thread_tlv": "",
    "matrix_cols": os.environ["MATRIX_COLS"],
    "matrix_panel_w": os.environ["MATRIX_PANEL_W"],
    "matrix_panel_h": os.environ["MATRIX_PANEL_H"],
    "device_role": "",
}))
PY
  ) || return 1

  _nvs_update_via_failsafe_api "$device_mac" "$json_vars"
}

_flash_write_nvs_secrets_usb() {
  local tty_device="$1"
  local device_mac="$2"
  local production_role="${3:-}"

  info "Writing device-specific secrets to NVS via USB..."
  if create_log_child_output_piped; then
    create_log_run "write-nvs-secrets" "$SCRIPT_DIR/scripts/write-nvs-secrets.sh" \
      "$tty_device" "$device_mac" "$production_role" \
      || err "Failed to write NVS secrets to device"
  else
    "$SCRIPT_DIR/scripts/write-nvs-secrets.sh" "$tty_device" "$device_mac" "$production_role" \
      || err "Failed to write NVS secrets to device"
  fi
  ok "NVS secrets written successfully via USB"
}

# Back-compat alias
_flash_write_nvs_secrets() {
  _flash_write_nvs_secrets_usb "$@"
}

_flash_store_matrix_layout_pass() {
  local role="$1"
  local cols="$2"
  local w="$3"
  local h="$4"

  [[ "${MATRIX_COLS_EXPLICIT:-0}" == "1" ]] && \
    printf '%s' "$cols" | pass insert -f "iotstack/roles/${role}/matrix_cols" 2>/dev/null || true
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
  local want_cols want_w want_h cur_cols cur_w cur_h

  _flash_matrix_layout_applicable "$device" "" || return 0
  _flash_resolve_matrix_layout "$device" want_cols want_w want_h

  if _flash_read_matrix_layout_from_device "$prod_hostname" "$device_mac" "$device" \
      cur_cols cur_w cur_h; then
    [[ "$cur_cols" == "$want_cols" && "$cur_w" == "$want_w" && "$cur_h" == "$want_h" ]] && return 0
    return 1
  fi

  # Runtime sensors unavailable -- only update when layout flags were passed explicitly.
  if _flash_matrix_layout_flags_set; then
    return 1
  fi
  return 0
}

_flash_matrix_layout_update_via_failsafe_if_needed() {
  # Query production API sensors; on mismatch, switch to failsafe and update NVS
  # via update_nvs_secrets API (USB esptool write is fallback only).
  # Returns 0 if unchanged, 2 if NVS was updated, 1 on failure.
  local device="$1"
  local tty_device="$2"
  local device_mac="$3"
  local prod_hostname="$4"
  local want_cols want_w want_h cur_cols cur_w cur_h verify_cols verify_w verify_h

  # mismatch returns 0 when layouts already match; 1 when NVS update is needed.
  if ! _flash_matrix_layout_mismatch "$device" "$device_mac" "$prod_hostname"; then
    return 0
  fi
  _flash_resolve_matrix_layout "$device" want_cols want_w want_h

  if _flash_read_matrix_layout_from_device "$prod_hostname" "$device_mac" "$device" \
      cur_cols cur_w cur_h; then
    info "Matrix layout mismatch: runtime ${cur_cols} panel(s) ${cur_w}x${cur_h} px -> target ${want_cols} panel(s) ${want_w}x${want_h} px"
  else
    info "Matrix layout: writing target ${want_cols} panel(s), ${want_w}x${want_h} px to NVS"
  fi

  info "Step 1: Switching ${prod_hostname} to failsafe for NVS update..."
  if ! _ensure_device_on_failsafe "$device_mac" false "$tty_device"; then
    if [[ -n "$tty_device" ]]; then
      warn "Network switch to failsafe failed -- refreshing failsafe firmware on ${tty_device}..."
      local _mac_file
      _mac_file=$(mktemp)
      _flash_failsafe_to_tty "$tty_device" "$_mac_file" "$device" \
        || { rm -f "$_mac_file"; return 1; }
      rm -f "$_mac_file"
      if ! _wait_for_device "failsafe-${device_mac}" 90; then
        warn "failsafe-${device_mac} did not appear after serial refresh"
        return 1
      fi
    else
      return 1
    fi
  fi

  info "Step 2: Updating matrix layout in NVS..."
  if _failsafe_update_nvs_matrix_layout "$device_mac" "$want_cols" "$want_w" "$want_h"; then
    ok "Matrix layout NVS updated via failsafe API (device rebooting)"
    sleep 5
    _wait_for_device "failsafe-${device_mac}" 60 || true
  elif [[ -n "$tty_device" ]]; then
    warn "Failsafe API unavailable -- writing matrix layout NVS via USB on ${tty_device}"
    export MATRIX_COLS="$want_cols" MATRIX_PANEL_W="$want_w" MATRIX_PANEL_H="$want_h"
    _flash_write_nvs_secrets_usb "$tty_device" "$device_mac" "$device"
  else
    err "Failsafe API NVS update failed and no USB device was provided"
    return 1
  fi
  _flash_store_matrix_layout_pass "$device" "$want_cols" "$want_w" "$want_h"

  info "Step 3: Booting production firmware with updated NVS..."
  if ! _boot_partition_network production "$device_mac"; then
    warn "Could not toggle boot partition via network -- try: iotstack set-boot ${device_mac} production"
  fi

  if _wait_for_production_online "$prod_hostname" 90; then
    if _flash_read_matrix_layout_from_device "$prod_hostname" "$device_mac" "$device" \
        verify_cols verify_w verify_h \
        && [[ "$verify_cols" == "$want_cols" && "$verify_w" == "$want_w" && "$verify_h" == "$want_h" ]]; then
      ok "Matrix layout verified via API: ${verify_cols} panel(s), ${verify_w}x${verify_h} px"
    else
      ok "Production firmware online -- matrix layout NVS written (re-query sensors if needed)"
    fi
  else
    warn "Production ${prod_hostname} did not reappear within 90s -- NVS was written on failsafe"
  fi
  return 2
}

cmd_flash() {
  _iotstack_command_help_if_requested flash "$@" && return 0

  local device="" tty_device_or_role="" skip_recovery=""
  export FLASH_ANYWAY=0
  export FLASH_ON_FLASH_VERIFY=0
  export MATRIX_COLS=""
  export MATRIX_PANEL_W=""
  export MATRIX_PANEL_H=""
  export MATRIX_COLS_EXPLICIT=0
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
      --flash-anyway)
        export FLASH_ANYWAY=1
        shift
        ;;
      --panel-count=*)
        MATRIX_COLS="${1#*=}"
        MATRIX_COLS_EXPLICIT=1
        shift
        ;;
      --panel-count)
        [[ $# -lt 2 ]] && err "Missing value for --panel-count"
        MATRIX_COLS="$2"
        MATRIX_COLS_EXPLICIT=1
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
        elif [[ -z "$tty_device_or_role" ]]; then
          tty_device_or_role="$1"
        else
          err "Unexpected flash argument: $1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$device" ]]; then
    help_flash
    exit 1
  fi

  if [[ -n "$MATRIX_COLS$MATRIX_PANEL_W$MATRIX_PANEL_H" ]]; then
    if ! _flash_matrix_layout_applicable "$device" "$tty_device_or_role"; then
      warn "Matrix layout options (--panel-count, --matrix-panel-width, --matrix-panel-height) apply only to matrixdisplay; ignoring"
      MATRIX_COLS=""
      MATRIX_PANEL_W=""
      MATRIX_PANEL_H=""
    fi
  fi

  # Special handling for "failsafe" role
  if [[ "$device" == "failsafe" ]]; then
    # Check if second arg is a production role (dual-flash mode)
    if [[ -n "$tty_device_or_role" && ! "$tty_device_or_role" =~ ^/dev/ ]]; then
      # Dual-flash: failsafe + production role
      local production_role="$tty_device_or_role"
      _flash_recovery_dual "$production_role"
    else
      # Single flash: failsafe only
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

  # For production roles: smart dual-partition setup
  # If device is fresh (no recovery): flash recovery first, then production
  # If device exists (has recovery): just flash production via OTA
  _flash_production_smart "$device" "$tty_device_or_role" "$skip_recovery"
}

_wait_for_serial_signal() {
  # Stream serial output until "wifi cleared Warning flag" is seen or timeout.
  # The device is live on the console the whole time; OTA can start the moment
  # WiFi clears rather than waiting a fixed sleep.
  # Usage: _wait_for_serial_signal <tty> [timeout_seconds]
  # Returns 0 when signal found, non-0 on timeout.
  local tty="$1"
  local timeout_s="${2:-90}"
  local py
  py=$(head -1 "$(command -v esphome)" 2>/dev/null | sed 's/^#!//')
  [[ -x "$py" ]] || py="python3"

  local serial_source
  serial_source=$(create_log_serial_source "$tty")

  if create_log_child_output_piped; then
    timeout "$timeout_s" "$py" -u "${SCRIPT_DIR}/scripts/serial-logs.py" \
      --reconnect --stop-on "wifi cleared Warning flag" "$tty" \
      | create_log_tee_console "$serial_source"
    return "${PIPESTATUS[0]}"
  fi

  timeout "$timeout_s" "$py" "${SCRIPT_DIR}/scripts/serial-logs.py" \
    --reconnect --stop-on "wifi cleared Warning flag" "$tty"
}

_flash_failsafe_esptool() {
  # Write failsafe binaries; erase first only when requested. Sets esptool_output.
  # Requires: IOTSTACK_ESPTOOL_CHIP, IOTSTACK_FAILSAFE_FLASH_SIZE, build_dir, failsafe_offset
  # Usage: _flash_failsafe_esptool <tty> <flash_log> <build_dir> <failsafe_offset> [erase:0|1]
  local tty_device="$1"
  local flash_log="$2"
  local build_dir="$3"
  local failsafe_offset="$4"
  local erase_flash="${5:-1}"
  local esptool_chip="${IOTSTACK_ESPTOOL_CHIP:-esp32c6}"
  local flash_label="${IOTSTACK_FAILSAFE_FLASH_SIZE:-4MB}"
  local esptool_baud
  esptool_baud=$(esp_esptool_baud_for_chip "$esptool_chip")

  local esptool_src="esptool:${esptool_chip}"

  if [[ "$erase_flash" == "1" ]]; then
    info "Erasing flash memory (${esptool_chip}, ${flash_label})..."
    create_log_run_esptool "$esptool_src" "$flash_log" \
      --chip "$esptool_chip" --port "$tty_device" --baud "$esptool_baud" --before default-reset erase-flash \
      || err "Erase failed"
    sleep 3
  else
    warn "Skipping flash erase (not required for this update)"
  fi

  info "Flashing failsafe firmware (${esptool_chip})..."
  if [[ $VERBOSE -eq 1 ]] && ! create_log_enabled; then
    info "Detailed output: tail -f $flash_log"
  fi

  create_log_run_esptool "$esptool_src" "$flash_log" \
    --chip "$esptool_chip" --port "$tty_device" --baud "$esptool_baud" --before default-reset \
    write-flash --flash-mode dio --flash-size "$flash_label" --flash-freq 40m \
    0x0 "$build_dir/bootloader.bin" \
    0x8000 "$build_dir/partitions.bin" \
    "$failsafe_offset" "$build_dir/firmware.bin" \
    || err "Flash failed"
  esptool_output="$create_log_esptool_output"
}

_ensure_failsafe_build_for_assess() {
  # Ensure failsafe is compiled (shared external_components + partition table for production).
  # On-flash MD5 read during assessment requires --on-flash-verify.
  local tty_device="$1"
  local production_role="$2"
  local profile variant board flash_size framework failsafe_yaml

  profile=$(failsafe_resolve_profile "$tty_device" "$production_role") || return 1
  failsafe_apply_profile_to_env "$profile"
  variant=$(echo "$profile" | cut -d'|' -f1)
  board=$(echo "$profile" | cut -d'|' -f2)
  flash_size=$(echo "$profile" | cut -d'|' -f3)
  framework=$(echo "$profile" | cut -d'|' -f4)
  failsafe_yaml="${YAMLS_DIR}/.iotstack-failsafe-${variant}.yaml"
  failsafe_render_yaml "$variant" "$board" "$flash_size" "$framework" >/dev/null || return 1
  iotstack_register_yaml_cleanup_trap
  smart_compile "$failsafe_yaml" failsafe
}

_flash_failsafe_to_tty() {
  # Compile variant-specific failsafe, flash, write NVS, wait for WiFi.
  # Returns MAC suffix via stdout or mac_return_file.
  local tty_device="$1"
  local mac_return_file="${2:-}"
  local production_role="${3:-}"
  local failsafe_yaml build_name profile variant board flash_size framework

  profile=$(failsafe_resolve_profile "$tty_device" "$production_role") || return 1
  failsafe_apply_profile_to_env "$profile"
  variant=$(echo "$profile" | cut -d'|' -f1)
  board=$(echo "$profile" | cut -d'|' -f2)
  flash_size=$(echo "$profile" | cut -d'|' -f3)
  framework=$(echo "$profile" | cut -d'|' -f4)
  failsafe_yaml="${YAMLS_DIR}/.iotstack-failsafe-${variant}.yaml"
  failsafe_render_yaml "$variant" "$board" "$flash_size" "$framework" >/dev/null || return 1
  iotstack_register_yaml_cleanup_trap
  build_name="failsafe"

  _check_serial_port_in_use "$tty_device"

  if [[ $CLEAN_BUILD_DIRECTORY -eq 1 ]]; then
    info "Cleaning build directory (CLEAN_BUILD_DIRECTORY=1)..."
    rm -rf "$ESPHOME_BUILD_DIR"
    ok "Build directory cleaned"
  fi

  info "Failsafe target: ${variant} on ${tty_device}"
  info "Artifact: ${failsafe_yaml}"
  smart_compile "$failsafe_yaml" "$build_name" || return 1

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

  local failsafe_offset
  failsafe_offset=$(flash_partition_offset failsafe 2>/dev/null) || true
  [[ -z "$failsafe_offset" ]] && err "Could not resolve failsafe partition offset (build failsafe/partitions.csv or ${PARTITION_TABLE})"

  local esptool_chip="${IOTSTACK_ESPTOOL_CHIP:-$variant}"
  flash_assess_failsafe_device "$tty_device" "$esptool_chip" "$build_dir" "$failsafe_offset"

  local esptool_output device_mac skip_serial="$FLASH_ASSESS_SKIP_SERIAL"
  if [[ "$skip_serial" -eq 1 ]]; then
    info "Failsafe image on device matches build -- serial upload not required"
    debug "On-device partition table also matches compiled build"
    esptool_output=$(esp_esptool_chip_id "$tty_device") || err "Could not read chip ID from $tty_device"
    device_mac=$(esp_mac_from_esptool_output "$esptool_output")
    [[ -z "$device_mac" || ! "$device_mac" =~ ^[0-9a-f]{6}$ ]] && err "Failed to extract MAC address from device"
    ok "Device MAC: $device_mac"
  else
    if [[ "$FLASH_ASSESS_FAILSAFE_MATCH" -eq 0 ]]; then
      info "Failsafe image on device differs from build -- serial upload required"
    elif [[ "$FLASH_ASSESS_PARTITION_MATCH" -eq 0 ]]; then
      info "On-device partition table differs from build -- serial upload required"
    fi
    _flash_failsafe_esptool "$tty_device" "$flash_log" "$build_dir" "$failsafe_offset" "$FLASH_ASSESS_NEED_ERASE"
    esptool_output="$create_log_esptool_output"
    device_mac=$(esp_mac_from_esptool_output "$esptool_output")
    [[ -z "$device_mac" || ! "$device_mac" =~ ^[0-9a-f]{6}$ ]] && err "Failed to extract MAC address from device"
    ok "Failsafe firmware (${variant}) flashed to: $device_mac"

    info "Waiting for device to boot..."
    sleep 5

    _provision_device_nvs "$tty_device" "$device_mac" "$production_role" || \
      err "Failed to provision device NVS"
    sleep 2

    info "Waiting for device to connect to WiFi..."
    if _wait_for_serial_signal "$tty_device" 90; then
      ok "Device connected to WiFi"
      create_log_enabled && ok "Serial output recorded in session log"
    else
      warn "WiFi wait timed out (90s); proceeding"
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
  # production_role is passed to write-nvs-secrets.sh so both failsafe- and
  # production-derived secrets are written to NVS in a single flash.
  local tty_device="$1"
  local mac_return_file="${2:-}"
  local production_role="${3:-}"

  info "Flashing failsafe firmware (dual-partition setup)"
  echo ""

  if [[ ! -f "$FAILSAFE_TEMPLATE" && ! -f "${YAMLS_DIR}/failsafe.yaml" ]]; then
    err "Failsafe template not found: ${YAMLS_DIR}/failsafe.yaml"
  fi

  if [[ -n "$tty_device" ]]; then
    if [[ ! -e "$tty_device" ]]; then
      err "TTY device not found: $tty_device"
    fi
    info "Flashing to: $tty_device"
    _flash_failsafe_to_tty "$tty_device" "$mac_return_file" "$production_role"
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

  local failed=0
  local successful_ttys=()
  for tty in "${targets[@]}"; do
    echo ""
    info "Flashing $tty..."
    echo "========================================================"
    if _flash_failsafe_to_tty "$tty" "" "$production_role"; then
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

  ok "Failsafe firmware flashed to ${#targets[@]} device(s)"
  if [[ ${#successful_ttys[@]} -eq 1 ]]; then
    echo ""
    info "Waiting for device to connect to WiFi..."
    if _wait_for_serial_signal "${successful_ttys[0]}" 60; then
      ok "Device connected to WiFi"
    else
      warn "WiFi wait timed out (60s); proceeding"
    fi
  elif [[ ${#successful_ttys[@]} -gt 1 ]]; then
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

  # Second: Discover recovery devices and reassign to production role
  info "Step 2: Reassigning devices to $production_role firmware via OTA..."
  echo ""

  # Discover recovery devices (failsafe advertises _iotstack-failsafe._tcp)
  local recovery_macs=()
  while IFS= read -r line; do
    if [[ "$line" =~ failsafe-([0-9a-f]+) ]]; then
      recovery_macs+=("${BASH_REMATCH[1]}")
    fi
  done < <(avahi-browse -t -r _iotstack-failsafe._tcp 2>/dev/null)

  if [[ ${#recovery_macs[@]} -eq 0 ]]; then
    err "No recovery devices found on network. Check WiFi connection."
  fi

  # Resolve role to YAML
  local yaml_file
  yaml_file=$(resolve_device "$production_role" false) || err "Unknown role: $production_role"

  # Use well-known recovery password for reassign
  local ota_password="IotstackRecovery2024"

  info "Flashing ${#recovery_macs[@]} device(s) to $production_role..."
  declare -a _recovery_ota_args=()
  mapfile -t _recovery_inherited < <(_update_devices_inherited_flags)
  [[ ${#_recovery_inherited[@]} -gt 0 ]] && _recovery_ota_args+=("${_recovery_inherited[@]}")
  _recovery_ota_args+=(--upgrade-delta --reassign "${recovery_macs[@]}" "$yaml_file" --ota-password "$ota_password" --jobs 1)
  _run_update_devices "${_recovery_ota_args[@]}" || err "OTA update failed"

  # Third: Toggle boot partition to production and reboot devices
  info "Toggling boot partition to production firmware..."
  echo ""

  # Discover recovery devices and toggle them (failsafe advertises _iotstack-failsafe._tcp)
  local recovery_devices=()
  while IFS= read -r line; do
    if [[ "$line" =~ failsafe-([0-9a-f]+) ]]; then
      recovery_devices+=("${BASH_REMATCH[1]}")
    fi
  done < <(avahi-browse -t -r _iotstack-failsafe._tcp 2>/dev/null)

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
        local device_name="failsafe-$mac"
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
        local device_name="failsafe-$mac"
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
  # Smart production firmware flash: detect if device is fresh (needs recovery)
  # If fresh: flash recovery first, then production via OTA
  # If exists: skip recovery, just OTA flash production
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

    info "Flash target: ${device} production firmware on ${tty_device}"

    # Check if user wants to skip recovery
    local device_mac="" prod_hostname=""
    if [[ "$skip_recovery" != "--ota-only" ]]; then
      device_mac=$(esp_mac_suffix_from_port "$tty_device" 2>/dev/null) || device_mac=""
      if [[ -n "$device_mac" ]]; then
        prod_hostname="${device}-${device_mac}"
        info "Assessing connected device on ${tty_device}..."
        _ensure_failsafe_build_for_assess "$tty_device" "$device" \
          || warn "Could not prepare failsafe build -- partition table may be stale"
        _flash_assess_device_runtime "$device_mac" "$prod_hostname" "$tty_device"
        smart_compile "$yaml_path" "$device" || err "Production compile failed"
        _flash_assess_device_on_flash_action "$tty_device" "$yaml_path" "$device_mac" "$prod_hostname"

        if [[ $FLASH_ASSESS_FLASH_CURRENT -eq 1 && $FLASH_ASSESS_PROD_ONLINE -eq 1 && "${FLASH_ANYWAY:-0}" != "1" ]]; then
          local img_hash layout_rc=0 want_cols want_w want_h
          set +e
          _flash_matrix_layout_update_via_failsafe_if_needed "$device" "$tty_device" "$device_mac" "$prod_hostname"
          layout_rc=$?
          set -e
          if [[ $layout_rc -eq 1 ]]; then
            err "Matrix layout NVS update failed"
          fi
          _flash_resolve_matrix_layout "$device" want_cols want_w want_h
          img_hash=$(_production_running_image_hash "$prod_hostname" "$tty_device" "$yaml_path")
          if [[ $layout_rc -eq 2 ]]; then
            ok "Matrix layout updated on ${prod_hostname}: ${want_cols} panel(s), ${want_w}x${want_h} px (config_hash ${img_hash})"
          else
            ok "Device ${prod_hostname} already running current ${device} firmware (config_hash ${img_hash})"
          fi
          _ha_after_production_online "$yaml_path" "$prod_hostname"
          ok "Production firmware setup complete!"
          return
        fi

        local try_network_ota=false
        if _production_api_reachable "$prod_hostname"; then
          try_network_ota=true
        elif _wait_for_production_online "$prod_hostname" 15 && _production_api_reachable "$prod_hostname"; then
          try_network_ota=true
        fi

        if [[ "$try_network_ota" == true ]]; then
          if [[ $FLASH_ASSESS_FLASH_CURRENT -eq 1 && "${FLASH_ANYWAY:-0}" != "1" ]]; then
            local layout_rc=0 want_cols want_w want_h
            set +e
            _flash_matrix_layout_update_via_failsafe_if_needed "$device" "$tty_device" "$device_mac" "$prod_hostname"
            layout_rc=$?
            set -e
            if [[ $layout_rc -eq 1 ]]; then
              err "Matrix layout NVS update failed"
            fi
            if [[ $layout_rc -eq 2 ]]; then
              _flash_resolve_matrix_layout "$device" want_cols want_w want_h
              ok "Matrix layout updated on ${prod_hostname}: ${want_cols} panel(s), ${want_w}x${want_h} px"
            else
              ok "Production firmware on flash matches build -- nothing to do"
            fi
            _ha_after_production_online "$yaml_path" "$prod_hostname"
            ok "Production firmware setup complete!"
            return
          fi
          if _flash_production_ota_update "$device_mac" "$yaml_path" "$device" "$tty_device"; then
            ok "Production firmware setup complete!"
            return
          fi
          warn "Production OTA via network failed -- trying serial failsafe path"
          info "Step 1: Refreshing failsafe-wifi firmware on ${tty_device}..."
          local _mac_file
          _mac_file=$(mktemp)
          _flash_failsafe_to_tty "$tty_device" "$_mac_file" "$device" \
            || err "Failsafe serial flash failed"
          if [[ -f "$_mac_file" ]]; then
            device_mac=$(tr -d '[:space:]' < "$_mac_file")
            rm -f "$_mac_file"
          fi
          info "Step 2: Reassigning failsafe device to ${device} production firmware..."
        elif [[ $FLASH_ASSESS_PROD_MDNS -eq 1 ]] || _production_mdns_advertised "$prod_hostname"; then
          warn "Production visible on mDNS but API unreachable -- using serial failsafe path"
          info "Step 1: Refreshing failsafe-wifi firmware on ${tty_device}..."
          local _mac_file
          _mac_file=$(mktemp)
          _flash_failsafe_to_tty "$tty_device" "$_mac_file" "$device" \
            || err "Failsafe serial flash failed"
          if [[ -f "$_mac_file" ]]; then
            device_mac=$(tr -d '[:space:]' < "$_mac_file")
            rm -f "$_mac_file"
          fi
          info "Step 2: Reassigning failsafe device to ${device} production firmware..."
        elif [[ $FLASH_ASSESS_FAILSAFE_ONLINE -eq 1 ]] || _failsafe_ota_reachable "$device_mac"; then
          info "Device is on failsafe firmware (failsafe-${device_mac} OTA is reachable)"
          local _mac_file
          _mac_file=$(mktemp)
          _flash_failsafe_to_tty "$tty_device" "$_mac_file" "$device" || rm -f "$_mac_file"
          if [[ -f "$_mac_file" ]]; then
            device_mac=$(tr -d '[:space:]' < "$_mac_file")
            rm -f "$_mac_file"
          fi
          info "Step 2: Reassigning failsafe device to ${device} production firmware..."
        else
          info "Device not on WiFi yet -- provisioning via failsafe serial path"
          info "Step 1: Flashing failsafe-wifi firmware..."
          local _mac_file
          _mac_file=$(mktemp)
          _flash_recovery "$tty_device" "$_mac_file" "$device"
          device_mac=$(tr -d '[:space:]' < "$_mac_file")
          rm -f "$_mac_file"
          info "Step 2: Waiting for device to appear on network..."
        fi
      else
        info "Could not read device MAC -- provisioning via failsafe serial path"
        info "Step 1: Flashing failsafe-wifi firmware..."
        echo ""
        local _mac_file
        _mac_file=$(mktemp)
        _flash_recovery "$tty_device" "$_mac_file" "$device"
        device_mac=$(tr -d '[:space:]' < "$_mac_file")
        rm -f "$_mac_file"
        echo ""
        info "Step 2: Waiting for device to appear on network..."
        echo ""
      fi
    else
      info "Skipping recovery (--ota-only flag)"
      echo ""
    fi

    # Reassign failsafe device to production
    if [[ -n "$device_mac" ]]; then
      device_mac=$(echo "$device_mac" | tr -d '[:space:]')
      local prod_hostname="${device}-${device_mac}"

      # Device may boot production while failsafe partition on flash is unchanged
      # (skip-serial path). Never wait for failsafe OTA in that case.
      if [[ $FLASH_ASSESS_PROD_ONLINE -eq 1 ]] || _wait_for_production_online "$prod_hostname" 10; then
        if [[ $FLASH_ASSESS_FLASH_CURRENT -eq 0 ]]; then
          _flash_report_device_assessment "$tty_device" "$yaml_path" "$device_mac" "$prod_hostname"
          echo ""
        fi
        if [[ $FLASH_ASSESS_FLASH_CURRENT -eq 1 ]]; then
          ok "Production firmware on flash matches build -- nothing to do"
          _ha_after_production_online "$yaml_path" "$prod_hostname"
          ok "Production firmware setup complete!"
          return
        fi
        _flash_production_ota_update "$device_mac" "$yaml_path" "$device" "$tty_device" \
          || err "Production OTA update failed"
        ok "Production firmware setup complete!"
        return
      fi

      if _failsafe_ota_reachable "$device_mac"; then
        ok "failsafe-$device_mac OTA service is up; starting production OTA..."
      else
        info "Waiting for failsafe-$device_mac OTA service to come online..."
        # The device is ready once its OTA service (port 3232) accepts a
        # connection. Probe the mDNS name directly: this confirms exactly what the
        # OTA needs and is far more reliable than polling 'avahi-browse -t' in a
        # tight loop (a fresh browse can terminate before the device replies, so
        # the device can be online yet never matched). Allow a generous window --
        # a fresh failsafe must flash, boot, apply WiFi creds from NVS, reconnect,
        # and announce over mDNS before this succeeds.
        local max_wait=180
        local waited=0
        local found=false

        while (( waited < max_wait )); do
          if timeout 3 bash -c "echo > /dev/tcp/failsafe-${device_mac}.local/3232" 2>/dev/null; then
            found=true
            break
          fi
          sleep 3
          waited=$((waited + 3))
          if (( waited % 15 == 0 )); then
            info "  Still waiting for failsafe-$device_mac OTA service ($waited/${max_wait}s)..."
          fi
        done

        if [[ "$found" != "true" ]]; then
          err "Failsafe device (failsafe-$device_mac) OTA service not reachable after ${max_wait}s.
The device is likely unable to connect to WiFi.
It will auto-reboot in ~3 minutes to retry WiFi. Once it connects, run:
  iotstack update $device
Or monitor it now: iotstack logs /dev/ttyACM0"
        fi

        ok "failsafe-$device_mac OTA service is up; starting production OTA..."
      fi

      # Resolve the failsafe device's IP now, before OTA changes the hostname.
      # After reboot the device gets the same DHCP lease, so we can probe the
      # OTA port on this IP directly -- no avahi cache invalidation needed.
      local device_ip=""
      device_ip=$(getent hosts "failsafe-${device_mac}.local" 2>/dev/null | awk '{print $1}' | head -1)
      if [[ -z "$device_ip" ]]; then
        device_ip=$(avahi-resolve -n "failsafe-${device_mac}.local" 2>/dev/null | awk '{print $2}' | head -1)
      fi
      [[ -n "$device_ip" ]] && debug "Resolved failsafe-$device_mac -> $device_ip (will probe after reboot)"

      # Wait for the OTA service to be fully ready. The /dev/tcp check above
      # confirmed the port is listening, but ESPHome needs a moment after the
      # socket opens to finish setup() before it can accept a connection.
      if [[ -n "$device_ip" ]] && command -v wait-for-it &>/dev/null; then
        wait-for-it "$device_ip:3232" -t 15 -q || true
        sleep 2
      fi

      local production_build_name production_build_dir production_offset skip_production_ota=0
      production_build_name=$(basename "$yaml_path" .yaml)
      info "Checking production firmware (${production_build_name})..."
      smart_compile "$yaml_path" "$production_build_name" || err "Production compile failed"
      production_build_dir="${YAMLS_DIR}/.esphome/build/${production_build_name}/.pioenvs/${production_build_name}"
      production_offset=$(awk -F',' '/^production[[:space:]]*,/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4); print $4}' "$PARTITION_TABLE" | head -1)

      if [[ "${FLASH_ON_FLASH_VERIFY:-0}" == "1" && -n "$production_offset" && -d "$production_build_dir" ]]; then
        local prod_chip="${IOTSTACK_ESPTOOL_CHIP:-}"
        [[ -z "$prod_chip" ]] && prod_chip=$(esp_detect_chip "$tty_device" 2>/dev/null) || true
        info "  Reading on-flash production partition via USB..."
        if [[ -n "$prod_chip" ]] && flash_production_matches_device \
            "$tty_device" "$prod_chip" "$production_build_dir" "$production_offset"; then
          ok "Production partition matches build -- skipping OTA"
          skip_production_ota=1
        fi
      elif _flash_production_matches_build "$prod_hostname" "$yaml_path" "$tty_device"; then
        ok "Production firmware matches build (runtime config_hash) -- skipping OTA"
        skip_production_ota=1
      fi

      if [[ "$skip_production_ota" -eq 1 ]]; then
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

      info "Reassigning failsafe-$device_mac to $device firmware..."

      # Retrieve failsafe role-based OTA password from pass store. The failsafe
      # device authenticates OTA with its device-specific password derived from
      # this role secret + MAC (the same value written to its NVS at flash time).
      local failsafe_role_password
      failsafe_role_password=$(pass show "iotstack/roles/failsafe/ota_password" 2>/dev/null)
      if [[ -z "$failsafe_role_password" ]]; then
        info "Failsafe role OTA password not found, generating..."
        failsafe_role_password=$(openssl rand -hex 16)
        # Store it in pass
        { echo "$failsafe_role_password"; echo "$failsafe_role_password"; } | \
          pass insert -f "iotstack/roles/failsafe/ota_password" 2>/dev/null || \
          err "Failed to store failsafe OTA password in pass"
        ok "Failsafe OTA password generated and stored"
      fi

      # Compute device-specific OTA password from role secret + MAC
      # sha256(role_secret | device_mac) - computed in-memory only
      local device_ota_password
      device_ota_password=$(echo -n "${failsafe_role_password}|${device_mac}" | sha256sum | cut -c1-32)

      declare -a _flash_ota_args=()
      mapfile -t _flash_inherited < <(_update_devices_inherited_flags)
      [[ ${#_flash_inherited[@]} -gt 0 ]] && _flash_ota_args+=("${_flash_inherited[@]}")
      _flash_ota_args+=(--upgrade-delta --reassign "$device_mac" "$yaml_path" --ota-password "$device_ota_password" --jobs 1)
      if ! _run_update_devices "${_flash_ota_args[@]}"; then
        err "OTA update failed. Device may still be booting. Try again in a moment:
  iotstack update $device"
      fi

      # Detect the production firmware's network type so we know how to wait.
      local network_type
      network_type=$(get_yaml_device_info "$yaml_path" | cut -d'|' -f3)

      if [[ "$network_type" == "thread" ]]; then
        # Thread production firmware joins the Thread mesh (not WiFi).
        # It won't appear in 'iotstack devices' (avahi/WiFi mDNS only).
        info "OTA update complete! Thread device rebooting into $device firmware..."
        info "(Thread devices communicate over the Thread mesh, not WiFi)"
        info "Verify with: iotstack logs /dev/ttyACM0  or check your Thread Border Router"
      else
        info "OTA update complete! Waiting for device to reboot..."
        if _wait_for_production_online "$prod_hostname" 90; then
          ok "Device online as $prod_hostname"
          _ha_after_production_online "$yaml_path" "$prod_hostname"
        else
          warn "Device did not come online after 90s."
          warn "It may still be booting. Check with: iotstack devices"
        fi
      fi
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
    info "Streaming serial logs from $port (Ctrl-C to stop)..."
    local py serial_source
    py=$(head -1 "$(command -v esphome)" 2>/dev/null | sed 's/^#!//')
    [[ -x "$py" ]] || py="python3"
    if create_log_child_output_piped; then
      serial_source=$(create_log_serial_source "$port")
      "$py" -u "${SCRIPT_DIR}/scripts/serial-logs.py" "$port" \
        | create_log_tee_console "$serial_source"
      exit "${PIPESTATUS[0]}"
    fi
    exec "$py" "${SCRIPT_DIR}/scripts/serial-logs.py" "$port"
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

cmd_clean() {
  # Clean build artifacts and compilation caches
  info "Cleaning build artifacts..."

  # List of directories/files to clean
  local items_to_clean=(
    "${YAMLS_DIR}/.esphome/build"
    "${HOME}/.esphome/storage"
    "${HOME}/.esphome/idedata"
    "${HOME}/.platformio/.cache"
    "${COMPILATION_CACHE}"
    "${LOGS_DIR}"
  )

  local cleaned_count=0 artifact name size

  for item in "${items_to_clean[@]}"; do
    if [[ -e "$item" ]]; then
      if [[ -d "$item" ]]; then
        local size
        size=$(du -sh "$item" 2>/dev/null | awk '{print $1}' || echo "unknown")
        info "Removing directory: $item ($size)"
        rm -rf "$item"
      else
        info "Removing file: $item"
        rm -f "$item"
      fi
      ((cleaned_count++))
    fi
  done

  # Clean temp artifact files (keep partition table so failsafe pass 2 can be skipped)
  if [[ -d "${ARTIFACTS_DIR}" ]]; then
    info "Removing temporary artifact files (keeping $(basename "$PARTITION_TABLE"))..."
    for artifact in "${ARTIFACTS_DIR}"/*; do
      [[ -e "$artifact" ]] || continue
      name=$(basename "$artifact")
      [[ "$name" == "$(basename "$PARTITION_TABLE")" ]] && continue
      if [[ -d "$artifact" ]]; then
        size=$(du -sh "$artifact" 2>/dev/null | awk '{print $1}' || echo "unknown")
        info "Removing directory: $artifact ($size)"
        rm -rf "$artifact"
      else
        info "Removing file: $artifact"
        rm -f "$artifact"
      fi
      ((cleaned_count++))
    done
  fi

  ok "Clean complete. Removed $cleaned_count item(s)"
  ok "Ready for next compilation"
}

help_clean() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-clean.txt"
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
  iotstack_parse_global_argv "$@"
  set -- "${IOTSTACK_ARGV[@]}"

  local command="${1:-help}"
  create_log_setup "$command"
  if create_log_enabled; then
    info "Session log: ${IOTSTACK_LOG_FILE}"
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
    failsafe)
      shift
      cmd_list failsafe "$@"
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
          failsafe)         help_failsafe ;;
          roles)            help_roles ;;
          flash)            help_flash ;;
          logs)             help_logs ;;
          set-boot)         cmd_set_boot help ;;
          matter)           help_matter "${3:-}" ;;
          otbr)             help_otbr ;;
          commission)       help_commission ;;
          clean)            help_clean ;;
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
