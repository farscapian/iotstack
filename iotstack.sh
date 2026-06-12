#!/bin/bash
# iotstack.sh — CLI tool for managing IoT Stack ESPHome devices
# Wrapper around update_devices.sh with a cleaner interface
#
# Each invocation runs in an isolated git worktree to prevent code changes
# from affecting running commands.

set -euo pipefail

# Global configuration
VERBOSE=0

# Colors
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLU='\033[0;34m'
DIM='\033[2m'
RST='\033[0m'

err()  { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }
ok()   { echo -e "${GRN}[OK]${RST} $*"; }
warn() { echo -e "${YLW}[WARN]${RST} $*"; }
info() { echo -e "${BLU}[INFO]${RST} $*"; }
debug() { [[ $VERBOSE -eq 1 ]] && echo -e "${DIM}[DEBUG]${RST} $*" || true; }

# ── Compilation Cache ────────────────────────────────────────────────────────

_get_yaml_sha() {
  # Get SHA256 of YAML file
  local yaml_file="$1"
  [[ -f "$yaml_file" ]] && sha256sum "$yaml_file" | awk '{print $1}' || echo ""
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
  local yaml_name=$(basename "$yaml_file")
  local yaml_sha=$(_get_yaml_sha "$yaml_file")

  [[ ! -f "$COMPILATION_CACHE" ]] && return 1

  # Look for matching YAML name and SHA in cache
  grep "^${yaml_name},${yaml_sha}," "$COMPILATION_CACHE" >/dev/null 2>&1
  return $?
}

_update_compilation_cache() {
  # Record compilation result in cache
  local yaml_file="$1"
  local binary_sha="$2"
  local yaml_name=$(basename "$yaml_file")
  local yaml_sha=$(_get_yaml_sha "$yaml_file")

  echo "${yaml_name},${yaml_sha},${binary_sha}" >> "$COMPILATION_CACHE"
}

