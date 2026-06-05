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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPDATE_SCRIPT="${SCRIPT_DIR}/update_devices.sh"
DEVICES_CONF="${SCRIPT_DIR}/iotstack-devices.conf"

# Check if update_devices.sh exists
if [[ ! -f "$UPDATE_SCRIPT" ]]; then
  err "update_devices.sh not found at $UPDATE_SCRIPT"
fi

# ── Device Mapping ─────────────────────────────────────────────────────────────
# Load device mappings from iotstack-devices.conf
declare -A DEVICE_MAP

load_device_mappings() {
  if [[ ! -f "$DEVICES_CONF" ]]; then
    err "iotstack-devices.conf not found at $DEVICES_CONF"
  fi

  while IFS='=' read -r device mapping; do
    # Skip comments and empty lines
    [[ "$device" =~ ^#.*$ ]] && continue
    [[ -z "$device" ]] && continue

    device=$(echo "$device" | xargs)  # trim whitespace
    mapping=$(echo "$mapping" | xargs)

    DEVICE_MAP["$device"]="$mapping"
  done < "$DEVICES_CONF"
}

# Resolve device name to YAML path
# Args: device_name [--thread]
# Returns: yaml file path
resolve_device() {
  local device_name="$1"
  local use_thread="${2:-}"

  if [[ ! -v DEVICE_MAP["$device_name"] ]]; then
    err "Unknown device: $device_name"
  fi

  local mapping="${DEVICE_MAP[$device_name]}"
  local wifi_yaml="${mapping%%:*}"
  local thread_yaml="${mapping##*:}"

  # Decide which variant to use
  if [[ "$use_thread" == "--thread" ]]; then
    if [[ -z "$thread_yaml" ]]; then
      err "Device '$device_name' does not have a Thread variant"
    fi
    echo "$thread_yaml"
  else
    if [[ -z "$wifi_yaml" ]]; then
      err "Device '$device_name' does not have a WiFi variant"
    fi
    echo "$wifi_yaml"
  fi
}

# List available device names
list_device_names() {
  local devices=()
  for device in "${!DEVICE_MAP[@]}"; do
    [[ "$device" != "" ]] && devices+=("$device")
  done

  # Sort and print
  for device in $(printf '%s\n' "${devices[@]}" | sort); do
    echo "$device"
  done
}

load_device_mappings

# ── Subcommands ──────────────────────────────────────────────────────────────

usage() {
  cat << 'EOF'
iotstack — Manage IoT Stack ESPHome Devices

Usage:
  iotstack update [options] [<device>|<yaml>|all] [--thread]
  iotstack verify [<device>|<yaml>|all] [--thread]
  iotstack reassign <MAC1> [MAC2 ...] --rename-from <role> [<device>|<yaml>]
  iotstack list
  iotstack devices
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

  reassign <MAC1> [MAC2 ...] --rename-from <role> [<device>|<yaml>]
    Alias for: iotstack update --reassign <MACs...> --rename-from <role> <device/yaml>
    Two-step process: reassign devices to a different role or rename within role.
    Examples:
      iotstack reassign 8dfcac 0f4df4 --rename-from esp32c6-wifi-bleproxy bleproxy
      iotstack reassign 8dfcac --rename-from esp32c6-wifi-bleproxy wifi/esp32c6-wifi-bleproxy.yaml

  verify [<device>|<yaml>|all]
    Check if devices match the current build hash (no flashing).
    Examples:
      iotstack verify bleproxy
      iotstack verify all
      iotstack verify thread_router --thread

  list
    Show all available device configurations (full paths).

  devices
    Show all available device shortcuts (friendly names).

  help [command]
    Show help for a specific command.

Options:
  --thread               Use Thread variant instead of WiFi (for devices with both)
  --dry-run              Compile and show what would be flashed (no flashing)
  --no-upgrade-delta     Flash all devices regardless of version
  --jobs N               Max concurrent flash jobs (default: 4)
  -v, --verbose          Show compilation output

Examples:
  # Update single device (WiFi default)
  iotstack update bleproxy

  # Update Thread variant
  iotstack update router --thread

  # Update all devices
  iotstack update all

  # Preview without flashing
  iotstack update --dry-run mmwave

  # Verify entire fleet
  iotstack verify all

  # Reassign devices
  iotstack reassign 8dfcac 0f4df4 --rename-from esp32c6-wifi-bleproxy bleproxy

  # Show available device names
  iotstack devices

EOF
}

help_update() {
  cat << 'EOF'
iotstack update — Flash ESPHome devices

Usage:
  iotstack update [options] [<yaml>|all]
  iotstack update --reassign <MACs...> --rename-from <role> <yaml>

Arguments:
  <yaml>     Path to device config (e.g., wifi/esp32c6-wifi-bleproxy.yaml)
  all        Update all device configs in the project

Options:
  --dry-run              Compile and show what would be flashed (no flashing)
  --no-upgrade-delta     Flash all devices regardless of version
  --jobs N               Max concurrent OTA jobs (default: 4)
  -v, --verbose          Show full compilation output

Reassignment Options:
  --reassign <MACs...>   Device MAC suffixes to reassign
  --rename-from <role>   Current role name (e.g., esp32c6-wifi-bleproxy)

Examples:
  # Update a single device type
  iotstack update wifi/esp32c6-wifi-bleproxy.yaml

  # Update everything
  iotstack update all

  # Preview without flashing
  iotstack update --dry-run wifi/esp32c6-wifi-bleproxy.yaml

  # Force flash all devices
  iotstack update --no-upgrade-delta thread/c6-thread-router.yaml

  # Update 8 devices in parallel
  iotstack update --jobs 8 wifi/esp32c6-wifi-mmwave.yaml

  # Reassign two devices
  iotstack update --reassign 8dfcac 0f4df4 \
    --rename-from esp32c6-wifi-bleproxy \
    wifi/esp32c6-wifi-bleproxy.yaml

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
  # Check if all BLE proxies are up-to-date
  iotstack verify wifi/esp32c6-wifi-bleproxy.yaml

  # Check entire fleet
  iotstack verify all

EOF
}

help_list() {
  cat << 'EOF'
iotstack list — Show available device configurations

Usage:
  iotstack list

Shows all YAML files in the project with device information.

EOF
}

list_devices() {
  info "Available device configurations:"
  echo

  found=0
  while IFS= read -r yaml_file; do
    if grep -q '^esphome:' "$yaml_file" 2>/dev/null; then
      role_name=$(grep -A 2 '^substitutions:' "$yaml_file" 2>/dev/null | grep 'role_name:' | sed 's/.*role_name:[[:space:]]*//; s/[[:space:]]*#.*//' | tr -d '"'"'" || echo "unknown")
      role_id=$(grep -A 3 '^substitutions:' "$yaml_file" 2>/dev/null | grep 'role_id:' | sed 's/.*role_id:[[:space:]]*//; s/[[:space:]]*#.*//' | tr -d '"'"'" || echo "unknown")

      printf "  ${GRN}%-40s${RST} role_name: ${DIM}%-30s${RST} id: ${DIM}%s${RST}\n" \
        "$yaml_file" "$role_name" "$role_id"
      found=$((found + 1))
    fi
  done < <(find . -maxdepth 3 -name "*.yaml" -type f | sort)

  if [[ $found -eq 0 ]]; then
    warn "No device configurations found"
  else
    echo
    ok "Found $found device configuration(s)"
  fi
}

# ── Command Handlers ─────────────────────────────────────────────────────────

cmd_update() {
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
  local rename_from_role=""
  local device_or_yaml=""
  local use_thread=""
  declare -a reassign_macs=()
  declare -a update_args=()

  # Parse arguments: <MAC1> [MAC2 ...] --rename-from <role> [<device>|<yaml>]
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rename-from)
        shift
        if [[ $# -eq 0 ]]; then
          err "--rename-from requires a role name"
        fi
        rename_from_role="$1"
        shift
        ;;
      --thread)
        use_thread="--thread"
        shift
        ;;
      --dry-run|--verbose|-v|--jobs)
        update_args+=("$1")
        if [[ "$1" == "--jobs" ]]; then
          shift
          update_args+=("$1")
        fi
        shift
        ;;
      *)
        # If we don't have rename_from yet, collect MACs
        if [[ -z "$rename_from_role" ]]; then
          reassign_macs+=("$1")
        else
          # Once we have rename_from, rest is device/yaml
          if [[ -z "$device_or_yaml" ]]; then
            device_or_yaml="$1"
          fi
        fi
        shift
        ;;
    esac
  done

  if [[ ${#reassign_macs[@]} -eq 0 ]] || [[ -z "$rename_from_role" ]]; then
    err "Usage: iotstack reassign <MAC1> [MAC2 ...] --rename-from <role> [<device>|<yaml>]"
  fi

  # If no device/yaml specified, try to infer from rename_from_role
  if [[ -z "$device_or_yaml" ]]; then
    err "Please specify a device or YAML file to reassign to"
  fi

  # Resolve device name to YAML if needed
  local yaml_file
  if [[ -f "$device_or_yaml" ]]; then
    yaml_file="$device_or_yaml"
  else
    yaml_file=$(resolve_device "$device_or_yaml" "$use_thread")
  fi

  info "Reassigning devices..."
  echo "  MACs: ${reassign_macs[*]}"
  echo "  From: $rename_from_role"
  echo "  To:   $yaml_file"
  echo

  # Build and invoke update_devices.sh with reassign flags
  "$UPDATE_SCRIPT" --reassign "${reassign_macs[@]}" --rename-from "$rename_from_role" "${update_args[@]}" "$yaml_file"
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

cmd_devices() {
  info "Available device shortcuts:"
  echo
  list_device_names | while read -r device; do
    mapping="${DEVICE_MAP[$device]}"
    wifi_yaml="${mapping%%:*}"
    thread_yaml="${mapping##*:}"

    printf "  ${GRN}%-15s${RST}" "$device"
    if [[ -n "$wifi_yaml" ]]; then
      printf " (wifi: %s)" "$wifi_yaml"
    fi
    if [[ -n "$thread_yaml" ]]; then
      printf " (thread: %s)" "$thread_yaml"
    fi
    echo
  done
  echo
  ok "Use 'iotstack help' for more information"
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
      list_devices
      ;;
    devices)
      cmd_devices
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
