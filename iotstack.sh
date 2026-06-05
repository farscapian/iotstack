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

# Check if update_devices.sh exists
if [[ ! -f "$UPDATE_SCRIPT" ]]; then
  err "update_devices.sh not found at $UPDATE_SCRIPT"
fi

# ── Subcommands ──────────────────────────────────────────────────────────────

usage() {
  cat << 'EOF'
iotstack — Manage IoT Stack ESPHome Devices

Usage:
  iotstack update [options] [<yaml>|all]
  iotstack verify [<yaml>|all]
  iotstack list
  iotstack help [command]

Commands:

  update [<yaml>|all]
    Compile and flash device(s) over-the-air (OTA).
    - Detects devices on network automatically
    - Only flashes devices that need updates (delta mode)
    Examples:
      iotstack update wifi/esp32c6-wifi-bleproxy.yaml
      iotstack update all
      iotstack update --dry-run wifi/esp32c6-wifi-mmwave.yaml

  update --reassign <MAC1> [MAC2 ...] --rename-from <old_role> <yaml>
    Two-step process: reassign devices to a different role or rename within role.
    Example:
      iotstack update --reassign 8dfcac 0f4df4 \
        --rename-from esp32c6-wifi-bleproxy \
        wifi/esp32c6-wifi-bleproxy.yaml

  verify [<yaml>|all]
    Check if devices match the current build hash (no flashing).
    Examples:
      iotstack verify wifi/esp32c6-wifi-bleproxy.yaml
      iotstack verify all

  list
    Show all available device configurations.

  help [command]
    Show help for a specific command.

Update Options (used with 'update'):
  --dry-run              Show what would be flashed without flashing
  --no-upgrade-delta     Flash all devices even if already up-to-date
  --jobs N               Max concurrent flash jobs (default: 4)
  -v, --verbose          Show compilation output

Examples:
  # Update all BLE proxies
  iotstack update wifi/esp32c6-wifi-bleproxy.yaml

  # Update everything
  iotstack update all

  # Preview updates without flashing
  iotstack update --dry-run wifi/esp32c6-wifi-bleproxy.yaml

  # Verify entire fleet is up-to-date
  iotstack verify all

  # Reassign specific devices to a new role
  iotstack update --reassign 8dfcac 0f4df4 \
    --rename-from esp32c6-wifi-bleproxy \
    wifi/esp32c6-wifi-bleproxy.yaml

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
  local yaml_file=""
  local reassign_mode=false
  declare -a reassign_macs=()
  local rename_from_role=""
  declare -a update_args=()

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reassign)
        reassign_mode=true
        shift
        # Collect MAC suffixes
        while [[ $# -gt 0 ]] && [[ "$1" != --* ]] && [[ "$1" != */* ]]; do
          reassign_macs+=("$1")
          shift
        done
        ;;
      --rename-from)
        shift
        if [[ $# -eq 0 ]]; then
          err "--rename-from requires a role name"
        fi
        rename_from_role="$1"
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
        yaml_file="all"
        shift
        ;;
      *)
        if [[ -z "$yaml_file" ]]; then
          yaml_file="$1"
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$yaml_file" ]]; then
    err "Usage: iotstack update [options] [<yaml>|all]"
  fi

  # Handle reassign mode
  if [[ "$reassign_mode" == true ]]; then
    if [[ ${#reassign_macs[@]} -eq 0 ]] || [[ -z "$rename_from_role" ]]; then
      err "Usage: iotstack update --reassign <MACs...> --rename-from <role> <yaml>"
    fi

    if [[ ! -f "$yaml_file" ]]; then
      err "File not found: $yaml_file"
    fi

    info "Reassigning devices..."
    echo "  MACs: ${reassign_macs[*]}"
    echo "  From: $rename_from_role"
    echo "  To:   $yaml_file"
    echo

    # Build and invoke update_devices.sh with reassign flags
    "$UPDATE_SCRIPT" --reassign "${reassign_macs[@]}" --rename-from "$rename_from_role" "${update_args[@]}" "$yaml_file"
    return $?
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

cmd_verify() {
  local yaml_file="${1:-}"

  if [[ -z "$yaml_file" ]]; then
    err "Usage: iotstack verify [<yaml>|all]"
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
    list)
      list_devices
      ;;
    help)
      if [[ $# -gt 1 ]]; then
        case "$2" in
          update)  help_update ;;
          verify)  help_verify ;;
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
