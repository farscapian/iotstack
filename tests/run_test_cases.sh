#!/bin/bash
# run_test_cases.sh -- Overnight iotstack integration test runner
#
# Usage:
#   ./tests/run_test_cases.sh [--list] [--tty DEV] [--iterations N] [--stop-on-failure] [test...]
#   iotstack tests run [options] [test...]
#
# Test selectors (one or more):
#   0 / 00 / 00-flash-bleproxy / flash-bleproxy
#
# Environment (from ~/.iotstack/.env):
#   IOTSTACK_TEST_TTY_C6=/dev/ttyACM0   optional override
#   IOTSTACK_TEST_TTY_S3=/dev/ttyACM1   optional override

set -euo pipefail

_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=tests/lib/common.sh
source "${_RUNNER_DIR}/lib/common.sh"

CASES_DIR="${TESTS_DIR}/cases"
STOP_ON_FAILURE=0
LIST_ONLY=0
PORTS_ONLY=0
ITERATIONS=1
declare -a SELECTED_TESTS=()

usage() {
  cat <<EOF
Usage: run_test_cases.sh [options] [test...]

Run iotstack integration tests against a USB-connected ESP32-C6.

Options:
  --list              List available test cases and exit
  --tty <device>      Pin a port (auto-detect chip; sets C6 or S3 override)
  --ports             Scan and print USB port -> chip mapping, then exit
  --iterations <n>    Repeat the selected suite N times (default: 1)
  --stop-on-failure   Stop after the first failing test
  --verbose           Pass -v to iotstack commands
  -h, --help          Show this help

Test selectors (if omitted, runs the full suite in order):
  0                   Run 00-flash-bleproxy
  00-flash-bleproxy   Run by id prefix or slug
  flash-bleproxy      Partial slug match

Examples:
  iotstack tests run
  iotstack tests run --iterations 3
  iotstack tests run 0
  iotstack tests run 00-flash-bleproxy --tty /dev/ttyACM0
  iotstack tests list
EOF
}

_list_cases() {
  local f base id slug desc
  printf '%-4s  %-28s  %s\n' "ID" "SLUG" "DESCRIPTION"
  printf '%s\n' "------------------------------------------------------------------------"
  for f in "${CASES_DIR}"/[0-9][0-9]-*/run.sh; do
    [[ -f "$f" ]] || continue
    base=$(basename "$(dirname "$f")")
    id="${base%%-*}"
    slug="${base#*-}"
    desc=$(grep -m1 '^# TEST_DESC:' "$f" 2>/dev/null | sed 's/^# TEST_DESC:[[:space:]]*//')
    [[ -z "$desc" ]] && desc="(no description)"
    printf '%-4s  %-28s  %s\n' "$id" "$slug" "$desc"
  done
}

