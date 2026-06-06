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
DEVICES_CONF="${SCRIPT_DIR}/iotstack-roles.conf"

# Check if update_devices.sh exists
if [[ ! -f "$UPDATE_SCRIPT" ]]; then
  err "update_devices.sh not found at $UPDATE_SCRIPT"
fi

# ── Device Mapping ─────────────────────────────────────────────────────────────
# Load device mappings from iotstack-roles.conf
declare -A DEVICE_MAP

load_device_mappings() {
  if [[ ! -f "$DEVICES_CONF" ]]; then
    err "iotstack-roles.conf not found at $DEVICES_CONF"
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

# Resolve role name to YAML path
resolve_device() {
  local role_name="$1"

  if [[ ! -v DEVICE_MAP["$role_name"] ]]; then
    err "Unknown role: $role_name"
  fi

  # Extract the YAML path from the mapping (now just a single path, no variants)
  local mapping="${DEVICE_MAP[$role_name]}"
  # Remove empty colon-separated parts
  local yaml_path="${mapping%:*}"
  [[ -z "$yaml_path" ]] && yaml_path="${mapping#*:}"

  if [[ -z "$yaml_path" ]]; then
    err "Role '$role_name' has no YAML configuration"
  fi

  echo "$yaml_path"
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
  iotstack reassign <MAC1> [MAC2 ...] <device|yaml>
  iotstack list [devices|roles]
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
    Examples:
      iotstack reassign 8dfcac 0f4df4 bleproxy
      iotstack reassign 8dfcac yamls/mmwave.yaml

  verify [<device>|<yaml>|all]
    Check if devices match the current build hash (no flashing).
    Examples:
      iotstack verify bleproxy
      iotstack verify all
      iotstack verify thread_router --thread

  list [devices|roles]
    Show devices and roles.
    Subcommands:
      devices   Show discovered ESPHome devices on network (default)
      roles     Show available device roles with their configurations

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
  iotstack reassign 8dfcac 0f4df4 bleproxy

  # Show available roles
  iotstack list roles

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
  # Update a single device by name (WiFi default)
  iotstack update bleproxy

  # Update Thread variant
  iotstack update threadrouter --thread

  # Update everything
  iotstack update all

  # Preview without flashing
  iotstack update --dry-run mmwave

  # Force flash all devices
  iotstack update --force-reflash bleproxy

  # Update 8 devices in parallel
  iotstack update --jobs 8 bleproxy

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
iotstack list — Show devices and roles

Usage:
  iotstack list [devices|roles]

Subcommands:
  devices   Show discovered ESPHome devices on network (default)
  roles     Show available device roles with their configurations

Examples:
  # Show discovered devices on network (default)
  iotstack list
  iotstack list devices

  # Show available device roles
  iotstack list roles

EOF
}

list_devices() {
  local output_format="${1:-text}"
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
      [[ $line =~ friendly_name=([^ \"]+) ]] && current_friendly="${BASH_REMATCH[1]}"
      [[ $line =~ project_name=([^ \"]+) ]] && current_project="${BASH_REMATCH[1]}"
      [[ $line =~ project_version=([^ \"]+) ]] && current_version="${BASH_REMATCH[1]}"
      [[ $line =~ config_hash=([^ \"]+) ]] && current_hash="${BASH_REMATCH[1]}"

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

  if [[ "$output_format" == "csv" ]]; then
    echo "Device,Friendly Name,Project,Version,Hash"
    while IFS='|' read -r hostname friendly project version hash; do
      echo "$hostname,$friendly,$project,$version,$hash"
    done < "${device_data}.sorted"
  elif [[ "$output_format" == "json" ]]; then
    echo "["
    first=true
    while IFS='|' read -r hostname friendly project version hash; do
      [[ "$first" != true ]] && echo ","
      printf '  {"device": "%s", "friendly_name": "%s", "project": "%s", "version": "%s", "hash": "%s"}' \
        "$hostname" "$friendly" "$project" "$version" "$hash"
      first=false
    done < "${device_data}.sorted"
    echo
    echo "]"
  else
    # Text format
    info "Discovered ESPHome devices on network:"
    echo
    printf "  ${GRN}%-25s %-20s %-20s %-15s %-12s${RST}\n" "Device" "Friendly Name" "Project" "Version" "Hash"
    printf "  ${DIM}%-25s %-20s %-20s %-15s %-12s${RST}\n" "─────────────────────────" "────────────────────" "────────────────────" "───────────────" "────────────"

    local found=0
    while IFS='|' read -r hostname friendly project version hash; do
      printf "  ${GRN}%-25s${RST} %-20s %-20s %-15s %-12s\n" \
        "$hostname" "$friendly" "$project" "$version" "$hash"
      found=$((found + 1))
    done < "${device_data}.sorted"

    echo
    local devices_count=$(wc -l < "${device_data}.sorted")
    if [[ $devices_count -eq 0 ]]; then
      warn "No ESPHome devices found on network"
    else
      ok "Found $devices_count device(s) on network"
    fi
  fi
}

list_yaml_configs() {
  info "Available device configurations:"
  echo
  printf "  ${GRN}%-20s %-10s %-10s %-40s${RST}\n" "Device" "Type" "Network" "Config File"
  printf "  ${DIM}%-20s %-10s %-10s %-40s${RST}\n" "─────────────────" "─────────" "─────────" "───────────────────────────────────────"

  found=0
  while IFS= read -r yaml_file; do
    if grep -q '^esphome:' "$yaml_file" 2>/dev/null; then
      # Extract device info
      device_info=$(get_yaml_device_info "$yaml_file")
      device_type="${device_info%%|*}"
      network_type="${device_info##*|}"

      # Extract friendly_name for display
      friendly_name=$(grep -E "^\s*friendly_name:\s*" "$yaml_file" | head -1 | sed 's/.*friendly_name:\s*"\?\([^"]*\)"\?.*/\1/')
      [[ -z "$friendly_name" ]] && friendly_name=$(basename "$yaml_file" .yaml)

      printf "  ${GRN}%-20s${RST} %-10s %-10s %s\n" \
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
  local use_thread=""
  declare -a update_args=()
  declare -a positional_args=()

  # Separate options from positional arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --thread)
        use_thread="--thread"
        shift
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
  echo

  # Build and invoke update_devices.sh with reassign flags
  "$UPDATE_SCRIPT" --reassign "${reassign_macs[@]}" "$yaml_file" "${update_args[@]}"
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
  local subcommand="devices"

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
      devices|roles)
        subcommand="$1"
        shift
        ;;
      *)
        err "Unknown argument: $1"
        ;;
    esac
  done

  case "$subcommand" in
    devices)
      list_devices "$output_format"
      ;;
    roles)
      list_roles "$output_format"
      ;;
    *)
      err "Unknown subcommand: $subcommand. Try 'iotstack list devices' or 'iotstack list roles'"
      ;;
  esac
}

list_roles() {
  local output_format="${1:-text}"

  if [[ "$output_format" == "csv" ]]; then
    echo "Role,Type,Network,Config"
    list_device_names | while read -r device; do
      mapping="${DEVICE_MAP[$device]}"
      wifi_yaml="${mapping%%:*}"
      thread_yaml="${mapping##*:}"

      device_type=""
      network_type=""
      if [[ -n "$wifi_yaml" && -f "$wifi_yaml" ]]; then
        device_info=$(get_yaml_device_info "$wifi_yaml")
        device_type="${device_info%%|*}"
        network_type="${device_info##*|}"
      elif [[ -n "$thread_yaml" && -f "$thread_yaml" ]]; then
        device_info=$(get_yaml_device_info "$thread_yaml")
        device_type="${device_info%%|*}"
        network_type="${device_info##*|}"
      fi

      config_display=""
      if [[ -n "$wifi_yaml" && -n "$thread_yaml" ]]; then
        config_display="${wifi_yaml##*/} / ${thread_yaml##*/}"
      elif [[ -n "$wifi_yaml" ]]; then
        config_display="${wifi_yaml##*/}"
      elif [[ -n "$thread_yaml" ]]; then
        config_display="${thread_yaml##*/}"
      fi

      echo "$device,$device_type,$network_type,$config_display"
    done
  elif [[ "$output_format" == "json" ]]; then
    echo "["
    first=true
    list_device_names | while read -r device; do
      mapping="${DEVICE_MAP[$device]}"
      wifi_yaml="${mapping%%:*}"
      thread_yaml="${mapping##*:}"

      device_type=""
      network_type=""
      if [[ -n "$wifi_yaml" && -f "$wifi_yaml" ]]; then
        device_info=$(get_yaml_device_info "$wifi_yaml")
        device_type="${device_info%%|*}"
        network_type="${device_info##*|}"
      elif [[ -n "$thread_yaml" && -f "$thread_yaml" ]]; then
        device_info=$(get_yaml_device_info "$thread_yaml")
        device_type="${device_info%%|*}"
        network_type="${device_info##*|}"
      fi

      config_display=""
      if [[ -n "$wifi_yaml" && -n "$thread_yaml" ]]; then
        config_display="${wifi_yaml##*/} / ${thread_yaml##*/}"
      elif [[ -n "$wifi_yaml" ]]; then
        config_display="${wifi_yaml##*/}"
      elif [[ -n "$thread_yaml" ]]; then
        config_display="${thread_yaml##*/}"
      fi

      [[ "$first" != true ]] && echo ","
      printf '  {"role": "%s", "type": "%s", "network": "%s", "config": "%s"}' \
        "$device" "$device_type" "$network_type" "$config_display"
      first=false
    done
    echo
    echo "]"
  else
    # Text format (default)
    info "Available device roles:"
    echo
    printf "  ${GRN}%-15s %-10s %-10s %-40s${RST}\n" "Role" "Type" "Network" "Config"
    printf "  ${DIM}%-15s %-10s %-10s %-40s${RST}\n" "───────────────" "──────────" "──────────" "────────────────────────────────────────"

    list_device_names | while read -r device; do
      mapping="${DEVICE_MAP[$device]}"
      wifi_yaml="${mapping%%:*}"
      thread_yaml="${mapping##*:}"

      device_type=""
      network_type=""
      if [[ -n "$wifi_yaml" && -f "$wifi_yaml" ]]; then
        device_info=$(get_yaml_device_info "$wifi_yaml")
        device_type="${device_info%%|*}"
        network_type="${device_info##*|}"
      elif [[ -n "$thread_yaml" && -f "$thread_yaml" ]]; then
        device_info=$(get_yaml_device_info "$thread_yaml")
        device_type="${device_info%%|*}"
        network_type="${device_info##*|}"
      fi

      config_display=""
      if [[ -n "$wifi_yaml" && -n "$thread_yaml" ]]; then
        config_display="${wifi_yaml##*/} / ${thread_yaml##*/}"
      elif [[ -n "$wifi_yaml" ]]; then
        config_display="${wifi_yaml##*/}"
      elif [[ -n "$thread_yaml" ]]; then
        config_display="${thread_yaml##*/}"
      fi

      printf "  ${GRN}%-15s${RST} %-10s %-10s %-40s\n" \
        "$device" "$device_type" "$network_type" "$config_display"
    done
    echo
    ok "Use 'iotstack help' for more information"
  fi
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
