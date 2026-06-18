#!/bin/bash
# common.sh -- Shared helpers for iotstack overnight test cases
#
# Sourced by tests/cases/<slug>/run.sh and tests/run_test_cases.sh (do not execute directly).

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
# shellcheck source=scripts/bootstrap-yaml.sh
source "${SCRIPTS_DIR}/bootstrap-yaml.sh"

export TESTS_DIR="${TESTS_DIR:-${_TESTS_ROOT}}"
export IOTSTACK_BIN="${IOTSTACK_BIN:-${PROJECT_ROOT}/iotstack.sh}"
export IOTSTACK_TEST_ROLE="${IOTSTACK_TEST_ROLE:-bleproxy}"
export IOTSTACK_TEST_STATE="${IOTSTACK_TEST_STATE:-${ARTIFACTS_DIR}/test-state.env}"
export IOTSTACK_TEST_LOG_DIR="${IOTSTACK_TEST_LOG_DIR:-${LOGS_DIR}/tests}"

# Per-case session log (~/.iotstack/logs/iotstack-<case-slug>.log). Set by the runner
# or auto-detected when a tests/cases/<slug>/run.sh script sources this file.
if [[ -n "${BASH_SOURCE[1]:-}" ]]; then
  case "${BASH_SOURCE[1]}" in
    */tests/cases/[0-9][0-9]-*/run.sh)
      export IOTSTACK_TEST_CASE_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
      if [[ -z "${IOTSTACK_TEST_LOG_ID:-}" ]]; then
        export IOTSTACK_TEST_LOG_ID="$(basename "$IOTSTACK_TEST_CASE_DIR")"
      fi
      ;;
  esac
fi

mkdir -p "$ARTIFACTS_DIR" "$IOTSTACK_TEST_LOG_DIR" "$LOGS_DIR" 2>/dev/null || true

test_session_log_file() {
  local log_id="${1:-${IOTSTACK_TEST_LOG_ID:-}}"
  [[ -n "$log_id" && "$log_id" != "0" ]] || return 1
  printf '%s/iotstack-%s.log' "$LOGS_DIR" "$log_id"
}

test_link_session_log() {
  # Symlink tests/cases/<slug>/iotstack-<slug>.log -> ~/.iotstack/logs/iotstack-<slug>.log
  local log_id="${1:-${IOTSTACK_TEST_LOG_ID:-}}"
  local case_dir="${2:-${IOTSTACK_TEST_CASE_DIR:-}}"
  local log_file link
  log_file=$(test_session_log_file "$log_id") || return 0
  [[ -n "$case_dir" && -d "$case_dir" ]] || return 0
  link="${case_dir}/iotstack-${log_id}.log"
  mkdir -p "$(dirname "$log_file")"
  ln -sfn "$log_file" "$link"
}

if [[ -n "${IOTSTACK_TEST_CASE_DIR:-}" && -n "${IOTSTACK_TEST_LOG_ID:-}" ]]; then
  test_link_session_log
fi

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

test_bootstrap_variant() {
  yaml_variant_for_bootstrap
}

test_scan_serial_devices() {
  local line
  test_info "Scanning USB serial ports for Espressif devices..."
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    test_info "  ${line//:/ -> }"
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
  test_info "Role ${role} -> ${variant} -> ${tty}"
}

test_require_tty_bootstrap() {
  # Bootstrap flash targets a chip-specific port (defaults to esp32c6).
  local variant="${1:-esp32c6}"
  local tty
  tty=$(test_tty_for_variant "$variant") || {
    test_fail "No USB ${variant} device for bootstrap flash (set IOTSTACK_TEST_TTY_C6 / _S3)"
    return 1
  }
  export IOTSTACK_TEST_TTY="$tty"
  export IOTSTACK_TEST_VARIANT="$variant"
  test_info "Bootstrap (${variant}) -> ${tty}"
}

test_iotstack() {
  local -a cmd=("$IOTSTACK_BIN")
  local log_id="${IOTSTACK_TEST_LOG_ID:-}"
  # Session log per test case (--log-id implies --create-log and -v).
  if [[ -n "$log_id" && "$log_id" != "0" ]]; then
    cmd+=(--log-id="$log_id")
  fi
  [[ "${IOTSTACK_TEST_VERBOSE:-0}" -eq 1 ]] && cmd+=(-v)
  # -q is incompatible with --log-id (implies -v); skip quiet when logging.
  if [[ "${IOTSTACK_TEST_QUIET:-1}" -eq 1 && ( -z "$log_id" || "$log_id" == "0" ) ]]; then
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

test_compilation_cache_row() {
  local yaml_name="${1:-bleproxy.yaml}"
  [[ -f "$COMPILATION_CACHE" ]] || return 1
  awk -F, -v name="$yaml_name" '$1==name { print; exit }' "$COMPILATION_CACHE"
}

test_compilation_cache_config_hash() {
  local yaml_name="${1:-bleproxy.yaml}"
  test_compilation_cache_row "$yaml_name" | awk -F, '{ print $4 }'
}

test_strip_compilation_cache_config_hash() {
  # Simulate a legacy row missing config_hash (backfill should repair on cache hit).
  local yaml_name="${1:-bleproxy.yaml}"
  local row yaml_sha binary_sha tmp
  row=$(test_compilation_cache_row "$yaml_name") || return 1
  IFS=, read -r _ yaml_sha binary_sha _ <<< "$row"
  [[ -n "$yaml_sha" && -n "$binary_sha" ]] || return 1
  tmp=$(mktemp)
  {
    echo "yaml_name,yaml_sha,binary_sha,config_hash"
    awk -F, -v name="$yaml_name" 'NR > 1 && $1 != name { print }' "$COMPILATION_CACHE"
    printf '%s,%s,%s,\n' "$yaml_name" "$yaml_sha" "$binary_sha"
  } > "$tmp"
  mv "$tmp" "$COMPILATION_CACHE"
}

test_assert_output_contains() {
  local needle="$1"
  local haystack="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    test_ok "Output contains: ${needle}"
    return 0
  fi
  test_fail "Expected output to contain: ${needle}"
  printf '%s\n' "$haystack" >&2
  return 1
}

test_compile_cache_bump_file() {
  printf '%s/external_components/partition_manager/partition_manager.cpp' "$YAMLS_DIR"
}

test_bump_external_component_for_cache_miss() {
  local cpp stamp
  cpp=$(test_compile_cache_bump_file)
  [[ -f "$cpp" ]] || { test_fail "Missing ${cpp}"; return 1; }
  stamp=$(date +%s)
  sed -i '/iotstack-test-cache-bump/d' "$cpp"
  sed -i "/void PartitionManager::handle_button_press/a\\  // iotstack-test-cache-bump ${stamp}" "$cpp"
}

test_restore_external_component_cache_bump() {
  git -C "$PROJECT_ROOT" checkout -- yamls/external_components/partition_manager/partition_manager.cpp 2>/dev/null \
    || true
}