#!/bin/bash
# failsafe-yaml.sh — Variant-specific failsafe YAML artifacts for iotstack flash
#
# Detects the chip on a serial port (or reads a production role YAML), renders
# yamls/.iotstack-failsafe-<variant>.yaml from yamls/failsafe.yaml, and
# exposes build/flash parameters. Each variant artifact is cached separately in
# compilation-cache.csv (yaml_name=failsafe-esp32c6.yaml, etc.).
#
# Requires config.sh, esp-serial.sh, and yaml-info.sh to be sourced first.

[[ -n "${_FAILSAFE_YAML_LOADED:-}" ]] && return 0
_FAILSAFE_YAML_LOADED=1

_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/esp-serial.sh
[[ -z "${_ESP_SERIAL_LOADED:-}" ]] && source "${_SCRIPTS_DIR}/esp-serial.sh"
# shellcheck source=scripts/yaml-info.sh
[[ -z "${_YAML_INFO_LOADED:-}" ]] && source "${_SCRIPTS_DIR}/yaml-info.sh"

FAILSAFE_TEMPLATE="${FAILSAFE_TEMPLATE:-${YAMLS_DIR}/failsafe.yaml}"

_IOTSTACK_YAML_CLEANUP_TRAP_REGISTERED=0

iotstack_cleanup_generated_yamls() {
  # Remove runtime artifacts under yamls/ (gitignored; recreated per invocation).
  local yamls_dir="${YAMLS_DIR:-}"
  [[ -z "$yamls_dir" || ! -d "$yamls_dir" ]] && return 0
  rm -f "${yamls_dir}"/.iotstack-failsafe-*.yaml \
        "${yamls_dir}"/.temp-ota-upload-*.yaml 2>/dev/null || true
}

iotstack_register_yaml_cleanup_trap() {
  # Chain with any existing EXIT handler so later trap assignments do not
  # drop yaml cleanup (SC2064: use single-quoted trap body; expand at trigger).
  [[ "${_IOTSTACK_YAML_CLEANUP_TRAP_REGISTERED}" -eq 1 ]] && return 0
  _IOTSTACK_YAML_CLEANUP_TRAP_REGISTERED=1

  local prior_cmd=""
  if trap -p EXIT 2>/dev/null | grep -q .; then
    prior_cmd=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")
  fi

  if [[ -n "$prior_cmd" ]]; then
    # shellcheck disable=SC2064
    trap 'iotstack_cleanup_generated_yamls; eval "$_IOTSTACK_PRIOR_EXIT_CMD"' EXIT
    _IOTSTACK_PRIOR_EXIT_CMD="$prior_cmd"
  else
    trap 'iotstack_cleanup_generated_yamls' EXIT
  fi
}

failsafe_boot_button_pin() {
  # BOOT button GPIO for the reference board of each variant.
  local variant="$1"
  case "$variant" in
    esp32s3|esp32s2|esp32) printf '%s\n' "GPIO0" ;;  # DevKitC / esp32dev
    *) printf '%s\n' "GPIO9" ;;                     # XIAO ESP32-C6 and similar
  esac
}

failsafe_chip_defaults() {
  # board|flash_size|framework for a variant when no production role is given
  local variant="$1"
  case "$variant" in
    esp32c6)  printf '%s\n' "seeed_xiao_esp32c6|4MB|esp-idf" ;;
    esp32s3)  printf '%s\n' "esp32-s3-devkitc-1|16MB|arduino" ;;
    esp32c3)  printf '%s\n' "esp32-c3-devkitm-1|4MB|arduino" ;;
    esp32s2)  printf '%s\n' "esp32-s3-devkitc-1|4MB|arduino" ;;
    esp32)    printf '%s\n' "esp32dev|4MB|arduino" ;;
    *)
      echo "Unsupported ESP32 variant for failsafe: $variant" >&2
      return 1
      ;;
  esac
}

flash_size_to_hex() {
  local size="$1"
  case "$size" in
    2MB)  printf '0x%x' $((2 * 1024 * 1024)) ;;
    4MB)  printf '0x%x' $((4 * 1024 * 1024)) ;;
    8MB)  printf '0x%x' $((8 * 1024 * 1024)) ;;
    16MB) printf '0x%x' $((16 * 1024 * 1024)) ;;
    0x*)  printf '%s' "$size" ;;
    *)
      echo "Unknown flash size: $size" >&2
      return 1
      ;;
  esac
}

