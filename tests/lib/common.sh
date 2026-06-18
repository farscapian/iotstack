#!/bin/bash
# common.sh — Shared helpers for iotstack overnight test cases
#
# Sourced by tests/cases/*.sh and tests/run_test_cases.sh (do not execute directly).

if [[ -n "${_IOTSTACK_TEST_COMMON_LOADED:-}" ]]; then
  return 0
fi
_IOTSTACK_TEST_COMMON_LOADED=1

_TESTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_TESTS_ROOT="$(cd "${_TESTS_LIB_DIR}/.." && pwd)"

if [[ -z "${PROJECT_ROOT:-}" ]]; then
  # shellcheck source=scripts/config.sh
  source "${_TESTS_ROOT}/../scripts/config.sh"
fi

# shellcheck source=scripts/esp-serial.sh
source "${SCRIPTS_DIR}/esp-serial.sh"
# shellcheck source=scripts/yaml-info.sh
source "${SCRIPTS_DIR}/yaml-info.sh"
# shellcheck source=scripts/failsafe-yaml.sh
source "${SCRIPTS_DIR}/failsafe-yaml.sh"

export TESTS_DIR="${TESTS_DIR:-${_TESTS_ROOT}}"
export IOTSTACK_BIN="${IOTSTACK_BIN:-${PROJECT_ROOT}/iotstack.sh}"
export IOTSTACK_TEST_ROLE="${IOTSTACK_TEST_ROLE:-bleproxy}"
export IOTSTACK_TEST_STATE="${IOTSTACK_TEST_STATE:-${ARTIFACTS_DIR}/test-state.env}"
export IOTSTACK_TEST_LOG_DIR="${IOTSTACK_TEST_LOG_DIR:-${LOGS_DIR}/tests}"

mkdir -p "$ARTIFACTS_DIR" "$IOTSTACK_TEST_LOG_DIR" 2>/dev/null || true

_TEST_RED=$'\033[0;31m'
_TEST_GRN=$'\033[0;32m'
_TEST_YLW=$'\033[0;33m'
_TEST_BLU=$'\033[0;34m'
_TEST_RST=$'\033[0m'

test_info() { echo -e "${_TEST_BLU}[TEST]${_TEST_RST} $*"; }
test_ok()   { echo -e "${_TEST_GRN}[PASS]${_TEST_RST} $*"; }
test_warn() { echo -e "${_TEST_YLW}[WARN]${_TEST_RST} $*"; }
test_fail() { echo -e "${_TEST_RED}[FAIL]${_TEST_RST} $*" >&2; }

test_role_variant() {
  local role="${1:-$IOTSTACK_TEST_ROLE}"
  yaml_variant_for_role "$role"
}

test_failsafe_variant() {
  yaml_variant_for_failsafe
}

test_scan_serial_devices() {
  local line
  test_info "Scanning USB serial ports for Espressif devices..."
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    test_info "  ${line//:/ → }"
  done < <(esp_serial_scan)
}

test_tty_for_variant() {
  local variant="$1"
  esp_serial_require_variant "$variant"
}

test_tty_for_role() {
  local role="${1:-$IOTSTACK_TEST_ROLE}"
  local variant tty
  variant=$(test_role_variant "$role") || {
    test_fail "Unknown role: $role"
    return 1
  }
  tty=$(test_tty_for_variant "$variant") || {
    local hint="IOTSTACK_TEST_TTY"
    case "$variant" in
      esp32c6) hint="IOTSTACK_TEST_TTY_C6" ;;
      esp32s3) hint="IOTSTACK_TEST_TTY_S3" ;;
    esac
    test_fail "No USB device found for ${role} (needs ${variant}). Plug in the board or set ${hint} in ~/.iotstack/.env"
    return 1
  }
  printf '%s\n' "$tty"
}

test_require_tty_for_role() {
  local role="${1:-$IOTSTACK_TEST_ROLE}"
  local variant tty
  variant=$(test_role_variant "$role")
  tty=$(test_tty_for_role "$role") || return 1
  export IOTSTACK_TEST_TTY="$tty"
  export IOTSTACK_TEST_ROLE="$role"
  export IOTSTACK_TEST_VARIANT="$variant"
  test_info "Role ${role} → ${variant} → ${tty}"
}