_check_serial_port_in_use() {
  # Check if serial port is already open by screen, minicom, picocom, or other tools
  local tty_device="$1"

  # Try lsof first (most reliable)
  if command -v lsof &>/dev/null; then
    local processes
    processes=$(lsof "$tty_device" 2>/dev/null | tail -n +2)  # Skip header
    if [[ -n "$processes" ]]; then
      # Extract PID and command for better error message
      local pid=$(echo "$processes" | awk '{print $2}' | head -1)
      local cmd=$(echo "$processes" | awk '{print $1}' | head -1)

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

smart_compile() {
  # Smart compilation that uses cache to skip rebuilds
  # Usage: smart_compile <yaml_file> [device_name_for_logging]
  local yaml_file="$1"
  local device_name="${2:-unknown}"

  # Get YAML SHA before compilation
  local yaml_sha=$(_get_yaml_sha "$yaml_file")
  [[ -z "$yaml_sha" ]] && err "Failed to compute SHA256 of $yaml_file"

  # Check if we can skip compilation
  if _check_compilation_cache "$yaml_file"; then
    ok "Firmware already compiled (cached)"
    return 0
  fi

  # YAML changed or first compile - need to rebuild
  info "Compiling firmware..."
  if [[ $VERBOSE -eq 1 ]]; then
    esphome compile "$yaml_file" || return 1
  else
    esphome compile "$yaml_file" >/dev/null 2>&1 || return 1
  fi

  # Get binary SHA after successful compilation
  local binary_sha=$(_get_binary_sha "$device_name")
  if [[ -n "$binary_sha" ]]; then
    _update_compilation_cache "$yaml_file" "$binary_sha"
    ok "Compilation cached"
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
UPDATE_SCRIPT="${SCRIPT_DIR}/update_devices.sh"
YAMLS_DIR="${SCRIPT_DIR}/yamls"

# Compilation cache
COMPILATION_CACHE="${HOME}/.iotstack/compilation-cache.csv"
mkdir -p "$(dirname "$COMPILATION_CACHE")"

# ── Worktree Isolation ────────────────────────────────────────────────────────
# Each iotstack invocation gets its own isolated worktree to prevent code
# changes from affecting running commands.

_setup_worktree() {
  local worktree_dir="${SCRIPT_DIR}/.git/worktrees/iotstack-$$"

  # Create and enter worktree
  cd "$SCRIPT_DIR"
  git worktree add --no-checkout "$worktree_dir" HEAD 2>/dev/null || return 0

  # Re-exec in worktree
  cd "$worktree_dir"
  export IOTSTACK_WORKTREE="$worktree_dir"
  exec bash "$SCRIPT_PATH" "$@"
}

_cleanup_worktree() {
  if [[ -n "${IOTSTACK_WORKTREE:-}" ]]; then
    cd "$SCRIPT_DIR" 2>/dev/null || return 0
    git worktree remove "$IOTSTACK_WORKTREE" --force 2>/dev/null || true
  fi
}

# Create isolated worktree for this invocation
if [[ -z "${IOTSTACK_WORKTREE:-}" ]]; then
  trap _cleanup_worktree EXIT
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

# ── Security: Auto-mount encrypted secrets if needed ──────────────────────
# Secrets must be in user-land encrypted FUSE mount (gocryptfs)
verify_secrets_mounted() {
  local secrets_mount="${HOME}/.iotstack/secrets"

  # Check if tmpfs mount exists
  if mount | grep -q "tmpfs.*${secrets_mount}"; then
    return 0
  fi

  # Not mounted - auto-mount (will prompt for sudo)
  echo "[INFO] Mounting secrets tmpfs (requires sudo)..."
  if ! "$SCRIPT_DIR/scripts/mount-secrets"; then
    err "Failed to mount secrets tmpfs"
  fi
}

# Note: tmpfs persists for the entire session until manual unmount or reboot
# Users can unmount manually: sudo umount ~/.iotstack/secrets

# ── Dynamic Role Discovery ──────────────────────────────────────────────────
# Roles are discovered from YAML filenames in yamls/ directory
# File: yamls/bleproxy.yaml → Role: bleproxy

# Resolve role name to YAML path
# If given "bleproxy", returns "yamls/bleproxy.yaml"
resolve_device() {
  local role_name="$1"
  local yaml_file="${YAMLS_DIR}/${role_name}.yaml"

  if [[ ! -f "$yaml_file" ]]; then
    err "Unknown role: $role_name (expected: $yaml_file)"
  fi

  echo "$yaml_file"
}

# Extract device_type and network_type from YAML file
# Returns: "device_type|network_type" (e.g., "esp32c6|wifi")
get_yaml_device_info() {
  local yaml_file="$1"
  local device_type=""
  local network_type=""

  if [[ -f "$yaml_file" ]]; then
    # Extract device_type from variant field
    device_type=$(grep -E "^\s*variant:\s*" "$yaml_file" | head -1 | sed 's/.*variant:\s*//; s/\s*$//')

    # Determine network_type from presence of wifi or openthread sections
    if grep -q "^wifi:" "$yaml_file" 2>/dev/null; then
      network_type="wifi"
    elif grep -q "^openthread:" "$yaml_file" 2>/dev/null; then
      network_type="thread"
    fi
  fi

  echo "${device_type}|${network_type}"
}

# List available role names (YAML filenames without extension, excluding secrets.yaml)
list_device_names() {
  for yaml_file in "$YAMLS_DIR"/*.yaml; do
    if [[ -f "$yaml_file" ]]; then
      local basename_only=$(basename "$yaml_file" .yaml)
      # Skip secrets.yaml (not a device role)
      [[ "$basename_only" == "secrets" ]] && continue
      echo "$basename_only"
    fi
  done | sort
}

# Query Home Assistant for device areas via WebSocket
# Returns JSON with device_name -> area_name mapping
get_ha_device_areas() {
  local secrets_yaml="$YAMLS_DIR/secrets.yaml"

  # Try to get HA credentials from pass/secrets
  local ha_token=""
  local ha_url=""

  if [[ -f "$secrets_yaml" ]]; then
    ha_token=$(grep "^ha_token:" "$secrets_yaml" | cut -d'"' -f2 | xargs)
    ha_url=$(grep "^ha_url:" "$secrets_yaml" | cut -d'"' -f2 | xargs)
  fi

  # Fallback to pass store
  if [[ -z "$ha_token" ]] || [[ -z "$ha_url" ]]; then
    ha_token=$(pass show "iotstack/common/ha_token" 2>/dev/null | xargs || echo "")
    ha_url=$(pass show "iotstack/common/ha_url" 2>/dev/null | xargs || echo "")
  fi

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
  cat << 'EOF'
iotstack — Manage IoT Stack ESPHome Devices

Global Options:
  -v, --verbose       Show all output (compiler, flashing, diagnostics)

Usage:
  iotstack [-v|--verbose] <command> [options]
  iotstack update [options] [<device>|<yaml>|all] [--thread]
  iotstack verify [<device>|<yaml>|all] [--thread]
  iotstack reassign <MAC1> [MAC2 ...] <device|yaml> [--ota-password PASSWORD]
  iotstack flash <device|yaml> [tty-device]
  iotstack set-boot <device> <recovery|production>
  iotstack commission <path-to-qr-image>
  iotstack list [devices|roles]
  iotstack secret get <role> <ota|api> [version]
  iotstack rotate-secrets <role> [new-password]
  iotstack help [command]

Examples:
  iotstack -v flash bleproxy /dev/ttyACM0    # Flash with verbose output
  iotstack --verbose update all              # Update all devices, show details

Commands:

  update [<device>|<yaml>|all]
    Compile and flash device(s) over-the-air (OTA).
    - Detects devices on network automatically
    - Only flashes devices that need updates (delta mode)
    Examples:
      iotstack update bleproxy              # update WiFi variant (default)
      iotstack update bleproxy --thread     # update Thread variant
      iotstack update all
      iotstack update --dry-run mmwave

  reassign <MAC1> [MAC2 ...] <device|yaml>
    Flash specific devices to a different configuration.
    Options:
      --ota-password <password>    Use specific OTA password for device authentication
    Examples:
      iotstack reassign 8dfcac 0f4df4 bleproxy
      iotstack reassign 11cdc4 threadrouter --ota-password "kOKuNAPXcbSdYch5AJFtrcoZPr3RyljAkN5Yu9n9oA"
      iotstack reassign 8dfcac yamls/mmwave.yaml

  verify [<device>|<yaml>|all]
    Check if devices match the current build hash (no flashing).
    Examples:
      iotstack verify bleproxy
      iotstack verify all
      iotstack verify thread_router --thread

  flash <device|yaml> [tty-device]
    Flash device via serial/USB (for bricked devices).
    Use when OTA is not available.
    Auto-detects USB device if only one is connected.
    Examples:
      iotstack flash bleproxy                 # auto-detect device
      iotstack flash bleproxy /dev/ttyACM0    # specify device
      iotstack flash mmwave /dev/ttyUSB0
      iotstack flash yamls/custom.yaml

  query [<device-name>|--list]
    Query Home Assistant device and entity registry via WebSocket API.
    Shows all entities (buttons, sensors, etc.) for a device.
    Examples:
      iotstack query --list                          # List all devices in HA
      iotstack query "Bilresa5 - Secondary RoomRemote"
      iotstack query "Kitchen RoomRemote"

  list [devices|roles]
    Show devices and roles.
    Subcommands:
      devices   Show discovered ESPHome devices on network (default)
      roles     Show available device roles with their configurations

  secret get <role> <ota|api> [version]
    Retrieve a secret from encrypted pass store.
    Examples:
      iotstack secret get bleproxy ota              # Current OTA password
      iotstack secret get bleproxy api              # Current API key
      iotstack secret get bleproxy ota 0            # Archived version (v0)

  commission <path-to-qr-image>
    Commission a Matter device via QR code image file.
    - Decodes Matter QR code from JPG/PNG/etc.
    - Commissions device via chip-tool (Thread network)
    - Opens commissioning window and hands off to Home Assistant
    - Requires Thread dataset configured in pass store
    Examples:
      iotstack commission ~/qr-code.jpg
      iotstack commission ~/Downloads/device-qr.png

  rotate-secrets <role> [new-secret]
    Rotate secrets (OTA password and API encryption key) for all devices in a role.
    - OTA password: Always rotated (required for device updates)
    - API key: Only rotated if Home Assistant credentials are configured
    - Keeps historical passwords for recovery and audit trails
    - If secret not provided, generates a cryptographically secure one
    Examples:
      iotstack rotate-secrets bleproxy                    # Generate strong secrets
      iotstack rotate-secrets bleproxy "newSecret123"     # Use specific secret

  help [command]
    Show help for a specific command.

Options:
  --thread               Use Thread variant instead of WiFi (for devices with both)
  --dry-run              Compile and show what would be flashed (no flashing)
  --flash-anyway         Flash all devices regardless of version
  --jobs N               Max concurrent flash jobs (default: 4)
  -v, --verbose          Show compilation output

Examples:
  iotstack update bleproxy                   # Update WiFi device
  iotstack update router --thread            # Update Thread device
  iotstack update all                        # Update all devices
  iotstack update --dry-run mmwave           # Preview without flashing
  iotstack verify all                        # Verify entire fleet
  iotstack reassign 8dfcac 0f4df4 bleproxy                         # Reassign devices
  iotstack reassign 11cdc4 bleproxy --ota-password "ZAD818dH7t..."     # With OTA password
  iotstack list roles                        # Show available roles

EOF
}

help_update() {
  cat << 'EOF'
iotstack update — Flash ESPHome devices

Usage:
  iotstack update [options] [<device>|<yaml>|all] [--thread]
  iotstack update [options] [<MAC1> [MAC2 ...]] <device|yaml> [--thread]

Arguments:
  <device>      Device role (e.g., bleproxy, mmwave)
  <yaml>        Path to device config (e.g., yamls/bleproxy.yaml)
  all           Update all device configs in the project
  <MAC1> [MAC2...]  MAC suffix(es) to update (6 hex digits each)
                    Update only specific devices matching these MACs

Options:
  --thread              Use Thread variant instead of WiFi
  --ota-password <pwd>  OTA password for device authentication
  --dry-run             Compile and show what would be flashed (no flashing)
  --force-reflash       Flash all devices regardless of version
  --jobs N              Max concurrent OTA jobs (default: 4)
  -v, --verbose         Show full compilation output

Examples:
  iotstack update bleproxy                                            # Update all bleproxy devices
  iotstack update threadrouter --thread                               # Update Thread device
  iotstack update all                                                 # Update all devices
  iotstack update --dry-run mmwave                                    # Preview without flashing
  iotstack update --force-reflash bleproxy                            # Force flash all devices
  iotstack update --jobs 8 bleproxy                                   # Update 8 devices in parallel
  iotstack update a1a7b0 8e1aa8 bleproxy                              # Update only specific devices by MAC
  iotstack update 135b60 1a7b00 1af95c threadrouter                   # Update 3 specific Thread devices
  iotstack update bleproxy --ota-password <password>                  # Update with OTA password
  iotstack update a1a7b0 mmwave --ota-password <password>             # Update MAC subset with password

NOTE: Pass OTA password via environment variable to avoid shell history:
  export OTA_PWD=<password>
  iotstack update bleproxy --ota-password \"\$OTA_PWD\"

EOF
}

help_verify() {
  cat << 'EOF'
iotstack verify — Check if devices are up-to-date

Usage:
  iotstack verify [<yaml>|all]

Arguments:
  <yaml>     Path to device config
  all        Verify all device configs

Examples:
  iotstack verify bleproxy                   # Check if devices are up-to-date
  iotstack verify all                        # Check entire fleet

EOF
}

help_list() {
  cat << 'EOF'
iotstack list — Show devices and roles

Usage:
  iotstack list [devices [role|other] [--id]|roles]

Subcommands:
  devices [role]   Show discovered devices (optionally filtered by role)
  devices other    Show devices that don't match any defined role
  roles            Show available device roles with their configurations

Options:
  --id             For devices: output only device IDs (space-separated)

Examples:
  iotstack list devices                      # Show all discovered devices
  iotstack list devices bleproxy             # Show only bleproxy devices
  iotstack list devices other                # Show devices not matching any role
  iotstack list devices --id                 # Output all device IDs
  iotstack list devices bleproxy --id        # Output bleproxy device IDs
  iotstack list devices other --id           # Output IDs of unmatched devices
  iotstack list roles                        # Show available device roles

EOF
}

help_reassign() {
  cat << 'EOF'
iotstack reassign — Flash specific devices to a different configuration

Usage:
  iotstack reassign <MAC1> [MAC2 ...] <device|yaml> [options]

Arguments:
  <MAC1> [MAC2 ...]  MAC suffix(es) to reassign (e.g., 19b164 199ef4)
  <device|yaml>      Target device role or YAML config

Options:
  --ota-password <pwd>              Single OTA password for device authentication
  --ota-password-list-path <file>   File with list of passwords to try (one per line)

Examples:
  iotstack reassign 19b164 bleproxy                                # Reassign to bleproxy role
  iotstack reassign 8dfcac 0f4df4 mmwave                           # Reassign multiple to mmwave
  iotstack reassign 11cdc4 threadrouter                            # Reassign to thread device
  iotstack reassign 19b164 yamls/custom.yaml                       # Reassign to custom YAML
  iotstack reassign 19b164 mmwave --ota-password <password>        # With OTA password
  iotstack reassign 19b164 threadrouter --ota-password-list-path ~/tmp/passwords.txt

PASSWORD LIST FILE FORMAT:
  - One password per line
  - No spaces or quotes
  - Empty lines and lines starting with # are ignored
  - Example (passwords.txt):
    myPassword123
    anotherPassword456
    # Old password, probably not used
    oldPassword789

SECURITY: Pass single password via environment variable to avoid shell history:
  export OTA_PWD=<password>
  iotstack reassign 19b164 mmwave --ota-password \"\$OTA_PWD\"

For password list mode, ensure the file permissions are restrictive:
  chmod 600 ~/tmp/passwords.txt

EOF
}

help_flash() {
  cat << 'EOF'
iotstack flash — Initial device setup with dual-partition recovery

Usage:
  iotstack flash <device> [tty-device] [options]
  iotstack flash recovery [tty-device|role]

Arguments:
  <device>        Device role (e.g., bleproxy, mmwave, threadrouter)
  recovery        Flash recovery image via serial
  [tty-device]    Serial device (e.g., /dev/ttyACM0). Auto-detected if omitted.
  [role]          Production role for dual-flash (e.g., mmwave, bleproxy)

Options:
  --ota-only      Skip recovery flash, only OTA production (device already has recovery)

WORKFLOW:

Fresh Device (brand new, never flashed):
  iotstack flash bleproxy /dev/ttyUSB0
  → Flashes recovery.yaml via serial (dual-partition setup)
  → Waits 15s for device to boot
  → Automatically OTA flashes bleproxy firmware
  → Done! Device ready for production

Existing Device (already has recovery):
  iotstack flash bleproxy /dev/ttyUSB0 --ota-only
  → Skips recovery, just OTA flashes production
  → Faster than full setup

Dual-Flash (recovery + production in one command):
  iotstack flash recovery mmwave
  → Flashes recovery via serial to all USB devices
  → Waits for devices to boot
  → OTA updates all devices to mmwave firmware
  → Done! All devices ready with dual-partition setup

Recovery Only:
  iotstack flash recovery /dev/ttyUSB0
  → Flashes just recovery image via serial
  → Useful for manual recovery partition management

Examples:
  iotstack flash bleproxy /dev/ttyUSB0         # Smart setup (recovery + production)
  iotstack flash recovery mmwave               # Dual-flash: recovery + mmwave
  iotstack flash recovery /dev/ttyUSB0         # Recovery image only
  iotstack flash mmwave /dev/ttyACM0 --ota-only # Skip recovery, update production only
  iotstack flash threadrouter                  # Auto-detect all USB devices

Notes:
  - Fresh device setup: 2-3 minutes total (recovery serial flash + production OTA)
  - Recovery image enables automatic fallback if production firmware fails
  - All devices share the same universal recovery.yaml firmware
  - OTA updates after setup use: iotstack update <device>

EOF
}

help_query() {
  cat << 'EOF'
iotstack query — Query Home Assistant device and entity registry

Usage:
  iotstack query [<device-name>|--list]

Arguments:
  <device-name>  Device name to query (e.g., "Kitchen RoomRemote")
  --list, -l     List all devices in Home Assistant

Examples:
  iotstack query --list                          # List all HA devices
  iotstack query "Bilresa5 - Secondary RoomRemote"
  iotstack query "Kitchen RoomRemote"

Notes:
  - Requires HA_URL and HA_TOKEN in secrets.yaml or pass store
  - Uses WebSocket API (requires websocat)
  - Auto-installs websocat if needed

EOF
}

help_secret() {
  cat << 'EOF'
iotstack secret — Retrieve encrypted secrets from pass store

Usage:
  iotstack secret get <role> <ota|api> [version]

Arguments:
  <role>        Device role (e.g., bleproxy, mmwave)
  <ota|api>     Secret type (OTA password or API key)
  [version]     Version number for historical secrets (default: current)

Examples:
  iotstack secret get bleproxy ota              # Get current OTA password
  iotstack secret get bleproxy api              # Get current API key
  iotstack secret get bleproxy ota 0            # Get archived OTA password v0

To rotate secrets, use:
  iotstack rotate-secrets <role>

Notes:
  - Secrets stored in encrypted pass store
  - Old secrets are archived with version numbers
  - Use rotate-secrets to generate new secrets securely

EOF
}

help_rotate_secrets() {
  cat << 'EOF'
iotstack rotate-secrets — Rotate OTA passwords and API keys

Usage:
  iotstack rotate-secrets <role> [new-secret]

Arguments:
  <role>        Device role to rotate (e.g., bleproxy, mmwave)
  [new-secret]  Specific secret to use. If omitted, generates cryptographically secure one.

Examples:
  iotstack rotate-secrets bleproxy                    # Generate and use random secret
  iotstack rotate-secrets bleproxy "mySecret123"      # Use specific secret
  iotstack rotate-secrets mmwave                      # Rotate mmwave secrets

Features:
  - OTA password: Always rotated (required for device updates)
  - API key: Only rotated if Home Assistant is configured
  - Old secrets: Kept in pass store history for recovery
  - Audit trail: All changes tracked with version numbers

EOF
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
  trap "rm -f $device_data" RETURN

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
    printf "  ${DIM}"
    printf "%-${w_id}s " "$(printf '─%.0s' $(seq 1 $((w_id-1))))"
    printf "%-${w_device}s " "$(printf '─%.0s' $(seq 1 $((w_device-1))))"
    printf "%-${w_friendly}s " "$(printf '─%.0s' $(seq 1 $((w_friendly-1))))"
    printf "%-${w_area}s " "$(printf '─%.0s' $(seq 1 $((w_area-1))))"
    printf "%-${w_project}s " "$(printf '─%.0s' $(seq 1 $((w_project-1))))"
    printf "%-${w_version}s " "$(printf '─%.0s' $(seq 1 $((w_version-1))))"
    printf "%-${w_hash}s" "$(printf '─%.0s' $(seq 1 $((w_hash-1))))"
    printf "${RST}\n"

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
  done < <(find "${SCRIPT_DIR}/yamls" -maxdepth 1 -name "*.yaml" -type f ! -name "secrets.yaml" | sort)

  info "Available device configurations:"
  echo

  # Print headers
  printf "  ${GRN}%-${w_device}s %-${w_type}s %-${w_network}s %-${w_config}s${RST}\n" \
    "$header_device" "$header_type" "$header_network" "$header_config"

  # Print separator
  printf "  ${DIM}"
  printf "%-${w_device}s " "$(printf '─%.0s' $(seq 1 $((w_device-1))))"
  printf "%-${w_type}s " "$(printf '─%.0s' $(seq 1 $((w_type-1))))"
  printf "%-${w_network}s " "$(printf '─%.0s' $(seq 1 $((w_network-1))))"
  printf "%-${w_config}s" "$(printf '─%.0s' $(seq 1 $((w_config-1))))"
  printf "${RST}\n"

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
  done < <(find "${SCRIPT_DIR}/yamls" -maxdepth 1 -name "*.yaml" -type f ! -name "secrets.yaml" | sort)

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

  verify_secrets_mounted

  local device_or_yaml=""
  local use_thread=""
  local ota_password=""
  declare -a update_args=()
  declare -a mac_suffixes=()

  # Parse arguments - collect MACs (6-digit hex), options, and device name
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --thread)
        use_thread="--thread"
        shift
        ;;
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
    yaml_file=$(resolve_device "$device_or_yaml" "$use_thread")
  fi

  # Handle normal update mode
  if [[ "$yaml_file" == "all" ]]; then
    info "Updating all device configurations..."
    echo

    found=0
    failed=0
    # Only compile device roles from iotstack-roles.conf, not random YAML files
    while IFS='=' read -r role rest; do
      # Skip empty lines and comments
      [[ -z "$role" ]] && continue
      [[ "$role" =~ ^[[:space:]]*# ]] && continue

      # Extract WiFi YAML (before colon)
      wifi_yaml="${rest%%:*}"
      thread_yaml="${rest##*:}"

      # Try WiFi variant first, then Thread variant
      for yaml_variant in "$wifi_yaml" "$thread_yaml"; do
        [[ -z "$yaml_variant" ]] && continue

        # yaml_variant already includes the path prefix (e.g., "yamls/bleproxy.yaml")
        yaml="${SCRIPT_DIR}/$yaml_variant"
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
      done
    done < <(cat "${SCRIPT_DIR}/iotstack-roles.conf" 2>/dev/null || echo "")

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

  verify_secrets_mounted

  local use_thread=""
  local api_key=""
  local password_list_file=""
  declare -a update_args=()
  declare -a positional_args=()

  # Separate options from positional arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --thread)
        use_thread="--thread"
        shift
        ;;
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
    yaml_file=$(resolve_device "$device_or_yaml" "$use_thread")
  fi

  # Early sanity check: verify devices aren't already the target role
  local target_role="$device_or_yaml"
  for mac in "${reassign_macs[@]}"; do
    local device_info=$(avahi-browse -t -r _esphomelib._tcp 2>/dev/null | grep -i "$mac" | head -1)
    if [[ -n "$device_info" ]]; then
      local device_name=$(echo "$device_info" | awk -F' ' '{print $4}' | cut -d'.' -f1)
      local current_role=$(echo "$device_name" | sed "s/-$mac\$//")
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
        local device_info=$(avahi-browse -t -r _esphomelib._tcp 2>/dev/null | grep -i "$mac" | head -1)
        if [[ -n "$device_info" ]]; then
          # Extract device name (e.g., "bleproxy-137284" from the line)
          local device_name=$(echo "$device_info" | awk -F' ' '{print $4}' | cut -d'.' -f1)
          # Extract role (everything before the MAC suffix)
          source_role=$(echo "$device_name" | sed "s/-$mac\$//")

          if [[ -n "$source_role" ]]; then
            # If device is running recovery firmware, use well-known recovery password
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
    local log_file="${HOME}/.iotstack/logs/reassign-$(date +%s).log"
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
  local use_thread=""

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --thread)
        use_thread="--thread"
        shift
        ;;
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
    yaml_file=$(resolve_device "$device_or_yaml" "$use_thread")
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
      list_roles "$output_format"
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

  verify_secrets_mounted

  local role="$1"
  local new_password="${2:-}"
  local secrets_yaml="${HOME}/.iotstack/secrets/secrets.yaml"

  if [[ -z "$role" ]]; then
    help_rotate_secrets
    exit 1
  fi

  # Verify role exists (check if YAML file exists)
  if [[ ! -f "${YAMLS_DIR}/${role}.yaml" ]]; then
    err "Unknown role: $role (expected: ${YAMLS_DIR}/${role}.yaml)"
  fi

  # Read HA credentials from secrets.yaml if they exist
  local ha_url=""
  local ha_token=""
  if [[ -f "$secrets_yaml" ]]; then
    ha_url=$(grep '^ha_url:' "$secrets_yaml" | sed 's/ha_url:[[:space:]]*"\?//; s/"\?[[:space:]]*$//' || true)
    ha_token=$(grep '^ha_token:' "$secrets_yaml" | sed 's/ha_token:[[:space:]]*"\?//; s/"\?[[:space:]]*$//' || true)
  fi

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
  current_password=$(cmd_secret get "$role" ota 2>/dev/null) || {
    # Not in pass yet - extract from YAML's secret reference and set it as v00
    echo "[INFO] Not in version history yet - extracting from YAML and setting as v00..."

    # Extract the secret name from YAML (e.g., !secret mmwave_ota_password)
    local secret_name
    secret_name=$(grep -oP '!secret\s+\K\S+(?=\s*$)' "${YAMLS_DIR}/${role}.yaml" | grep ota_password | head -1)

    if [[ -n "$secret_name" ]]; then
      # Look up the value in yamls/secrets.yaml (source file)
      local source_secrets="${YAMLS_DIR}/secrets.yaml"
      if [[ ! -f "$source_secrets" ]]; then
        err "Source secrets file not found: $source_secrets"
      fi

      current_password=$(grep "^${secret_name}:" "$source_secrets" | sed "s/${secret_name}:[[:space:]]*['\"]//; s/['\"][[:space:]]*$//" || true)

      if [[ -z "$current_password" ]]; then
        err "Could not find secret '${secret_name}' in $source_secrets"
      fi

      # Set it in pass as v00 so future rotations have it versioned
      echo "[INFO] Storing current password in pass as v00..."
      "$SCRIPT_DIR/scripts/iotstack-secrets" set "$role" ota "$current_password"
      echo "[OK] Current password extracted and stored in pass"
    else
      err "Could not find OTA password secret in ${role}.yaml"
    fi
  }

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
      # Check if API key is already versioned in pass
      local current_api_key
      current_api_key=$(cmd_secret get "$role" api 2>/dev/null) || {
        # Not versioned yet - extract from YAML and set as v00
        echo "[INFO] API key not in version history - extracting from YAML..."

        # Extract the secret name from YAML (e.g., !secret mmwave_api_encryption_key)
        local api_secret_name
        api_secret_name=$(grep -oP '!secret\s+\K\S+(?=\s*$)' "${YAMLS_DIR}/${role}.yaml" | grep api_encryption_key | head -1)

        if [[ -n "$api_secret_name" ]]; then
          # Look up the value in yamls/secrets.yaml (source file)
          local source_secrets="${YAMLS_DIR}/secrets.yaml"
          current_api_key=$(grep "^${api_secret_name}:" "$source_secrets" | sed "s/${api_secret_name}:[[:space:]]*['\"]//; s/['\"][[:space:]]*$//" || true)

          if [[ -n "$current_api_key" ]]; then
            echo "[INFO] Storing current API key in pass as v00..."
            "$SCRIPT_DIR/scripts/iotstack-secrets" set "$role" api "$current_api_key"
            echo "[OK] Current API key stored in pass"
          fi
        fi
      }

      # Generate and set new API key
      local new_api_key
      echo "[INFO] Generating new API encryption key..."
      new_api_key=$(openssl rand -base64 32)
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

  if [[ "$output_format" == "csv" ]]; then
    echo "Role,Type,Network,Config"
    list_device_names | while read -r device; do
      yaml_file="${YAMLS_DIR}/${device}.yaml"

      if [[ -f "$yaml_file" ]]; then
        device_info=$(get_yaml_device_info "$yaml_file")
        device_type="${device_info%%|*}"
        network_type="${device_info##*|}"
        config_file=$(basename "$yaml_file")
      else
        device_type=""
        network_type=""
        config_file=""
      fi

      echo "$device,$device_type,$network_type,$config_file"
    done
  elif [[ "$output_format" == "json" ]]; then
    echo "["
    first=true
    list_device_names | while read -r device; do
      yaml_file="${YAMLS_DIR}/${device}.yaml"

      if [[ -f "$yaml_file" ]]; then
        device_info=$(get_yaml_device_info "$yaml_file")
        device_type="${device_info%%|*}"
        network_type="${device_info##*|}"
        config_file=$(basename "$yaml_file")
      else
        device_type=""
        network_type=""
        config_file=""
      fi

      [[ "$first" != true ]] && echo ","
      printf '  {"role": "%s", "type": "%s", "network": "%s", "config": "%s"}' \
        "$device" "$device_type" "$network_type" "$config_file"
      first=false
    done
    echo
    echo "]"
  else
    # Text format - gather data first
    local margin=2
    local temp_data
    temp_data=$(mktemp)
    # Capture temp_data in trap by expanding it now (double quotes), not at trap time
    trap "rm -f '$temp_data'" RETURN

    # Gather role data into temp file (using process substitution to avoid subshell)
    while IFS= read -r device; do
      yaml_file="${YAMLS_DIR}/${device}.yaml"

      if [[ -f "$yaml_file" ]]; then
        device_info=$(get_yaml_device_info "$yaml_file")
        device_type="${device_info%%|*}"
        network_type="${device_info##*|}"
        config_display=$(basename "$yaml_file")
      else
        device_type=""
        network_type=""
        config_display=""
      fi

      echo "$device|$device_type|$network_type|$config_display" >> "$temp_data"
    done < <(list_device_names)

    # Calculate column widths
    local header_role="Role"
    local header_type="Type"
    local header_network="Network"
    local header_config="Config"

    local w_role=$(( ${#header_role} + margin ))
    local w_type=$(( ${#header_type} + margin ))
    local w_network=$(( ${#header_network} + margin ))
    local w_config=$(( ${#header_config} + margin ))

    while IFS='|' read -r device device_type network_type config_display; do
      (( ${#device} + margin > w_role )) && w_role=$(( ${#device} + margin ))
      (( ${#device_type} + margin > w_type )) && w_type=$(( ${#device_type} + margin ))
      (( ${#network_type} + margin > w_network )) && w_network=$(( ${#network_type} + margin ))
      (( ${#config_display} + margin > w_config )) && w_config=$(( ${#config_display} + margin ))
    done < "$temp_data"

    info "Available device roles:"
    echo

    # Print headers
    printf "  ${GRN}%-${w_role}s %-${w_type}s %-${w_network}s %-${w_config}s${RST}\n" \
      "$header_role" "$header_type" "$header_network" "$header_config"

    # Print separator
    printf "  ${DIM}"
    printf "%-${w_role}s " "$(printf '─%.0s' $(seq 1 $((w_role-1))))"
    printf "%-${w_type}s " "$(printf '─%.0s' $(seq 1 $((w_type-1))))"
    printf "%-${w_network}s " "$(printf '─%.0s' $(seq 1 $((w_network-1))))"
    printf "%-${w_config}s" "$(printf '─%.0s' $(seq 1 $((w_config-1))))"
    printf "${RST}\n"

    # Print data rows
    while IFS='|' read -r device device_type network_type config_display; do
      printf "  ${GRN}%-${w_role}s${RST} %-${w_type}s %-${w_network}s %-${w_config}s\n" \
        "$device" "$device_type" "$network_type" "$config_display"
    done < "$temp_data"

    echo
    ok "Use 'iotstack help' for more information"
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
Usage: iotstack set-boot <device> <recovery|production>

Set which partition a recovery device boots into.

Arguments:
  <device>      MAC suffix (e.g., 1af95c) OR serial device (e.g., /dev/ttyACM0)
  <partition>   recovery or production

Examples:
  Network device (by MAC):
    iotstack set-boot 1af95c recovery          # Set recovery-1af95c → recovery
    iotstack set-boot 9019c8 production        # Set recovery-9019c8 → production

  USB-connected device:
    iotstack set-boot /dev/ttyACM0 recovery    # Set /dev/ttyACM0 → recovery
    iotstack set-boot /dev/ttyUSB0 production  # Set /dev/ttyUSB0 → production
EOF
    exit 1
  fi

  if [[ ! "$partition" =~ ^(recovery|production)$ ]]; then
    err "Partition must be 'recovery' or 'production'"
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

  # Device must be running recovery firmware for this to work
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

  # Special handling for "recovery" role
  if [[ "$device" == "recovery" ]]; then
    # Check if second arg is a production role (dual-flash mode)
    if [[ -n "$tty_device_or_role" && ! "$tty_device_or_role" =~ ^/dev/ ]]; then
      # Dual-flash: recovery + production role
      local production_role="$tty_device_or_role"
      _flash_recovery_dual "$production_role"
    else
      # Single flash: recovery only
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

  info "Flashing recovery firmware (dual-partition setup)"
  echo ""

  local recovery_yaml="$YAMLS_DIR/recovery.yaml"
  if [[ ! -f "$recovery_yaml" ]]; then
    err "Recovery firmware not found: $recovery_yaml"
  fi

  # If specific TTY device, flash only that one
  if [[ -n "$tty_device" ]]; then
    if [[ ! -e "$tty_device" ]]; then
      err "TTY device not found: $tty_device"
    fi

    # Check if serial port is already in use
    _check_serial_port_in_use "$tty_device"

    info "Flashing to: $tty_device"
    info "Compiling recovery firmware..."
    smart_compile "$recovery_yaml" "recovery" || err "Compilation failed"

    info "Uploading recovery firmware to device..."

    # Erase flash completely to handle devices with incompatible firmware (RCP, etc.)
    info "Erasing flash memory..."
    esptool --chip esp32c6 --port "$tty_device" --baud 9600 erase_flash || err "Erase failed"
    sleep 3  # Wait for erase to complete and device to stabilize

    # Flash generic recovery firmware and capture MAC
    local build_dir="$YAMLS_DIR/.esphome/build/recovery/.pioenvs/recovery"
    [[ ! -d "$build_dir" ]] && err "Build directory not found: $build_dir"

    local esptool_output
    esptool_output=$(esptool --chip esp32c6 --port "$tty_device" --baud 9600 \
      write-flash --flash-mode dio --flash-size 4MB --flash-freq 40m \
      0x0 "$build_dir/bootloader.bin" \
      0x8000 "$build_dir/partitions.bin" \
      0x30000 "$build_dir/firmware.bin" 2>&1) || err "Flash failed"

    # Extract MAC address from esptool output
    local device_mac
    device_mac=$(echo "$esptool_output" | grep "BASE MAC:" | awk '{print $NF}' | sed 's/://g' | tr -d '[:space:]')
    device_mac="${device_mac: -6}"

    [[ -z "$device_mac" || ! "$device_mac" =~ ^[0-9a-f]{6}$ ]] && err "Failed to extract MAC address from device"

    ok "Recovery firmware flashed to: $device_mac"
    echo ""

    # Compute device-specific OTA password from role-based secret
    # sha256(role_secret | device_mac) - never stored, computed in-memory only
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

    local device_specific_ota_password
    device_specific_ota_password=$(echo -n "${recovery_role_password}|${device_mac}" | sha256sum | cut -c1-32)

    # Write device-specific secrets to NVS partition
    # Firmware reads these via custom NVS components
    info "Writing device-specific secrets to NVS..."
    "$SCRIPT_DIR/scripts/write-nvs-secrets.sh" "$tty_device" "$device_mac" "recovery" "$device_specific_ota_password" || \
      err "Failed to write NVS secrets"

    # Verify flash checksums before proceeding
    info "Verifying flash checksums..."
    "$SCRIPT_DIR/scripts/verify-flash.sh" "$tty_device" "recovery" || \
      err "Flash verification failed - device may be corrupted"
    echo ""

    info "Device booting recovery firmware..."
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

  info "Compiling recovery firmware..."
  if [[ $VERBOSE -eq 1 ]]; then
    esphome compile "$recovery_yaml" || err "Compilation failed"
  else
    esphome compile "$recovery_yaml" >/dev/null 2>&1 || err "Compilation failed"
  fi
  ok "Recovery firmware compiled"
  echo ""

  # Flash to all devices sequentially (one at a time)
  local build_dir="$YAMLS_DIR/.esphome/build/recovery/.pioenvs/recovery"
  [[ ! -d "$build_dir" ]] && err "Build directory not found: $build_dir"

  local failed=0
  for tty in "${tty_devices[@]}"; do
    local log_file="/tmp/iotstack-flash-recovery-$(basename "$tty").log"
    echo ""
    info "Flashing $tty (log: $log_file)..."
    echo "════════════════════════════════════════════════════════"

    if esptool --chip esp32c6 --port "$tty" --baud 9600 \
      write-flash --flash-mode dio --flash-size 4MB \
      0x0 "$build_dir/bootloader.bin" \
      0x8000 "$build_dir/partitions.bin" \
      0x30000 "$build_dir/firmware.bin" 2>&1 | tee "$log_file"; then
      ok "Recovery firmware flashed on $tty"
    else
      warn "Recovery flash FAILED on $tty"
      failed=$((failed + 1))
    fi

    echo "════════════════════════════════════════════════════════"
  done

  if [[ $failed -gt 0 ]]; then
    err "Failed to flash recovery to $failed device(s)"
  else
    ok "Recovery firmware flashed to all ${#tty_devices[@]} device(s)"
    echo ""
    info "Devices booting recovery firmware..."
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
    local ha_url=$(pass show iotstack/common/ha_url 2>/dev/null || echo "")
    local ha_token=$(pass show iotstack/common/ha_token 2>/dev/null || echo "")

    if [[ -n "$ha_url" && -n "$ha_token" ]]; then
      # Call the partition toggle button via Home Assistant
      for mac in "${recovery_devices[@]}"; do
        local device_name="recovery-$mac"
        local entity_id="button.${device_name,,}_toggle_boot_partition"

        info "Toggling partition on $device_name (via HA)..."
        curl -s -X POST "$ha_url/api/services/button/press" \
          -H "Authorization: Bearer $ha_token" \
          -H "Content-Type: application/json" \
          -d "{\"entity_id\": \"$entity_id\"}" >/dev/null 2>&1 && \
          ok "  Partition toggled, device rebooting..." || \
          warn "  Could not toggle partition via HA (continuing anyway)"
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
      info "Step 1: Flashing recovery firmware..."
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
      local product_name="${device_role}"
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

sync_common_secrets() {
  # Seed common secrets from secrets.yaml ONLY if pass doesn't have them yet
  # Pass takes precedence: if a value exists in pass, it's never overridden
  # secrets.yaml is only for initial seeding with well-known defaults (e.g., CHANGE_ME)
  local secrets_yaml="$YAMLS_DIR/secrets.yaml"

  [[ ! -f "$secrets_yaml" ]] && return 0

  # Setup pass environment
  export GNUPGHOME="${HOME}/.iotstack/.gnupg"
  export PASSWORD_STORE_DIR="${HOME}/.iotstack/.pass"

  # Seed HA token only if pass doesn't have it yet
  if ! pass show "iotstack/common/ha_token" >/dev/null 2>&1; then
    local ha_token=$(grep "^ha_token:" "$secrets_yaml" 2>/dev/null | cut -d'"' -f2 | xargs || echo "")
    if [[ -n "$ha_token" ]]; then
      { echo "$ha_token"; echo "$ha_token"; } | pass insert -f "iotstack/common/ha_token" 2>&1 >/dev/null || true
    fi
  fi

  # Seed HA URL only if pass doesn't have it yet
  if ! pass show "iotstack/common/ha_url" >/dev/null 2>&1; then
    local ha_url=$(grep "^ha_url:" "$secrets_yaml" 2>/dev/null | cut -d'"' -f2 | xargs || echo "")
    if [[ -n "$ha_url" ]]; then
      { echo "$ha_url"; echo "$ha_url"; } | pass insert -f "iotstack/common/ha_url" 2>&1 >/dev/null || true
    fi
  fi
}

verify_wifi_credentials() {
  # Check if wifi_ssid and wifi_password exist in secrets.yaml
  # If missing, prompt user to provide them
  local secrets_yaml="$YAMLS_DIR/secrets.yaml"

  [[ ! -f "$secrets_yaml" ]] && return 0  # File doesn't exist yet, will be created

  local has_ssid=false
  local has_password=false

  if grep -q "^wifi_ssid:" "$secrets_yaml"; then
    has_ssid=true
  fi

  if grep -q "^wifi_password:" "$secrets_yaml"; then
    has_password=true
  fi

  if [[ "$has_ssid" == false ]] || [[ "$has_password" == false ]]; then
    warn "Missing WiFi credentials in $secrets_yaml"
    echo ""

    if [[ "$has_ssid" == false ]]; then
      read -p "Enter WiFi SSID: " wifi_ssid
      [[ -z "$wifi_ssid" ]] && err "WiFi SSID cannot be empty"
      echo "wifi_ssid: \"$wifi_ssid\"" >> "$secrets_yaml"
    fi

    if [[ "$has_password" == false ]]; then
      read -sp "Enter WiFi password: " wifi_password
      echo ""
      [[ -z "$wifi_password" ]] && err "WiFi password cannot be empty"
      echo "wifi_password: \"$wifi_password\"" >> "$secrets_yaml"
    fi

    ok "WiFi credentials added to $secrets_yaml"
    echo ""
  fi
}

cmd_commission() {
  # Commission a Matter device via QR code image
  # Usage: iotstack commission <path-to-qr-image.jpg>
  local qr_image="${1:-}"

  [[ -z "$qr_image" ]] && err "Usage: iotstack commission <path-to-qr-image>"
  [[ ! -f "$qr_image" ]] && err "QR code image not found: $qr_image"

  verify_secrets_mounted

  local matter_script="${SCRIPT_DIR}/scripts/matter-commission.sh"
  [[ ! -f "$matter_script" ]] && err "Matter commission script not found: $matter_script"

  "$matter_script" "$qr_image"
}

help_commission() {
  cat << 'EOF'
Commission a Matter device via QR code image.

Decodes a Matter QR code from an image file, commissions the device via
chip-tool (Thread), opens a commissioning window, and hands off to Home
Assistant for adoption.

Required secrets (stored in pass):
  iotstack/common/thread_tlv          Thread network TLV data (hex)
  iotstack/common/ha_url              Home Assistant URL
  iotstack/common/ha_token            Home Assistant long-lived token
  iotstack/matter/next_node_id        Auto-increment node ID (auto-initialized)

Set secrets with:
  pass insert iotstack/common/thread_tlv
  pass insert iotstack/common/ha_url
  pass insert iotstack/common/ha_token

Dependencies:
  - zbar-tools (zbarimg): apt install zbar-tools
  - chip-tool: https://github.com/project-chip/connectedhomeip
  - curl, python3

Usage:
  iotstack commission <path-to-qr-image.jpg>

How to use:
  1. Take a photo of the Matter QR code (phone, screenshot, etc.)
  2. Save the image (JPG, PNG, etc.)
  3. Run: iotstack commission /path/to/image.jpg

Examples:
  iotstack commission ~/qr-code.jpg
  iotstack commission ~/Downloads/device-qr.png
  iotstack commission ./matter-qr.jpg
EOF
}

main() {
  # Parse global flags (-v/--verbose)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose)
        VERBOSE=1
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  # Mount secrets store early - needed for all operations
  verify_secrets_mounted

  # Check WiFi credentials exist, prompt if missing
  verify_wifi_credentials

  # Sync common secrets silently at startup
  sync_common_secrets

  local command="${1:-help}"

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
          flash)            help_flash ;;
          set-boot)         cmd_set_boot help ;;
          commission)       help_commission ;;
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