yaml_esp32_profile() {
  # Emit variant|board|flash_size|framework from a YAML file.
  local yaml_file="$1"
  local board variant flash_size framework
  board=$(grep -A10 '^esp32:' "$yaml_file" | grep -E '^\s*board:\s*' | head -1 | sed 's/.*board:\s*//; s/\s*$//')
  variant=$(grep -A10 '^esp32:' "$yaml_file" | grep -E '^\s*variant:\s*' | head -1 | sed 's/.*variant:\s*//; s/\s*$//')
  flash_size=$(grep -A10 '^esp32:' "$yaml_file" | grep -E '^\s*flash_size:\s*' | head -1 | sed 's/.*flash_size:\s*//; s/\s*$//')
  framework=$(grep -A10 '^esp32:' "$yaml_file" | grep -A2 'framework:' | grep -E '^\s*type:\s*' | head -1 | sed 's/.*type:\s*//; s/\s*$//')
  [[ -n "$variant" && -n "$board" && -n "$flash_size" && -n "$framework" ]] || return 1
  printf '%s|%s|%s|%s\n' "$variant" "$board" "$flash_size" "$framework"
}

failsafe_profile_from_role() {
  local role="$1"
  local yaml_file
  yaml_file=$(yaml_path_for_role "$role") || return 1
  yaml_esp32_profile "$yaml_file"
}

failsafe_profile_from_tty() {
  local tty="$1"
  local variant defaults board flash_size framework
  variant=$(esp_detect_chip "$tty") || return 1
  defaults=$(failsafe_chip_defaults "$variant") || return 1
  board=$(echo "$defaults" | cut -d'|' -f1)
  flash_size=$(echo "$defaults" | cut -d'|' -f2)
  framework=$(echo "$defaults" | cut -d'|' -f3)
  printf '%s|%s|%s|%s\n' "$variant" "$board" "$flash_size" "$framework"
}

failsafe_resolve_profile() {
  # Resolve chip profile for a serial flash.
  # Usage: failsafe_resolve_profile <tty> [production_role]
  # Emits: variant|board|flash_size|framework|esptool_chip|flash_hex
  local tty="$1"
  local production_role="${2:-}"
  local port_variant="" role_profile="" variant board flash_size framework

  [[ -n "$tty" && -e "$tty" ]] || {
    echo "TTY device not found: $tty" >&2
    return 1
  }

  port_variant=$(esp_detect_chip "$tty") || {
    echo "Could not detect chip on $tty" >&2
    return 1
  }

  if [[ -n "$production_role" ]]; then
    role_profile=$(failsafe_profile_from_role "$production_role") || {
      echo "Could not read esp32 profile for role: $production_role" >&2
      return 1
    }
    variant=$(echo "$role_profile" | cut -d'|' -f1)
    board=$(echo "$role_profile" | cut -d'|' -f2)
    flash_size=$(echo "$role_profile" | cut -d'|' -f3)
    if [[ "$variant" != "$port_variant" ]]; then
      echo "Chip mismatch: $tty is ${port_variant} but role '${production_role}' requires ${variant}" >&2
      return 1
    fi
    # Failsafe framework is per-chip (e.g. esp32s3 → arduino), not the production role's.
    role_profile=$(failsafe_chip_defaults "$variant") || return 1
    framework=$(echo "$role_profile" | cut -d'|' -f3)
  else
    variant="$port_variant"
    role_profile=$(failsafe_chip_defaults "$variant") || return 1
    board=$(echo "$role_profile" | cut -d'|' -f1)
    flash_size=$(echo "$role_profile" | cut -d'|' -f2)
    framework=$(echo "$role_profile" | cut -d'|' -f3)
  fi

  local flash_hex
  flash_hex=$(flash_size_to_hex "$flash_size") || return 1
  printf '%s|%s|%s|%s|%s|%s\n' "$variant" "$board" "$flash_size" "$framework" "$variant" "$flash_hex"
}