test_require_tty_failsafe() {
  # Failsafe flash targets a chip-specific port (defaults to esp32c6).
  local variant="${1:-esp32c6}"
  local tty
  tty=$(test_tty_for_variant "$variant") || {
    test_fail "No USB ${variant} device for failsafe flash (set IOTSTACK_TEST_TTY_C6 / _S3)"
    return 1
  }
  export IOTSTACK_TEST_TTY="$tty"
  export IOTSTACK_TEST_VARIANT="$variant"
  test_info "Failsafe (${variant}) → ${tty}"
}

test_iotstack() {
  local -a cmd=("$IOTSTACK_BIN")
  # Full logs for post-run review (~/.iotstack/logs/iotstack-<command>.log)
  if [[ "${IOTSTACK_TEST_LOG_FOR_CLAUDE:-1}" -eq 1 ]]; then
    cmd+=(--log-for-claude)
  fi
  [[ "${IOTSTACK_TEST_VERBOSE:-0}" -eq 1 ]] && cmd+=(-v)
  # -q suppresses info lines; skip it when capturing Claude logs
  if [[ "${IOTSTACK_TEST_QUIET:-1}" -eq 1 && "${IOTSTACK_TEST_LOG_FOR_CLAUDE:-1}" -ne 1 ]]; then
    cmd+=(-q)
  fi
  "${cmd[@]}" "$@"
}

test_save_state() {
  local key="$1"
  local value="$2"
  local tmp
  tmp=$(mktemp)
  if [[ -f "$IOTSTACK_TEST_STATE" ]]; then
    grep -v "^${key}=" "$IOTSTACK_TEST_STATE" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$value" >> "$tmp"
  mv "$tmp" "$IOTSTACK_TEST_STATE"
}

test_load_state() {
  local key="$1"
  local value=""
  if [[ -f "$IOTSTACK_TEST_STATE" ]]; then
    value=$(grep -m1 "^${key}=" "$IOTSTACK_TEST_STATE" 2>/dev/null | cut -d= -f2-)
  fi
  printf '%s' "$value"
}

test_mac_state_key() {
  local role="${1:-$IOTSTACK_TEST_ROLE}"
  printf 'TEST_MAC_%s' "$role"
}

test_discover_mac() {
  local role="${1:-$IOTSTACK_TEST_ROLE}"
  local mdns_name mac_line mac key
  mdns_name=$(yaml_mdns_name_for_role "$role" 2>/dev/null) || mdns_name="$role"
  mac_line=$(test_iotstack devices "$mdns_name" --id 2>/dev/null | tr '\n' ' ')
  if [[ -z "$(echo "$mac_line" | tr -d '[:space:]')" ]]; then
    mac_line=$(test_iotstack devices "$role" --id 2>/dev/null | tr '\n' ' ')
  fi
  read -r mac _ <<< "$mac_line"
  mac=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
  if [[ "$mac" =~ ^[0-9a-f]{6}$ ]]; then
    key=$(test_mac_state_key "$role")
    test_save_state "$key" "$mac"
    test_save_state "TEST_MAC" "$mac"
    printf '%s\n' "$mac"
    return 0
  fi
  return 1
}

test_ensure_mac() {
  local role="${1:-$IOTSTACK_TEST_ROLE}"
  local mac key
  key=$(test_mac_state_key "$role")
  mac=$(test_load_state "$key")
  mac=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
  if [[ "$mac" =~ ^[0-9a-f]{6}$ ]]; then
    printf '%s\n' "$mac"
    return 0
  fi
  test_discover_mac "$role"
}

test_run_step() {
  local desc="$1"
  shift
  local output rc
  test_info "$desc"
  set +e
  output=$("$@" 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    [[ -n "$output" ]] && printf '%s\n' "$output"
    test_ok "$desc"
    return 0
  fi
  test_fail "$desc"
  if [[ -n "$output" ]]; then
    echo "$output" >&2
  else
    test_warn "No output captured (try: IOTSTACK_TEST_VERBOSE=1 iotstack tests run ...)"
  fi
  return 1
}

test_verify_flash() {
  local role="${1:-failsafe}"
  local tty="${2:-${IOTSTACK_TEST_TTY:-}}"
  local variant="${3:-${IOTSTACK_TEST_VARIANT:-$(test_role_variant "$role")}}"
  local chip flash_size

  chip="$variant"
  case "$variant" in
    esp32c6) flash_size=4MB ;;
    esp32s3) flash_size=16MB ;;
    *) flash_size=4MB ;;
  esac

  ESP_VERIFY_CHIP="$chip" ESP_VERIFY_FLASH_SIZE="$flash_size" \
    "${SCRIPTS_DIR}/verify-flash.sh" "$tty" "$role"
}