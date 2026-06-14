#!/bin/bash
# iotstack.sh — CLI tool for managing IoT Stack ESPHome devices
# Wrapper around update_devices.sh with a cleaner interface
#
# Each invocation runs in an isolated git worktree to prevent code changes
# from affecting running commands.

set -euo pipefail

# Global configuration
VERBOSE=0
QUIET=0
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

# ── Compilation Cache ────────────────────────────────────────────────────────

_get_yaml_sha() {
  # Get SHA256 of YAML file plus all external_components
  # This ensures cache invalidation when any component changes
  local yaml_file="$1"

  if [[ ! -f "$yaml_file" ]]; then
    echo ""
    return
  fi

  # Start with YAML file hash
  local combined_hash
  combined_hash=$(sha256sum "$yaml_file" | awk '{print $1}')

  # Include external_components directory hash if it exists
  local external_components_dir="${YAMLS_DIR}/external_components"
  if [[ -d "$external_components_dir" ]]; then
    # Find all files in external_components and hash them
    # Sort by filename to ensure consistent ordering
    local components_hash
    components_hash=$(find "$external_components_dir" -type f | sort | xargs cat | sha256sum | awk '{print $1}')

    # Combine both hashes
    combined_hash=$(echo -n "${combined_hash}${components_hash}" | sha256sum | awk '{print $1}')
  fi

  echo "$combined_hash"
}

_get_binary_sha() {
  # Get SHA256 of compiled firmware binary
  local device_name="$1"
  local build_dir="${YAMLS_DIR}/.esphome/build/${device_name}/.pioenvs/${device_name}/firmware.bin"
  [[ -f "$build_dir" ]] && sha256sum "$build_dir" | awk '{print $1}' || echo ""
}

_check_compilation_cache() {
  # Check if we can skip compilation based on YAML SHA
  # Returns 0 (can skip) or 1 (must compile)
  local yaml_file="$1"
  local yaml_name
  yaml_name=$(basename "$yaml_file")
  local yaml_sha
  yaml_sha=$(_get_yaml_sha "$yaml_file")

  [[ ! -f "$COMPILATION_CACHE" ]] && return 1

  # Look for matching YAML name and SHA in cache (skip header row)
  tail -n +2 "$COMPILATION_CACHE" | grep "^${yaml_name},${yaml_sha}," >/dev/null 2>&1
  return $?
}