failsafe_render_yaml() {
  # Render yamls/.iotstack-failsafe-<variant>.yaml from the template.
  # Must live under yamls/ so !include common/... resolves correctly.
  # Args: variant board flash_size framework
  local variant="$1" board="$2" flash_size="$3" framework="$4"
  local boot_pin dst
  boot_pin=$(failsafe_boot_button_pin "$variant") || return 1
  dst="${YAMLS_DIR}/.iotstack-failsafe-${variant}.yaml"

  [[ -f "$FAILSAFE_TEMPLATE" ]] || {
    echo "Failsafe template not found: $FAILSAFE_TEMPLATE" >&2
    return 1
  }
  mkdir -p "$ARTIFACTS_DIR"

  awk -v variant="$variant" -v board="$board" -v flash="$flash_size" -v framework="$framework" -v boot_pin="$boot_pin" '
    /^  chip_variant:/   { print "  chip_variant: " variant; next }
    /^  chip_board:/     { print "  chip_board: " board; next }
    /^  chip_flash_size:/{ print "  chip_flash_size: " flash; next }
    /^  chip_framework:/ { print "  chip_framework: " framework; next }
    /^  boot_button_pin:/ { print "  boot_button_pin: " boot_pin; next }
    { print }
  ' "$FAILSAFE_TEMPLATE" > "$dst"

  # Do not register EXIT trap here — callers often capture this path via $(...)
  # which runs in a subshell; the trap would delete the artifact when that
  # subshell exits, before compile/flash. Register in the parent shell instead.
  printf '%s\n' "$dst"
}

failsafe_apply_profile_to_env() {
  # Parse profile line into env vars used by flash/partition code.
  local profile="$1"
  export IOTSTACK_FAILSAFE_VARIANT
  export IOTSTACK_FAILSAFE_BOARD
  export IOTSTACK_FAILSAFE_FLASH_SIZE
  export IOTSTACK_FAILSAFE_FRAMEWORK
  export IOTSTACK_ESPTOOL_CHIP
  export IOTSTACK_FLASH_SIZE

  IOTSTACK_FAILSAFE_VARIANT=$(echo "$profile" | cut -d'|' -f1)
  IOTSTACK_FAILSAFE_BOARD=$(echo "$profile" | cut -d'|' -f2)
  IOTSTACK_FAILSAFE_FLASH_SIZE=$(echo "$profile" | cut -d'|' -f3)
  IOTSTACK_FAILSAFE_FRAMEWORK=$(echo "$profile" | cut -d'|' -f4)
  IOTSTACK_ESPTOOL_CHIP=$(echo "$profile" | cut -d'|' -f5)
  IOTSTACK_FLASH_SIZE=$(echo "$profile" | cut -d'|' -f6)
}

failsafe_prepare_for_tty() {
  # Detect chip, render YAML artifact, set partition/flash env.
  # Usage: failsafe_prepare_for_tty <tty> [production_role]
  # Prints: artifact_yaml_path|build_name (build_name is always "failsafe")
  local tty="$1"
  local production_role="${2:-}"
  local profile

  profile=$(failsafe_resolve_profile "$tty" "$production_role") || return 1
  failsafe_apply_profile_to_env "$profile"

  local variant board flash_size framework
  variant=$(echo "$profile" | cut -d'|' -f1)
  board=$(echo "$profile" | cut -d'|' -f2)
  flash_size=$(echo "$profile" | cut -d'|' -f3)
  framework=$(echo "$profile" | cut -d'|' -f4)

  failsafe_render_yaml "$variant" "$board" "$flash_size" "$framework" >/dev/null || return 1
  iotstack_register_yaml_cleanup_trap
  printf '%s|failsafe\n' "${YAMLS_DIR}/.iotstack-failsafe-${variant}.yaml"
}

failsafe_is_artifact_yaml() {
  local yaml_file="$1"
  local base
  base=$(basename "$yaml_file")
  [[ "$base" =~ ^failsafe(-[a-z0-9]+)?\.yaml$ ]] \
    || [[ "$base" =~ ^\.iotstack-failsafe-[a-z0-9]+\.yaml$ ]]
}