_match_case() {
  local query="$1"
  local f base id slug
  local -a matches=()
  local q_lower q_num

  q_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')
  if [[ "$q_lower" =~ ^[0-9]+$ ]]; then
    q_num=$((10#$q_lower))
  else
    q_num=-1
  fi

  for f in "${CASES_DIR}"/[0-9][0-9]-*/run.sh; do
    [[ -f "$f" ]] || continue
    base=$(basename "$(dirname "$f")")
    id="${base%%-*}"
    slug="${base#*-}"
    if (( q_num >= 0 )); then
      if (( 10#$id == q_num )); then
        matches+=("$f")
      fi
      continue
    fi
    if [[ "$base" == "$q_lower" || "$slug" == "$q_lower" || "$base" == *"-${q_lower}"* || "$slug" == *"${q_lower}"* ]]; then
      matches+=("$f")
    fi
  done

  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "No test case matches: $query" >&2
    return 1
  fi
  if [[ ${#matches[@]} -gt 1 ]]; then
    echo "Ambiguous test selector '$query' matches:" >&2
    printf '  %s\n' "${matches[@]##*/}" >&2
    return 1
  fi
  printf '%s\n' "${matches[0]}"
}

_resolve_suite() {
  local -a resolved=()
  local query f

  if [[ ${#SELECTED_TESTS[@]} -eq 0 ]]; then
    for f in "${CASES_DIR}"/[0-9][0-9]-*/run.sh; do
      [[ -f "$f" ]] || continue
      resolved+=("$f")
    done
  else
    for query in "${SELECTED_TESTS[@]}"; do
      f=$(_match_case "$query") || return 1
      resolved+=("$f")
    done
  fi

  if [[ ${#resolved[@]} -eq 0 ]]; then
    echo "No test cases found in ${CASES_DIR}" >&2
    return 1
  fi

  printf '%s\n' "${resolved[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    --tty)
      _pin_tty="$2"
      shift 2
      # shellcheck source=scripts/esp-serial.sh
      source "${SCRIPTS_DIR}/esp-serial.sh"
      _pin_chip=$(esp_detect_chip "$_pin_tty" 2>/dev/null) || {
        echo "Could not detect chip on $_pin_tty" >&2
        exit 1
      }
      case "$_pin_chip" in
        esp32c6) export IOTSTACK_TEST_TTY_C6="$_pin_tty" ;;
        esp32s3) export IOTSTACK_TEST_TTY_S3="$_pin_tty" ;;
        *) echo "Unsupported chip $_pin_chip on $_pin_tty" >&2; exit 1 ;;
      esac
      ;;
    --ports)
      PORTS_ONLY=1
      shift
      ;;
    --iterations)
      ITERATIONS="$2"
      shift 2
      ;;
    --stop-on-failure)
      STOP_ON_FAILURE=1
      shift
      ;;
    --verbose)
      IOTSTACK_TEST_VERBOSE=1
      IOTSTACK_TEST_QUIET=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      SELECTED_TESTS+=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      SELECTED_TESTS+=("$1")
      shift
      ;;
  esac
done

if [[ ! -d "$CASES_DIR" ]]; then
  echo "Test cases directory not found: $CASES_DIR" >&2
  exit 1
fi

if [[ "$LIST_ONLY" -eq 1 ]]; then
  _list_cases
  exit 0
fi

if [[ "$PORTS_ONLY" -eq 1 ]]; then
  test_scan_serial_devices
  exit 0
fi

if ! [[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]]; then
  echo "--iterations must be a positive integer" >&2
  exit 1
fi

mapfile -t SUITE < <(_resolve_suite)

test_scan_serial_devices

RUN_LOG="${IOTSTACK_TEST_LOG_DIR}/run_$(date +%Y%m%d_%H%M%S).log"
test_info "Log file: $RUN_LOG"
test_info "Cases: ${#SUITE[@]} | Iterations: $ITERATIONS"
test_info "Port map: ${ESP_SERIAL_MAP}"
test_info "iotstack logs: tests/cases/<slug>/iotstack-<slug>.log -> ~/.iotstack/logs/ (--log-id)"
{
  echo "iotstack test run started: $(date -Is)"
  echo "ROLE=${IOTSTACK_TEST_ROLE} ITERATIONS=${ITERATIONS}"
  echo "PORT_MAP=${ESP_SERIAL_MAP}"
  if [[ -f "${ESP_SERIAL_MAP}" ]]; then
    cat "${ESP_SERIAL_MAP}"
  fi
} >> "$RUN_LOG"

total_pass=0
total_fail=0
run_failed=0

for (( iter=1; iter<=ITERATIONS; iter++ )); do
  if [[ "$ITERATIONS" -gt 1 ]]; then
    test_info "=== Iteration $iter/$ITERATIONS ==="
    echo "-- iteration $iter/$ITERATIONS --" >> "$RUN_LOG"
  fi

  for case_script in "${SUITE[@]}"; do
    case_slug=$(basename "$(dirname "$case_script")")
    export IOTSTACK_TEST_LOG_ID="$case_slug"
    export IOTSTACK_TEST_CASE_DIR="$(cd "$(dirname "$case_script")" && pwd)"
    test_link_session_log
    test_info "> ${case_slug}/run.sh (log-id=${IOTSTACK_TEST_LOG_ID})"
    echo "> ${case_slug}/run.sh (log-id=${IOTSTACK_TEST_LOG_ID})" >> "$RUN_LOG"

    set +e
    bash "$case_script" 2>&1 | tee -a "$RUN_LOG"
    case_status=${PIPESTATUS[0]}
    set -e

    if [[ $case_status -eq 0 ]]; then
      total_pass=$((total_pass + 1))
      test_ok "Completed: ${case_slug}/run.sh"
    else
      total_fail=$((total_fail + 1))
      run_failed=1
      test_fail "Failed: ${case_slug}/run.sh (exit $case_status)"
      if [[ "$STOP_ON_FAILURE" -eq 1 ]]; then
        break 2
      fi
    fi
    echo "" >> "$RUN_LOG"
  done
done

echo ""
test_info "Summary: ${total_pass} passed, ${total_fail} failed"
echo "summary: pass=$total_pass fail=$total_fail log=$RUN_LOG" >> "$RUN_LOG"

if [[ $run_failed -ne 0 ]]; then
  exit 1
fi