_update_compilation_cache() {
  # Record compilation result in cache
  local yaml_file="$1"
  local binary_sha="$2"
  local yaml_name
  yaml_name=$(basename "$yaml_file")
  local yaml_sha
  yaml_sha=$(_get_yaml_sha "$yaml_file")

  # Add header if file doesn't exist
  if [[ ! -f "$COMPILATION_CACHE" ]]; then
    echo "yaml_name,yaml_sha,binary_sha" > "$COMPILATION_CACHE"
  fi

  # Check if this yaml_sha already exists in cache
  if tail -n +2 "$COMPILATION_CACHE" | grep -q "^${yaml_name},${yaml_sha},"; then
    # Entry already exists - don't add a duplicate
    return 0
  fi

  # Append new entry only if it doesn't already exist
  echo "${yaml_name},${yaml_sha},${binary_sha}" >> "$COMPILATION_CACHE"
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

_generate_initial_partition_table() {
  # Generate initial partition table with safe defaults before compilation
  # Uses 1.5MB for recovery/production (fits in 4MB with overhead)
  # Will be recalculated after compilation to exact sizes

  local output_file="${1:-${YAMLS_DIR}/iotstack_partition_table.csv}"

  debug "Generating initial partition table: $output_file"

  cat > "$output_file" << 'EOF'
# ESP32-C6 Partition Table for Dual App OTA Recovery
# Initial defaults - will be recalculated after compilation
# Bootloader: 0x0-0x8000 (32KB)
# NVS: 0x9000 (16KB, fixed)
# OTA Data: 0xd000 (8KB, fixed)
# Recovery: ota_0 at 0x30000 (will be calculated)
# Production: ota_1 (will be calculated)
# Name,     Type,  SubType,    Offset,      Size,
nvs,        data,  nvs,        0x9000,      0x4000,
otadata,    data,  ota,        0xd000,      0x2000,
recovery,   app,   ota_0,      0x30000,     0x180000,
production, app,   ota_1,      0x1b0000,    0x180000,
EOF
}

_calculate_partition_sizes() {
  # Calculate partition sizes and offsets based on compiled firmware size
  # Called after successful compilation to determine actual partition table
  #
  # Arguments:
  #   $1 = device name (e.g., "recovery", "bleproxy")
  #   $2 = yaml file (e.g., yamls/failsafe.yaml)
  #
  # Sets global variables:
  #   RECOVERY_SIZE, PRODUCTION_SIZE, PRODUCTION_OFFSET

  local device_name="$1"
  local yaml_file="$2"

  # Get compiled firmware binary size
  local firmware_bin="${YAMLS_DIR}/.esphome/build/${device_name}/.pioenvs/${device_name}/firmware.bin"

  if [[ ! -f "$firmware_bin" ]]; then
    err "Compiled firmware not found: $firmware_bin"
  fi

  local firmware_size
  firmware_size=$(stat -f%z "$firmware_bin" 2>/dev/null || stat -c%s "$firmware_bin" 2>/dev/null || echo 0)

  if [[ $firmware_size -eq 0 ]]; then
    err "Could not determine firmware size: $firmware_bin"
  fi

  # Calculate failsafe partition size: firmware_size rounded up to nearest 4KB boundary
  # No safety margin - partition is exactly what firmware needs
  local recovery_size_calc=$firmware_size

  # Round up to nearest 4KB (0x1000 = 4096 bytes) for flash sector alignment
  local remainder=$((recovery_size_calc % 0x1000))
  if [[ $remainder -ne 0 ]]; then
    recovery_size_calc=$(((recovery_size_calc / 0x1000 + 1) * 0x1000))
  fi

  # Convert to hex
  local RECOVERY_SIZE_HEX
  RECOVERY_SIZE_HEX=$(printf '0x%x' "$recovery_size_calc")

  # Production size matches recovery for symmetry (both can be flashed)
  local PRODUCTION_SIZE_HEX=$RECOVERY_SIZE_HEX

  # Calculate production offset
  # = RECOVERY_OFFSET + RECOVERY_SIZE, then round up to 64KB boundary for app partition alignment
  local production_offset=$((0x30000 + recovery_size_calc))

  # Round up to nearest 64KB (0x10000) for ESP32 app partition alignment requirement
  local remainder=$((production_offset % 0x10000))
  if [[ $remainder -ne 0 ]]; then
    production_offset=$(((production_offset / 0x10000 + 1) * 0x10000))
  fi

  local PRODUCTION_OFFSET_HEX
  PRODUCTION_OFFSET_HEX=$(printf '0x%x' "$production_offset")

  # Export for use in partition table generation
  export RECOVERY_SIZE="$RECOVERY_SIZE_HEX"
  export PRODUCTION_SIZE="$PRODUCTION_SIZE_HEX"
  export PRODUCTION_OFFSET="$PRODUCTION_OFFSET_HEX"

  # Log the calculated values
  info "Partition sizes calculated from firmware ($firmware_size bytes):"
  info "  Recovery partition: $RECOVERY_SIZE_HEX ($recovery_size_calc bytes)"
  info "  Production partition: $PRODUCTION_SIZE_HEX"
  info "  Production offset: $PRODUCTION_OFFSET_HEX"
}

_generate_partition_table() {
  # Generate partition table CSV from calculated/loaded partition sizes
  # Sources NVS, recovery, and production sizes from calculated values

  cat << EOF
# ESP32-C6 Partition Table for Dual App OTA Recovery
# Generated from compiled firmware sizes (failsafe partition auto-sized)
# Bootloader: 0x0-0x8000 (32KB)
# NVS: 0x9000 (16KB, fixed)
# OTA Data: 0xd000 (8KB, fixed)
# Recovery: ota_0 at 0x30000 (sized to firmware + margin)
# Production: ota_1 (sized to recovery, offset calculated)
# Name,     Type,  SubType,    Offset,              Size,
nvs,        data,  nvs,        0x9000,              0x4000,
otadata,    data,  ota,        0xd000,              0x2000,
recovery,   app,   ota_0,      0x30000,             ${RECOVERY_SIZE:-0x180000},
production, app,   ota_1,      ${PRODUCTION_OFFSET:-0x1b0000}, ${PRODUCTION_SIZE:-0x240000},
EOF
}

_update_partition_table_file() {
  # Write generated partition table to ~/.iotstack/iotstack_partition_table.csv
  # ESPHome accesses via symlink at yamls/iotstack_partition_table.csv
  local output_file="${1:-${HOME}/.iotstack/iotstack_partition_table.csv}"

  debug "Writing partition table: $output_file"
  mkdir -p "$(dirname "$output_file")"
  _generate_partition_table > "$output_file"

  # Ensure symlink exists from yamls/ to ~/.iotstack/
  local symlink_path="${YAMLS_DIR}/iotstack_partition_table.csv"
  if [[ ! -L "$symlink_path" ]] || [[ "$(readlink "$symlink_path")" != "$output_file" ]]; then
    rm -f "$symlink_path"
    ln -s "$output_file" "$symlink_path"
    debug "Created symlink: $symlink_path -> $output_file"
  fi

  ok "Partition table generated and saved to $output_file"
}

smart_compile() {
  # Smart compilation that uses cache to skip rebuilds
  # After compilation, calculates partition sizes based on firmware size
  # Usage: smart_compile <yaml_file> [device_name_for_logging]
  # Environment variable: DISABLE_COMPILATION_CACHE=1 forces recompilation
  local yaml_file="$1"
  local device_name="${2:-unknown}"

  # Get YAML SHA before compilation
  local yaml_sha
  yaml_sha=$(_get_yaml_sha "$yaml_file")
  [[ -z "$yaml_sha" ]] && err "Failed to compute SHA256 of $yaml_file"

  # Generate initial partition table (needed by ESPHome during compilation)
  _generate_initial_partition_table

  # Check if we can skip compilation (unless DISABLE_COMPILATION_CACHE is set)
  if [[ "${DISABLE_COMPILATION_CACHE:-0}" != "1" ]] && _check_compilation_cache "$yaml_file"; then
    ok "Firmware already compiled (cached)"
    # Even when using cache, recalculate partition sizes in case firmware size changed
    _calculate_partition_sizes "$device_name" "$yaml_file" || return 1
    _update_partition_table_file
    return 0
  fi

  [[ "${DISABLE_COMPILATION_CACHE:-0}" == "1" ]] && debug "Compilation cache disabled (DISABLE_COMPILATION_CACHE=1)"

  # YAML changed or first compile - need to rebuild
  info "Compiling firmware..."
  if [[ $VERBOSE -eq 1 ]]; then
    esphome compile "$yaml_file" || return 1
  else
    esphome compile "$yaml_file" >/dev/null 2>&1 || return 1
  fi

  # Get binary SHA after successful compilation
  local binary_sha
  binary_sha=$(_get_binary_sha "$device_name")
  if [[ -n "$binary_sha" ]]; then
    _update_compilation_cache "$yaml_file" "$binary_sha"
    ok "Compilation cached"
  fi

  # Calculate partition sizes based on actual compiled firmware size
  _calculate_partition_sizes "$device_name" "$yaml_file" || return 1
  _update_partition_table_file

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

# Source centralized configuration
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.sh"

UPDATE_SCRIPT="${SCRIPT_DIR}/update_devices.sh"

# ── Worktree Isolation ────────────────────────────────────────────────────────
# Each iotstack invocation gets its own isolated worktree to prevent code
# changes from affecting running commands.

_setup_worktree() {
  local worktree_dir="${SCRIPT_DIR}/.git/worktrees/iotstack-$$"

  # Create and enter worktree
  cd "$SCRIPT_DIR"

  # Suppress git worktree output if QUIET is set
  if [[ $QUIET -eq 1 ]]; then
    git worktree add "$worktree_dir" HEAD >/dev/null 2>&1 || return 0
  else
    git worktree add "$worktree_dir" HEAD 2>/dev/null || return 0
  fi

  # Re-exec in worktree
  cd "$worktree_dir"
  export IOTSTACK_WORKTREE="$worktree_dir"
  export QUIET="$QUIET"  # Preserve QUIET flag in worktree
  exec bash "$SCRIPT_PATH" "$@"
}

_cleanup_worktree() {
  if [[ -n "${IOTSTACK_WORKTREE:-}" ]]; then
    cd "$SCRIPT_DIR" 2>/dev/null || return 0
    git worktree remove "$IOTSTACK_WORKTREE" --force 2>/dev/null || true
  fi
}

# Parse global flags early (before worktree setup) so they apply to git commands
# Only parse -q/--quiet, -v/--verbose, and -env= flags here
for arg in "$@"; do
  case "$arg" in
    -q|--quiet)
      QUIET=1
      ;;
    -v|--verbose)
      VERBOSE=1
      ;;
  esac
