#!/bin/bash
# iotstack.sh — CLI tool for managing IoT Stack ESPHome devices
# Wrapper around update_devices.sh with a cleaner interface

set -euo pipefail

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

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
UPDATE_SCRIPT="${SCRIPT_DIR}/update_devices.sh"
YAMLS_DIR="${SCRIPT_DIR}/yamls"

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

# Set up cleanup on shell exit
cleanup_secrets_on_exit() {
  local secrets_mount="${HOME}/.iotstack/secrets"
  if mount | grep -q "tmpfs.*${secrets_mount}"; then
    echo "[INFO] Unmounting secrets on logout..."
    sudo umount "$secrets_mount" 2>/dev/null || true
  fi
}

# Register cleanup trap
trap cleanup_secrets_on_exit EXIT

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

# List available role names (YAML filenames without extension)
list_device_names() {
  for yaml_file in "$YAMLS_DIR"/*.yaml; do
    if [[ -f "$yaml_file" ]]; then
      basename "$yaml_file" .yaml
    fi
  done | sort
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
  declare -a job_commands=()

  for i in "${!commands[@]}"; do
    # Wait for a slot to free up
    while [[ $slot_count -ge $max_jobs ]]; do
      wait -n 2>/dev/null || true
      slot_count=$((slot_count - 1))
    done

    # Start job in background
    local cmd="${commands[$i]}"
    eval "$cmd" &
    job_pids[$i]=$!
    slot_count=$((slot_count + 1))
  done

  # Wait for all remaining jobs
  job_results=()
  for i in "${!job_pids[@]}"; do
    local pid="${job_pids[$i]}"
    wait "$pid" 2>/dev/null
    job_results[$i]=$?
  done
}

# ── Subcommands ──────────────────────────────────────────────────────────────

usage() {
  cat << 'EOF'
iotstack — Manage IoT Stack ESPHome Devices

Usage:
  iotstack update [options] [<device>|<yaml>|all] [--thread]
  iotstack verify [<device>|<yaml>|all] [--thread]
  iotstack reassign <MAC1> [MAC2 ...] <device|yaml> [--ota-password PASSWORD]
  iotstack flash <device|yaml> [tty-device]
  iotstack list [devices|roles]
  iotstack secret get <role> <ota|api> [version]
  iotstack secret set <role> <ota|api> <value>
  iotstack rotate-password <role> [new-password]
  iotstack help [command]

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

  secret set <role> <ota|api> <value>
    Set a secret (auto-versions old value).
    Examples:
      iotstack secret set bleproxy ota "newPassword"
      iotstack secret set mmwave api "newApiKey"

  rotate-password <role> [new-password]
    Rotate OTA password for all devices in a role.
    Keeps historical passwords for recovery and audit trails.
    If password not provided, generates a cryptographically secure one.
    Examples:
      iotstack rotate-password bleproxy                    # Generate strong password
      iotstack rotate-password bleproxy "newPassword123"   # Use specific password

  help [command]
    Show help for a specific command.

Options:
  --thread               Use Thread variant instead of WiFi (for devices with both)
  --dry-run              Compile and show what would be flashed (no flashing)
  --no-upgrade-delta     Flash all devices regardless of version
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

Arguments:
  <device>   Device role (e.g., bleproxy, mmwave)
  <yaml>     Path to device config (e.g., yamls/bleproxy.yaml)
  all        Update all device configs in the project

Options:
  --thread               Use Thread variant instead of WiFi
  --dry-run              Compile and show what would be flashed (no flashing)
  --force-reflash        Flash all devices regardless of version
  --jobs N               Max concurrent OTA jobs (default: 4)
  -v, --verbose          Show full compilation output

Examples:
  iotstack update bleproxy                   # Update WiFi device
  iotstack update threadrouter --thread      # Update Thread device
  iotstack update all                        # Update all devices
  iotstack update --dry-run mmwave           # Preview without flashing
  iotstack update --force-reflash bleproxy   # Force flash all devices
  iotstack update --jobs 8 bleproxy          # Update 8 devices in parallel

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
  local device_data=$(mktemp)
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
    echo "ID,Device,Friendly Name,Project,Version,Hash"
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
      echo "$id,$hostname,$friendly,$project,$version,$hash"
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
        [[ "$first" != true ]] && echo ","
        printf '  {"id": "%s", "device": "%s", "friendly_name": "%s", "project": "%s", "version": "%s", "hash": "%s"}' \
          "$id" "$hostname" "$friendly" "$project" "$version" "$hash"
        first=false
      done < "${device_data}.sorted"
      echo
      echo "]"
    ) | jq '.'
  else
    # Text format - calculate column widths
    local margin=2
    local header_id="ID"
    local header_device="Device"
    local header_friendly="Friendly Name"
    local header_project="Project"
    local header_version="Version"
    local header_hash="Hash"

    local w_id=$(( ${#header_id} + margin ))
    local w_device=$(( ${#header_device} + margin ))
    local w_friendly=$(( ${#header_friendly} + margin ))
    local w_project=$(( ${#header_project} + margin ))
    local w_version=$(( ${#header_version} + margin ))
    local w_hash=$(( ${#header_hash} + margin ))

    # Scan data to find max widths
    while IFS='|' read -r hostname friendly project version hash; do
      id="${hostname##*-}"
      (( ${#id} + margin > w_id )) && w_id=$(( ${#id} + margin ))
      (( ${#hostname} + margin > w_device )) && w_device=$(( ${#hostname} + margin ))
      (( ${#friendly} + margin > w_friendly )) && w_friendly=$(( ${#friendly} + margin ))
      (( ${#project} + margin > w_project )) && w_project=$(( ${#project} + margin ))
      (( ${#version} + margin > w_version )) && w_version=$(( ${#version} + margin ))
      (( ${#hash} + margin > w_hash )) && w_hash=$(( ${#hash} + margin ))
    done < "${device_data}.sorted"

    info "Discovered ESPHome devices on network:"
    echo

    # Print headers with calculated widths
    printf "  ${GRN}%-${w_id}s %-${w_device}s %-${w_friendly}s %-${w_project}s %-${w_version}s %-${w_hash}s${RST}\n" \
      "ID" "Device" "Friendly Name" "Project" "Version" "Hash"

    # Print separator
    printf "  ${DIM}"
    printf "%-${w_id}s " "$(printf '─%.0s' $(seq 1 $((w_id-1))))"
    printf "%-${w_device}s " "$(printf '─%.0s' $(seq 1 $((w_device-1))))"
    printf "%-${w_friendly}s " "$(printf '─%.0s' $(seq 1 $((w_friendly-1))))"
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
      printf "  ${GRN}%-${w_id}s${RST} %-${w_device}s %-${w_friendly}s %-${w_project}s %-${w_version}s %-${w_hash}s\n" \
        "$id" "$hostname" "$friendly" "$project" "$version" "$hash"
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
  verify_secrets_mounted

  local device_or_yaml=""
  local use_thread=""
  declare -a update_args=()

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --thread)
        use_thread="--thread"
        shift
        ;;
      --dry-run|--no-upgrade-delta|--verbose|-v|--jobs)
        update_args+=("$1")
        if [[ "$1" == "--jobs" ]]; then
          shift
          update_args+=("$1")
        fi
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
    err "Usage: iotstack update [options] [<device>|<yaml>|all] [--thread]"
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
    while IFS= read -r yaml; do
      if grep -q '^esphome:' "$yaml" 2>/dev/null; then
        role=$(grep -A 2 '^substitutions:' "$yaml" 2>/dev/null | grep 'role_name:' | sed 's/.*role_name:[[:space:]]*//; s/[[:space:]]*#.*//' | tr -d '"'"'" || echo "$(basename "$yaml")")
        echo "────────────────────────────────────────────────────────────"
        info "Updating: $yaml (role: $role)"
        echo "────────────────────────────────────────────────────────────"
        if "$UPDATE_SCRIPT" "${update_args[@]}" "$yaml"; then
          found=$((found + 1))
        else
          failed=$((failed + 1))
        fi
        echo
      fi
    done < <(find . -maxdepth 3 -name "*.yaml" -type f | sort)

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

    info "Updating: $yaml_file"
    "$UPDATE_SCRIPT" "${update_args[@]}" "$yaml_file"
  fi
}

