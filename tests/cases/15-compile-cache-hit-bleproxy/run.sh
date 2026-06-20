#!/bin/bash
# TEST_DESC: Compile skip hit via build_info.json config_hash (iotstack flash -> smart_compile)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

role=bleproxy

test_require_tty_for_role "$role"

test_run_step "iotstack flash ${role} ${IOTSTACK_TEST_TTY} (seed)" \
  test_iotstack flash "$role" "$IOTSTACK_TEST_TTY"

test_info "iotstack flash ${role} ${IOTSTACK_TEST_TTY} (expect compile skip hit)"
output=""
set +e
output=$(test_iotstack flash "$role" "$IOTSTACK_TEST_TTY" 2>&1)
rc=$?
set -e
[[ -n "$output" ]] && printf '%s\n' "$output"
[[ $rc -eq 0 ]] || { test_fail "iotstack flash ${role} failed"; exit 1; }

test_assert_output_contains "Compilation cache hit" "$output"

hash=$(test_build_config_hash "$role")
if [[ "$hash" =~ ^[0-9a-f]{8}$ ]]; then
  test_ok "build_info.json config_hash present: ${hash}"
else
  test_fail "config_hash missing from build_info.json (got: ${hash:-empty})"
  exit 1
fi