done

# Set up cleanup trap to ensure worktree is removed on exit
# This runs in both parent (before creating worktree) and child (after re-exec)
trap _cleanup_worktree EXIT

# Create isolated worktree for this invocation
if [[ -z "${IOTSTACK_WORKTREE:-}" ]]; then
  _setup_worktree "$@"
fi

# ──────────────────────────────────────────────────────────────────────────────

# Check if update_devices.sh exists
if [[ ! -f "$UPDATE_SCRIPT" ]]; then
  err "update_devices.sh not found at $UPDATE_SCRIPT"
fi

if [[ ! -d "$YAMLS_DIR" ]]; then
  err "yamls directory not found at $YAMLS_DIR"
fi

# ── Dynamic Role Discovery ──────────────────────────────────────────────────
# Roles are discovered from YAML filenames in yamls/ directory
# File: yamls/bleproxy.yaml → Role: bleproxy

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

Run 'iotstack list roles' for details."
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
  grep -v "^#\|^$" "${SCRIPT_DIR}/roles.conf" | cut -d= -f1 | sort
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

  # Get HA credentials from pass store
  local ha_token
  ha_token=$(pass show "iotstack/common/ha_token" 2>/dev/null | xargs || echo "")
  local ha_url
  ha_url=$(pass show "iotstack/common/ha_url" 2>/dev/null | xargs || echo "")

  # If still no credentials, return empty
  if [[ -z "$ha_token" ]] || [[ -z "$ha_url" ]]; then
    return 1
  fi

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

# ── Parallel Job Queue ────────────────────────────────────────────────────────
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

# ── Subcommands ──────────────────────────────────────────────────────────────

usage() {
  cat "${SCRIPT_DIR}/docs/help/iotstack.txt"
}

help_update() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-update.txt"
}

help_verify() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-verify.txt"
}

help_list() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-list.txt"
}

help_devices() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-devices.txt"
}

help_roles() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-roles.txt"
}

help_reassign() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-reassign.txt"
}

help_flash() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-flash.txt"
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

list_devices() {
  local output_format="${1:-text}"
  local filter_role="${2:-}"
  local suffix_only="${3:-false}"
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
  done < <(avahi-browse -t -r _esphomelib._tcp 2>/dev/null)

  # Sort and deduplicate
  sort -u "$device_data" > "${device_data}.sorted"

  # Try to get Home Assistant area info
  local ha_areas="{}"
  if get_ha_device_areas > /tmp/ha_areas.json 2>/dev/null; then
    ha_areas=$(cat /tmp/ha_areas.json)
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
      ) | jq '.'
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
    (
      echo "["
      first=true
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
        area=$(echo "$ha_areas" | jq -r ".[\"$hostname\"] // .[\"$friendly\"] // null" 2>/dev/null)
        [[ -z "$area" ]] && area=null
        [[ "$first" != true ]] && echo ","
        printf '  {"id": "%s", "device": "%s", "friendly_name": "%s", "area": %s, "project": "%s", "version": "%s", "hash": "%s"}' \
          "$id" "$hostname" "$friendly" "$area" "$project" "$version" "$hash"
        first=false
      done < "${device_data}.sorted"
      echo
      echo "]"
    ) | jq '.'
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

    info "Discovered ESPHome devices on network:"
    echo

    # Print headers with calculated widths (all left-aligned with %)
    printf "  ${GRN}%-${w_id}s %-${w_device}s %-${w_friendly}s %-${w_area}s %-${w_project}s %-${w_version}s %-${w_hash}s${RST}\n" \
      "ID" "Device" "Friendly Name" "Area" "Project" "Version" "Hash"

    # Print separator
    printf '  %s' "$DIM"
    printf "%-${w_id}s " "$(printf '─%.0s' $(seq 1 $((w_id-1))))"
    printf "%-${w_device}s " "$(printf '─%.0s' $(seq 1 $((w_device-1))))"
    printf "%-${w_friendly}s " "$(printf '─%.0s' $(seq 1 $((w_friendly-1))))"
    printf "%-${w_area}s " "$(printf '─%.0s' $(seq 1 $((w_area-1))))"
    printf "%-${w_project}s " "$(printf '─%.0s' $(seq 1 $((w_project-1))))"
    printf "%-${w_version}s " "$(printf '─%.0s' $(seq 1 $((w_version-1))))"
    printf "%-${w_hash}s" "$(printf '─%.0s' $(seq 1 $((w_hash-1))))"
    printf '%s\n' "$RST"

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
  printf '  %s' "$DIM"
  printf "%-${w_device}s " "$(printf '─%.0s' $(seq 1 $((w_device-1))))"
  printf "%-${w_type}s " "$(printf '─%.0s' $(seq 1 $((w_type-1))))"
  printf "%-${w_network}s " "$(printf '─%.0s' $(seq 1 $((w_network-1))))"
  printf "%-${w_config}s" "$(printf '─%.0s' $(seq 1 $((w_config-1))))"
  printf '%s\n' "$RST"

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

# ── Command Handlers ─────────────────────────────────────────────────────────