cmd_reassign() {
  verify_secrets_mounted

  local use_thread=""
  local api_key=""
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
    err "Usage: iotstack reassign <MAC1> [MAC2 ...] <device|yaml>"
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

  info "Reassigning devices..."
  echo "  MACs: ${reassign_macs[*]}"
  [[ -n "$api_key" ]] && echo "  OTA Password: $api_key"
  echo

  # Build and invoke update_devices.sh with reassign flags
  if [[ -n "$api_key" ]]; then
    "$UPDATE_SCRIPT" --reassign "${reassign_macs[@]}" "$yaml_file" --ota-password "$api_key" "${update_args[@]}"
  else
    "$UPDATE_SCRIPT" --reassign "${reassign_macs[@]}" "$yaml_file" "${update_args[@]}"
  fi
  return $?
}

cmd_verify() {
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
    err "Usage: iotstack verify [<device>|<yaml>|all] [--thread]"
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

cmd_list() {
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
  local command="$1"
  local role="$2"
  local secret_type="$3"
  local value="${4:-}"

  case "$command" in
    get)
      if [[ -z "$role" || -z "$secret_type" ]]; then
        err "Usage: iotstack secret get <role> <ota|api> [version]"
      fi
      "$SCRIPT_DIR/iotstack-secrets" get "$role" "$secret_type" "$value"
      ;;
    set)
      if [[ -z "$role" || -z "$secret_type" || -z "$value" ]]; then
        err "Usage: iotstack secret set <role> <ota|api> <value>"
      fi
      "$SCRIPT_DIR/iotstack-secrets" set "$role" "$secret_type" "$value"
      ;;
    *)
      err "Unknown secret command: $command. Use 'get' or 'set'"
      ;;
  esac
}

cmd_rotate_password() {
  verify_secrets_mounted

  local role="$1"
  local new_password="${2:-}"

  if [[ -z "$role" ]]; then
    err "Usage: iotstack rotate-password <role> [new-password]"
  fi

  # Verify role exists (check if YAML file exists)
  if [[ ! -f "${YAMLS_DIR}/${role}.yaml" ]]; then
    err "Unknown role: $role (expected: ${YAMLS_DIR}/${role}.yaml)"
  fi

  info "Rotating OTA password for role: $role"
  echo

  # Get current OTA password from password manager or prompt
  local current_password
  echo "[INFO] Retrieving current OTA password from password manager..."
  current_password=$(cmd_secret get "$role" ota 2>/dev/null) || {
    warn "Could not retrieve password from password manager"
    read -p "Enter current OTA password for '$role': " -rs current_password
    echo
  }

  if [[ -z "$current_password" ]]; then
    err "Current password is required"
  fi

  # If no new password provided, generate a cryptographically secure one
  if [[ -z "$new_password" ]]; then
    echo "[INFO] Generating cryptographically secure password..."
    # Generate 32 bytes of random data, encode as base64, remove padding/special chars for compatibility
    new_password=$(openssl rand -base64 32 | tr -d '=+/' | cut -c1-32)
    echo "[OK] Generated password (32 chars): $new_password"
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
  read -p "Proceed with password rotation for ${#mac_suffixes[@]} device(s)? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    info "Password rotation cancelled"
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
  echo "[INFO] Rotation Summary"
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

    echo "[INFO] Updating password manager with versioned password..."
    cmd_secret set "$role" ota "$new_password"

    echo
    ok "Password rotation complete!"
  else
    warn "Password rotation incomplete due to failures"
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
    local temp_data=$(mktemp)
    trap "rm -f $temp_data" RETURN

    # Gather role data into temp file
    list_device_names | while read -r device; do
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
    done

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
cmd_flash() {
  local device="$1"
  local tty_device="${2:-}"

  if [[ -z "$device" ]]; then
    err "Usage: iotstack flash <role|yaml> [tty-device]
Examples:
  iotstack flash bleproxy                    # auto-detect if only one device
  iotstack flash bleproxy /dev/ttyACM0       # specify device
  iotstack flash yamls/mmwave.yaml /dev/ttyUSB0"
  fi

  # If no device specified, auto-detect
  if [[ -z "$tty_device" ]]; then
    # Find all USB serial devices
    local tty_devices=()
    for dev in /dev/ttyACM* /dev/ttyUSB*; do
      if [[ -e "$dev" ]]; then
        tty_devices+=("$dev")
      fi
    done 2>/dev/null

    if [[ ${#tty_devices[@]} -eq 0 ]]; then
      err "No USB serial devices found. Plug in the device and try again, or specify manually:
  iotstack flash $device /dev/ttyACM0"
    elif [[ ${#tty_devices[@]} -gt 1 ]]; then
      err "Multiple USB serial devices found:
$(printf '  %s\n' "${tty_devices[@]}")
Please specify which one:
  iotstack flash $device ${tty_devices[0]}"
    else
      tty_device="${tty_devices[0]}"
    fi
  fi

  # Resolve device role to YAML path
  local yaml_path
  yaml_path=$(resolve_device "$device")

  # Verify TTY device exists
  if [[ ! -e "$tty_device" ]]; then
    err "TTY device not found: $tty_device"
  fi

  echo "[INFO] Flashing to: $tty_device"
  echo "[INFO] Configuration: $yaml_path"
  echo ""

  # Use esphome to flash via serial
  esphome run "$yaml_path" --device "$tty_device"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
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
    rotate-password)
      shift
      cmd_rotate_password "$@"
      ;;
    flash)
      shift
      cmd_flash "$@"
      ;;
    help)
      if [[ $# -gt 1 ]]; then
        case "$2" in
          update)  help_update ;;
          verify)  help_verify ;;
          reassign) help_update ;; # reassign uses same help as update
          list)    help_list ;;
          *)       err "Unknown command: $2" ;;
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