cmd_update() {
  # Handle help request
  if [[ "${1:-}" == "help" ]]; then
    help_update
    return 0
  fi

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
      --dry-run|--flash-anyway|--verbose|-v|--jobs)
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
        declare -a cmd=("$UPDATE_SCRIPT" "${update_args[@]}")
        [[ -n "$ota_password" ]] && cmd+=("--ota-password" "$ota_password")
        [[ ${#mac_suffixes[@]} -gt 0 ]] && cmd+=("--macs" "${mac_suffixes[@]}")
        cmd+=("$yaml")

        if "${cmd[@]}"; then
          found=$((found + 1))
        else
          failed=$((failed + 1))
        fi
        echo
      fi
    done < <(cat "${SCRIPT_DIR}/roles.conf" 2>/dev/null || echo "")

    echo "────────────────────────────────────────────────────────────"
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

    # Build update command with OTA password and MACs if specified
    declare -a cmd=("$UPDATE_SCRIPT" "${update_args[@]}")
    [[ -n "$ota_password" ]] && cmd+=("--ota-password" "$ota_password")
    [[ ${#mac_suffixes[@]} -gt 0 ]] && cmd+=("--macs" "${mac_suffixes[@]}")
    cmd+=("$yaml_file")

    "${cmd[@]}"
  fi
}

cmd_reassign() {
  # Handle help request
  if [[ "${1:-}" == "help" ]]; then
    help_reassign
    return 0
  fi

  local api_key=""
  local password_list_file=""
  declare -a update_args=()
  declare -a positional_args=()

  # Separate options from positional arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ota-password)
        api_key="$2"
        shift 2
        ;;
      --ota-password-list-path)
        password_list_file="$2"
        shift 2
        ;;
      --dry-run|-v|--verbose)
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
  local target_role="$device_or_yaml"
  for mac in "${reassign_macs[@]}"; do
    local device_info
    device_info=$(avahi-browse -t -r _esphomelib._tcp 2>/dev/null | grep -i "$mac" | head -1)
    if [[ -n "$device_info" ]]; then
      local device_name
      device_name=$(echo "$device_info" | awk -F' ' '{print $4}' | cut -d'.' -f1)
      local current_role="${device_name%-"$mac"}"
      if [[ "$current_role" == "$target_role" ]]; then
        ok "Device $device_name is already assigned to $target_role — no reassign needed."
        return 0
      fi
    fi
  done

  info "Reassigning devices..."
  echo "  MACs: ${reassign_macs[*]}"

  # Confirm before reassigning multiple devices
  confirm_multi_device ${#reassign_macs[@]} "$(printf '%s\n' "${reassign_macs[@]}")"

  # Handle password list if provided
  if [[ -n "$password_list_file" ]]; then
    # Expand path (handle ~)
    password_list_file="${password_list_file/#\~/$HOME}"

    if [[ ! -f "$password_list_file" ]]; then
      err "Password list file not found: $password_list_file"
    fi

    echo "  Mode: Password list brute-force"
    echo

    declare -a successful_passwords=()
    declare -a failed_passwords=()
    local password_count=0

    while IFS= read -r password || [[ -n "$password" ]]; do
      # Skip empty lines and comments
      [[ -z "$password" ]] && continue
      [[ "$password" =~ ^[[:space:]]*# ]] && continue

      # Trim whitespace
      password=$(printf '%s' "$password" | xargs)
      [[ -z "$password" ]] && continue

      password_count=$((password_count + 1))
      echo "[${password_count}] Trying password (${#password} chars)..."

      # Try reassign with this password
      if "$UPDATE_SCRIPT" --reassign "${reassign_macs[@]}" "$yaml_file" --ota-password "$password" "${update_args[@]}" 2>&1 | grep -q "flash successful"; then
        ok "  ✓ Password worked!"
        successful_passwords+=("$password")
      else
        failed_passwords+=("$password")
      fi
      echo
    done < "$password_list_file"

    # Summary
    echo "════════════════════════════════════════════════════════"
    echo "[INFO] Password brute-force summary:"
    echo "  Total tried: $password_count"
    echo "  Successful: ${#successful_passwords[@]}"
    echo "  Failed: ${#failed_passwords[@]}"

    if [[ ${#successful_passwords[@]} -gt 0 ]]; then
      echo
      ok "Working password(s):"
      for pwd in "${successful_passwords[@]}"; do
        echo "  → $(printf '%s' "$pwd" | head -c 32)${#pwd}"
      done
      return 0
    else
      err "No passwords from the list worked"
      # shellcheck disable=SC2317
      return 1
    fi
  else
    # Single password mode - auto-retrieve from pass if not provided
    local source_role=""

    if [[ -n "$api_key" ]]; then
      echo "  OTA Password: (provided)"
    else
      # Try to auto-retrieve OTA password from pass for current device role
      for mac in "${reassign_macs[@]}"; do
        # Query mDNS to find device with this MAC suffix
        local device_info
        device_info=$(avahi-browse -t -r _esphomelib._tcp 2>/dev/null | grep -i "$mac" | head -1)
        if [[ -n "$device_info" ]]; then
          # Extract device name (e.g., "bleproxy-137284" from the line)
          local device_name
          device_name=$(echo "$device_info" | awk -F' ' '{print $4}' | cut -d'.' -f1)
          # Extract role (everything before the MAC suffix)
          source_role="${device_name%-"$mac"}"

          if [[ -n "$source_role" ]]; then
            # If device is running failsafe firmware, use well-known recovery password
            if [[ "$source_role" =~ ^recovery ]]; then
              api_key="IotstackRecovery2024"
              echo "  OTA Password: (well-known recovery password)"
              break
            fi

            # Try to retrieve OTA password for this role
            api_key=$(cmd_secret get "$source_role" ota 2>/dev/null) || true
            if [[ -n "$api_key" ]]; then
              echo "  OTA Password: (auto-retrieved from $source_role)"
              break
            fi
          fi
        fi
      done

      if [[ -z "$api_key" ]]; then
        warn "Could not auto-retrieve OTA password. Proceeding without password."
        echo "  OTA Password: (none)"
      fi
    fi
    echo

    # Suppress verbose esphome output, only show errors
    local log_file
    log_file="${HOME}/.iotstack/logs/reassign-$(date +%s).log"
    mkdir -p "$(dirname "$log_file")"

    # Build and invoke update_devices.sh with reassign flags
    if [[ -n "$api_key" ]]; then
      "$UPDATE_SCRIPT" --reassign "${reassign_macs[@]}" "$yaml_file" --ota-password "$api_key" "${update_args[@]}" > "$log_file" 2>&1
    else
      "$UPDATE_SCRIPT" --reassign "${reassign_macs[@]}" "$yaml_file" "${update_args[@]}" > "$log_file" 2>&1
    fi

    local exit_code=$?

    # Show summary lines from log (ok/err/warn only)
    grep -E '^\[OK\]|\[ERR\]|\[WARN\]|^═' "$log_file" 2>/dev/null || true

    if [[ $exit_code -ne 0 ]]; then
      warn "See full log: $log_file"
    fi

    return $exit_code
  fi
}

cmd_verify() {
  # Handle help request
  if [[ "${1:-}" == "help" ]]; then
    help_verify
    return 0
  fi

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
        echo "────────────────────────────────────────────────────────────"
        info "Verifying: $yaml"
        echo "────────────────────────────────────────────────────────────"
        if "$UPDATE_SCRIPT" --verify "$yaml"; then
          found=$((found + 1))
        else
          failed=$((failed + 1))
        fi
        echo
      fi
    done < <(find . -maxdepth 3 -name "*.yaml" -type f | sort)

    echo "────────────────────────────────────────────────────────────"
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
    "$UPDATE_SCRIPT" --verify "$yaml_file"
  fi
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
  # Handle help request
  if [[ "${1:-}" == "help" ]]; then
    help_list
    return 0
  fi

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
      devices|roles)
        subcommand="$1"
        shift
        # For devices subcommand, next argument might be a role filter
        if [[ "$subcommand" == "devices" && $# -gt 0 && "$1" != --* ]]; then
          filter_role="$1"
          shift
        fi
        ;;
      *)
        err "Unknown argument: $1"
        ;;
    esac
  done

  # Show help if no subcommand provided
  if [[ -z "$subcommand" ]]; then
    help_list
    return
  fi

  case "$subcommand" in
    devices)
      list_devices "$output_format" "$filter_role" "$suffix_only"
      ;;
    roles)
      list_roles "$output_format" "$suffix_only"
      ;;
    *)
      err "Unknown subcommand: $subcommand. Try 'iotstack list devices' or 'iotstack list roles'"
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
  ha_url=$(pass show "iotstack/common/ha_url" 2>/dev/null | xargs || echo "")
  ha_token=$(pass show "iotstack/common/ha_token" 2>/dev/null | xargs || echo "")

  # Check if HA credentials are configured
  local ha_configured=false
  if [[ -n "$ha_url" && -n "$ha_token" ]]; then
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

  # Get current OTA password from password manager (versioned)
  local current_password
  echo "[INFO] Retrieving current OTA password from version history..."
  current_password=$(cmd_secret get "$role" ota 2>/dev/null)
  if [[ -z "$current_password" ]]; then
    err "No password found in pass. Ensure role '$role' has an OTA password configured."
  fi

  if [[ -z "$current_password" ]]; then
    err "Current password is required"
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
  mac_line=$(iotstack list devices "$role" --id 2>/dev/null)
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

  # Flash all devices with new password using old password for authentication
  echo "[INFO] Flashing devices with new password (authenticating with old password)..."
  echo "[INFO] Using parallel jobs (4 devices at a time)..."
  echo

  local max_jobs=4
  declare -a commands=()

  # Build command list for parallel execution
  for mac in "${mac_suffixes[@]}"; do
    commands+=("if \"$UPDATE_SCRIPT\" --reassign \"$mac\" \"$(resolve_device "$role")\" --ota-password \"$current_password\" >/dev/null 2>&1; then echo \"[OK] $mac flashed successfully\"; else echo \"[ERR] $mac flash failed\"; fi")
  done

  # Run all flashing jobs in parallel
  job_results=()
  run_parallel_jobs "$max_jobs" "${commands[@]}"

  # Collect results
  local success_count=0
  local fail_count=0
  declare -a failed_macs=()

  for i in "${!job_results[@]}"; do
    if [[ ${job_results[$i]} -eq 0 ]]; then
      success_count=$((success_count + 1))
    else
      fail_count=$((fail_count + 1))
      failed_macs+=("${mac_suffixes[$i]}")
    fi
  done

  echo
  echo "════════════════════════════════════════════════════════"
  echo "[INFO] Secret Rotation Summary"
  echo "════════════════════════════════════════════════════════"
  echo "  Role: $role"
  echo "  Total: ${#mac_suffixes[@]}"
  echo "  Success: $success_count"
  echo "  Failed: $fail_count"

  if [[ $fail_count -gt 0 ]]; then
    echo "  Failed MACs: ${failed_macs[*]}"
    echo
    warn "Some devices failed. Retry with:"
    echo "  iotstack reassign ${failed_macs[*]} $role --ota-password \"<password>\""
    echo
    warn "Using new password (if those devices were flashed):"
    echo "  iotstack reassign ${failed_macs[*]} $role"
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

  # If --id flag was used, just output role names (one per line, no formatting)
  if [[ "$id_only" == "true" ]]; then
    list_roles_from_conf
    return 0
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
    echo "["
    # Collect, sort, and format JSON entries
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
        printf "%s_%s|%s|%s|%s|%s|%s|%s\n" "$sort_key" "$device" "$device" "$board" "$variant" "$network_type" "$dev_status" "$config_file"
      done
    } | sort -t_ -k1,1 -k2 | cut -d'|' -f2- | {
      first=true
      while IFS='|' read -r device board variant network_type dev_status config_file; do
        [[ "$first" != true ]] && echo ","
        printf '  {"role": "%s", "board": "%s", "variant": "%s", "network": "%s", "status": "%s", "config": "%s"}' \
          "$device" "$board" "$variant" "$network_type" "$dev_status" "$config_file"
        first=false
      done
    }
    echo
    echo "]"
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
    printf '%s' "  ${DIM}"
    printf "%-${w_role}s " "$(printf '─%.0s' $(seq 1 $((w_role-1))))"
    printf "%-${w_board}s " "$(printf '─%.0s' $(seq 1 $((w_board-1))))"
    printf "%-${w_variant}s " "$(printf '─%.0s' $(seq 1 $((w_variant-1))))"
    printf "%-${w_network}s " "$(printf '─%.0s' $(seq 1 $((w_network-1))))"
    printf "%-${w_status}s " "$(printf '─%.0s' $(seq 1 $((w_status-1))))"
    printf "%-${w_config}s" "$(printf '─%.0s' $(seq 1 $((w_config-1))))"
    printf '%s\n' "${RST}"

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

# ── Flash command: serial/USB flashing ─────────────────────────────────────
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
    iotstack set-boot 1af95c failsafe          # Set failsafe-1af95c → failsafe
    iotstack set-boot 9019c8 production        # Set failsafe-9019c8 → production

  USB-connected device:
    iotstack set-boot /dev/ttyACM0 failsafe    # Set /dev/ttyACM0 → failsafe
    iotstack set-boot /dev/ttyUSB0 production  # Set /dev/ttyUSB0 → production
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
    info "Setting recovery-$device to boot: $partition"
    _boot_partition_network "$partition" "$device"
  fi
}

_boot_partition_usb() {
  # Set boot partition on USB-connected device
  local device="$1"
  local partition="$2"

  # Device must be running failsafe firmware for this to work
  info "Toggling boot partition..."
  if timeout 5 curl -s -X POST "http://localhost:6053/api/services/button/press" \
    -H "Content-Type: application/json" \
    -d '{"entity_id": "button.recovery_toggle_boot_partition"}' >/dev/null 2>&1; then
    ok "Boot partition toggled to: $partition"
  else
    err "Could not communicate with device. Ensure it's running and connected."
  fi
}

_boot_partition_single() {
  # Set boot partition on a single device
  local target_partition="$1"
  local mac="$2"
  local device_name="recovery-$mac"
  local device_host="${device_name}.local"

  info "Setting $device_name to boot: $target_partition..."

  # Try ESPHome API directly on device (no HA needed)
  if curl -s -X POST "http://$device_host/api/services/button/press" \
    -H "Content-Type: application/json" \
    -d "{\"entity_id\": \"button.${device_name}_toggle_boot_partition\"}" \
    --max-time 5 >/dev/null 2>&1; then
    ok "  Boot partition set to $target_partition, device rebooting..."
  else
    err "Could not reach device at $device_host (is it on the network?)"
  fi
}

cmd_flash() {
  # Handle help request
  if [[ "${1:-}" == "help" ]]; then
    help_flash
    return 0
  fi
  local device="${1:-}"
  local tty_device_or_role="${2:-}"
  local skip_recovery="${3:-}"

  if [[ -z "$device" ]]; then
    help_flash
    exit 1
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

  # For production roles: smart dual-partition setup
  # If device is fresh (no recovery): flash recovery first, then production
  # If device exists (has recovery): just flash production via OTA
  _flash_production_smart "$device" "$tty_device_or_role" "$skip_recovery"
}

_flash_recovery() {
  # Flash recovery image via serial and return the device's MAC suffix
  local tty_device="$1"

  info "Flashing failsafe firmware (dual-partition setup)"
  echo ""

  local failsafe_yaml="$YAMLS_DIR/failsafe.yaml"
  debug "failsafe_yaml=$failsafe_yaml"
  if [[ ! -f "$failsafe_yaml" ]]; then
    err "Failsafe firmware not found: $failsafe_yaml"
  fi
  debug "failsafe.yaml file exists"

  # If specific TTY device, flash only that one
  debug "tty_device=$tty_device"
  if [[ -n "$tty_device" ]]; then
    debug "TTY device provided: $tty_device"
    if [[ ! -e "$tty_device" ]]; then
      err "TTY device not found: $tty_device"
    fi
    debug "TTY device exists"

    # Check if serial port is already in use
    debug "Checking if serial port is in use..."
    _check_serial_port_in_use "$tty_device"
    debug "Serial port check completed"

    info "Flashing to: $tty_device"
    info "Compiling failsafe firmware..."
    smart_compile "$failsafe_yaml" "recovery" || err "Compilation failed"

    info "Uploading failsafe firmware to device..."

    # Create flash log directory
    local flash_log_dir="$HOME/.iotstack/logs/flash"
    mkdir -p "$flash_log_dir"
    local flash_log
    flash_log="$flash_log_dir/$(date +%Y%m%d_%H%M%S).log"

    # Erase flash completely to handle devices with incompatible firmware (RCP, etc.)
    info "Erasing flash memory..."
    esptool --chip esp32c6 --port "$tty_device" --baud 9600 erase_flash 2>&1 | tee -a "$flash_log" >/dev/null || err "Erase failed"
    sleep 3  # Wait for erase to complete and device to stabilize

    # Flash generic failsafe firmware and capture MAC
    local build_dir="$YAMLS_DIR/.esphome/build/recovery/.pioenvs/recovery"
    [[ ! -d "$build_dir" ]] && err "Build directory not found: $build_dir"

    info "Flashing failsafe firmware..."
    if [[ $VERBOSE -eq 1 ]]; then
      info "Detailed output:"
      info "tail -f $flash_log"
    fi

    # Flash and capture output
    local esptool_output
    esptool_output=$(esptool --chip esp32c6 --port "$tty_device" --baud 9600 \
      write-flash --flash-mode dio --flash-size 4MB --flash-freq 40m \
      0x0 "$build_dir/bootloader.bin" \
      0x8000 "$build_dir/partitions.bin" \
      0x30000 "$build_dir/firmware.bin" 2>&1 | tee -a "$flash_log") || err "Flash failed"

    # Extract MAC address from esptool output
    local device_mac
    device_mac=$(echo "$esptool_output" | grep "BASE MAC:" | awk '{print $NF}' | sed 's/://g' | tr -d '[:space:]')
    device_mac="${device_mac: -6}"

    [[ -z "$device_mac" || ! "$device_mac" =~ ^[0-9a-f]{6}$ ]] && err "Failed to extract MAC address from device"

    ok "Failsafe firmware flashed to: $device_mac"
    echo ""

    # Compute device-specific OTA password from role-based secret
    # sha256(role_secret | device_mac) - never stored, computed in-memory only
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

    local device_specific_ota_password
    device_specific_ota_password=$(echo -n "${failsafe_role_password}|${device_mac}" | sha256sum | cut -c1-32)

    # Write device-specific secrets to NVS partition
    # Firmware reads these via custom NVS components
    info "Writing device-specific secrets to NVS..."
    "$SCRIPT_DIR/scripts/write-nvs-secrets.sh" "$tty_device" "$device_mac" "failsafe" "$device_specific_ota_password" || \
      err "Failed to write NVS secrets"
    sleep 2  # Let device stabilize after NVS write

    # Verify flash checksums before proceeding
    info "Verifying flash checksums..."
    sleep 1  # Brief pause before verification to ensure flash is readable
    "$SCRIPT_DIR/scripts/verify-flash.sh" "$tty_device" "failsafe" || \
      err "Flash verification failed - device may be corrupted"
    echo ""

    info "Device booting failsafe firmware..."
    info "(Failsafe firmware at 0x30000 - failsafe partition)"
    sleep 10

    # Return the MAC suffix for later reassignment
    echo "$device_mac"
    return
  fi

  # Auto-detect USB serial devices
  local tty_devices=()
  for dev in /dev/ttyACM* /dev/ttyUSB*; do
    if [[ -e "$dev" ]]; then
      tty_devices+=("$dev")
    fi
  done 2>/dev/null

  if [[ ${#tty_devices[@]} -eq 0 ]]; then
    # Diagnostic: check if USB devices might be claimed by a VM
    local vm_warning=""
    if pgrep -l "VirtualBox|qemu|vboxheadless" >/dev/null 2>&1; then
      vm_warning=$'\n\n⚠️  Virtual machine(s) detected. USB devices may be passed through to a VM.\n   Stop the VM or disconnect devices from it to use them on the host.'
    fi
    err "No USB serial devices found. Plug in device(s) and try again.${vm_warning}"
  fi

  info "Found ${#tty_devices[@]} USB device(s): ${tty_devices[*]}"

  # Confirm before flashing multiple devices
  confirm_multi_device ${#tty_devices[@]} "$(printf '%s\n' "${tty_devices[@]}")"

  info "Compiling failsafe firmware..."
  if [[ $VERBOSE -eq 1 ]]; then
    esphome compile "$failsafe_yaml" || err "Compilation failed"
  else
    esphome compile "$failsafe_yaml" >/dev/null 2>&1 || err "Compilation failed"
  fi
  ok "Failsafe firmware compiled"
  echo ""

  # Flash to all devices sequentially (one at a time)
  local build_dir="$YAMLS_DIR/.esphome/build/recovery/.pioenvs/recovery"
  [[ ! -d "$build_dir" ]] && err "Build directory not found: $build_dir"

  local failed=0
  for tty in "${tty_devices[@]}"; do
    local log_file
    log_file="/tmp/iotstack-flash-recovery-$(basename "$tty").log"
    echo ""
    info "Flashing $tty (log: $log_file)..."
    echo "════════════════════════════════════════════════════════"

    if esptool --chip esp32c6 --port "$tty" --baud 9600 \
      write-flash --flash-mode dio --flash-size 4MB \
      0x0 "$build_dir/bootloader.bin" \
      0x8000 "$build_dir/partitions.bin" \
      0x30000 "$build_dir/firmware.bin" 2>&1 | tee "$log_file"; then
      ok "Failsafe firmware flashed on $tty"
    else
      warn "Recovery flash FAILED on $tty"
      failed=$((failed + 1))
    fi

    echo "════════════════════════════════════════════════════════"
  done

  if [[ $failed -gt 0 ]]; then
    err "Failed to flash recovery to $failed device(s)"
  else
    ok "Failsafe firmware flashed to all ${#tty_devices[@]} device(s)"
    echo ""
    info "Devices booting failsafe firmware..."
    info "Waiting 15 seconds for devices to stabilize and connect..."
    sleep 15
  fi
}

_flash_recovery_dual() {
  # Dual-flash: recovery via serial + production role via OTA
  # Usage: iotstack flash recovery mmwave
  local production_role="$1"

  # First: flash recovery via serial to all USB devices (auto-detect)
  _flash_recovery ""

  # Second: Discover recovery devices and reassign to production role
  info "Step 2: Reassigning devices to $production_role firmware via OTA..."
  echo ""

  # Discover recovery devices
  local recovery_macs=()
  while IFS= read -r line; do
    if [[ "$line" =~ recovery-([0-9a-f]+) ]]; then
      recovery_macs+=("${BASH_REMATCH[1]}")
    fi
  done < <(avahi-browse -t -r _esphomelib._tcp 2>/dev/null)

  if [[ ${#recovery_macs[@]} -eq 0 ]]; then
    err "No recovery devices found on network. Check WiFi connection."
  fi

  # Resolve role to YAML
  local yaml_file
  yaml_file=$(resolve_device "$production_role" false) || err "Unknown role: $production_role"

  # Use well-known recovery password for reassign
  local ota_password="IotstackRecovery2024"

  info "Flashing ${#recovery_macs[@]} device(s) to $production_role..."
  "$UPDATE_SCRIPT" --reassign "${recovery_macs[@]}" "$yaml_file" --ota-password "$ota_password" --jobs 1 || err "OTA update failed"

  # Third: Toggle boot partition to production and reboot devices
  info "Toggling boot partition to production firmware..."
  echo ""

  # Discover recovery devices and toggle them
  local recovery_devices=()
  while IFS= read -r line; do
    if [[ "$line" =~ recovery-([0-9a-f]+) ]]; then
      recovery_devices+=("${BASH_REMATCH[1]}")
    fi
  done < <(avahi-browse -t -r _esphomelib._tcp 2>/dev/null)

  if [[ ${#recovery_devices[@]} -gt 0 ]]; then
    # Try to toggle via Home Assistant first
    local ha_url
    ha_url=$(pass show iotstack/common/ha_url 2>/dev/null || echo "")
    local ha_token
    ha_token=$(pass show iotstack/common/ha_token 2>/dev/null || echo "")

    if [[ -n "$ha_url" && -n "$ha_token" ]]; then
      # Call the partition toggle button via Home Assistant
      for mac in "${recovery_devices[@]}"; do
        local device_name="recovery-$mac"
        local entity_id="button.${device_name,,}_toggle_boot_partition"

        info "Toggling partition on $device_name (via HA)..."
        if curl -s -X POST "$ha_url/api/services/button/press" \
          -H "Authorization: Bearer $ha_token" \
          -H "Content-Type: application/json" \
          -d "{\"entity_id\": \"$entity_id\"}" >/dev/null 2>&1; then
          ok "  Partition toggled, device rebooting..."
        else
          warn "  Could not toggle partition via HA (continuing anyway)"
        fi
      done
    else
      # Fallback: toggle via ESPHome API directly on device
      for mac in "${recovery_devices[@]}"; do
        local device_name="recovery-$mac"
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

  info "Production firmware setup for: $device"
  echo ""

  # If TTY device specified: flash via serial (assume fresh device)
  if [[ -n "$tty_device" ]]; then
    if [[ ! -e "$tty_device" ]]; then
      err "TTY device not found: $tty_device"
    fi

    # Check if user wants to skip recovery
    local device_mac=""
    if [[ "$skip_recovery" != "--ota-only" ]]; then
      info "Fresh device detected (serial connection)"
      info "Step 1: Flashing failsafe firmware..."
      echo ""
      device_mac=$(_flash_recovery "$tty_device")
      echo ""
      info "Step 2: Waiting for device to appear on network..."
      echo ""
    else
      info "Skipping recovery (--ota-only flag)"
      echo ""
    fi

    # Reassign recovery device to production
    if [[ -n "$device_mac" ]]; then
      # Extract only the MAC suffix (last 6 chars) from captured output
      device_mac=$(echo "$device_mac" | tail -1 | tr -d '[:space:]')

      info "Waiting for recovery device ($device_mac) to connect to network..."
      local max_wait=60
      local waited=0
      local found=false

      while [[ $waited -lt $max_wait ]]; do
        # Check if device is on network via mDNS
        if avahi-browse -t -r _esphomelib._tcp 2>/dev/null | grep -Fqi "recovery-$device_mac"; then
          info "  Device found on mDNS, waiting for OTA service..."

          # Verify OTA service is actually responding on port 3232
          if timeout 2 bash -c "echo > /dev/tcp/recovery-$device_mac.local/3232" 2>/dev/null; then
            found=true
            break
          fi
        fi

        sleep 1
        waited=$((waited + 1))

        # Show progress every 10 seconds
        if (( waited % 10 == 0 )); then
          info "  Still waiting... ($waited/$max_wait seconds)"
        fi
      done

      if [[ "$found" != "true" ]]; then
        err "Recovery device (recovery-$device_mac) OTA service not ready after $max_wait seconds. Check WiFi connection or device logs."
      fi

      info "Device found on network! Waiting for OTA service to fully initialize..."
      sleep 30

      info "Reassigning recovery-$device_mac to $device firmware..."

      # Retrieve recovery role-based OTA password from pass store
      local recovery_role_password
      recovery_role_password=$(pass show "iotstack/roles/recovery/ota_password" 2>/dev/null)
      if [[ -z "$recovery_role_password" ]]; then
        info "Recovery role OTA password not found, generating..."
        recovery_role_password=$(openssl rand -hex 16)
        # Store it in pass
        { echo "$recovery_role_password"; echo "$recovery_role_password"; } | \
          pass insert -f "iotstack/roles/recovery/ota_password" 2>/dev/null || \
          err "Failed to store recovery OTA password in pass"
        ok "Recovery OTA password generated and stored"
      fi

      # Compute device-specific OTA password from role secret + MAC
      # sha256(role_secret | device_mac) - computed in-memory only
      local device_ota_password
      device_ota_password=$(echo -n "${recovery_role_password}|${device_mac}" | sha256sum | cut -c1-32)

      if ! "$UPDATE_SCRIPT" --reassign "$device_mac" "$yaml_path" --ota-password "$device_ota_password" --jobs 1; then
        err "OTA update failed. Device may still be booting. Try again in a moment:
  iotstack update $device"
      fi

      # Wait for device to reboot and appear with correct firmware name
      info "OTA update complete! Waiting for device to reboot..."
      # Extract product name from device name (everything before the MAC suffix)
      local product_name="${device%-*}"
      local max_reboot_wait=45
      local reboot_waited=0
      local rebooted=false

      while [[ $reboot_waited -lt $max_reboot_wait ]]; do
        if avahi-browse -t -r _esphomelib._tcp 2>/dev/null | grep -Fqi "${product_name}-${device_mac}"; then
          rebooted=true
          ok "Device rebooted successfully as $product_name-$device_mac"
          break
        fi

        sleep 1
        reboot_waited=$((reboot_waited + 1))

        if (( reboot_waited % 10 == 0 )); then
          info "  Still rebooting... ($reboot_waited/$max_reboot_wait seconds)"
        fi
      done

      if [[ "$rebooted" != "true" ]]; then
        warn "Device did not appear as $product_name-$device_mac after $max_reboot_wait seconds."
        warn "It may still be booting. Check with: iotstack list devices"
      fi
    fi

    ok "Production firmware setup complete!"
    return
  fi

  # No TTY specified: flash command requires serial device
  err "Serial device required for flash command.
Usage: iotstack flash $device /dev/ttyUSB0

Note: Use 'iotstack update $device' for OTA flashing to devices already on network"
}

# ── Main ─────────────────────────────────────────────────────────────────────


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

cmd_commission() {
  # Commission a Matter device via QR code image
  # Usage: iotstack commission <path-to-qr-image.jpg>
  local qr_image="${1:-}"

  [[ -z "$qr_image" ]] && err "Usage: iotstack commission <path-to-qr-image>"
  [[ ! -f "$qr_image" ]] && err "QR code image not found: $qr_image"

  local matter_script="${SCRIPT_DIR}/scripts/matter-commission.sh"
  [[ ! -f "$matter_script" ]] && err "Matter commission script not found: $matter_script"

  "$matter_script" "$qr_image"
}

help_commission() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-commission.txt"
}

cmd_clean() {
  # Clean build artifacts and compilation caches
  info "Cleaning build artifacts..."

  # List of directories/files to clean
  local items_to_clean=(
    "${YAMLS_DIR}/.esphome/build"
    "${HOME}/.platformio/.cache"
    "${COMPILATION_CACHE}"
  )

  local cleaned_count=0

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

  # Clean old logs (keep last 7 days)
  if [[ -d "${HOME}/.iotstack/logs" ]]; then
    info "Cleaning old logs (keeping last 7 days)..."
    find "${HOME}/.iotstack/logs" -type f -mtime +7 -delete
  fi

  # Clean temp files
  if [[ -d "${HOME}/.iotstack/artifacts" ]]; then
    info "Removing temporary files..."
    rm -rf "${HOME}/.iotstack/artifacts"/*
  fi

  ok "Clean complete. Removed $cleaned_count item(s)"
  ok "Ready for next compilation"
}

help_clean() {
  cat "${SCRIPT_DIR}/docs/help/iotstack-clean.txt"
}

main() {
  # Parse global flags (-v/--verbose, -q/--quiet, -env=filename)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      -q|--quiet)
        QUIET=1
        shift
        ;;
      -env=*)
        # Override environment file: -env=pangolin.env
        ENV_FILE="${HOME}/.iotstack/${1#-env=}"
        shift
        ;;
      *)
        break
        ;;
    esac
  done

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

  # Sync common secrets silently at startup
  local command="${1:-help}"

  # Only verify WiFi credentials if it's an actual operation (not help)
  if [[ "${2:-}" != "help" ]]; then
    case "$command" in
      update|reassign|flash)
        # Check WiFi credentials exist, prompt if missing (needed for device flashing)
        verify_wifi_credentials
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
    reassign)
      shift
      cmd_reassign "$@"
      ;;
    list)
      shift
      cmd_list "$@"
      ;;
    devices)
      shift
      cmd_list devices "$@"
      ;;
    roles)
      shift
      cmd_list roles "$@"
      ;;
    secret)
      shift
      cmd_secret "$@"
      ;;
    rotate-secrets)
      shift
      cmd_rotate_secrets "$@"
      ;;
    flash)
      shift
      cmd_flash "$@"
      ;;
    set-boot)
      shift
      cmd_set_boot "$@"
      ;;
    commission)
      shift
      cmd_commission "$@"
      ;;
    clean)
      shift
      cmd_clean "$@"
      ;;
    query)
      shift
      cmd_query "$@"
      ;;
    help)
      if [[ $# -gt 1 ]]; then
        case "$2" in
          update)           help_update ;;
          verify)           help_verify ;;
          reassign)         help_reassign ;;
          list)             help_list ;;
          devices)          help_devices ;;
          roles)            help_roles ;;
          flash)            help_flash ;;
          set-boot)         cmd_set_boot help ;;
          commission)       help_commission ;;
          clean)            help_clean ;;
          query)            help_query ;;
          secret)           help_secret ;;
          rotate-secrets)   help_rotate_secrets ;;
          *)                err "Unknown command: $2" ;;
        esac
      else
        usage
      fi
      ;;
    *)
      err "Unknown command: $command. Try 'iotstack help'"
      ;;
  esac
}

main "$@"
