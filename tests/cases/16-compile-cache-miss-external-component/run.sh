#!/bin/bash
# TEST_DESC: Compile skip miss after external_components change (iotstack flash)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

role=bleproxy

cleanup() {
  test_restore_external_component_cache_bump
}
trap cleanup EXIT

test_require_tty_for_role "$role"

test_run_step "iotstack flash ${role} ${IOTSTACK_TEST_TTY} (seed)" \
  test_iotstack flash "$role" "$IOTSTACK_TEST_TTY"

test_info "iotstack flash ${role} ${IOTSTACK_TEST_TTY} (confirm compile skip hit)"
output=""
set +e
output=$(test_iotstack flash "$role" "$IOTSTACK_TEST_TTY" 2>&1)
rc=$?
set -e
[[ -n "$output" ]] && printf '%s\n' "$output"
[[ $rc -eq 0 ]] || { test_fail "iotstack flash ${role} failed"; exit 1; }
test_assert_output_contains "Compilation cache hit" "$output"

test_bump_external_component_for_cache_miss

before_hash=$(test_build_config_hash "$role")

test_info "iotstack flash ${role} ${IOTSTACK_TEST_TTY} (expect compile skip miss after partition_manager bump)"
output=""
set +e
output=$(test_iotstack flash "$role" "$IOTSTACK_TEST_TTY" 2>&1)
rc=$?
set -e
[[ -n "$output" ]] && printf '%s\n' "$output"
[[ $rc -eq 0 ]] || { test_fail "iotstack flash ${role} failed after bump"; exit 1; }

test_assert_output_contains "Compilation cache miss" "$output"
test_assert_output_contains "Compiling production firmware" "$output"

after_hash=$(test_build_config_hash "$role")
if [[ -n "$before_hash" && -n "$after_hash" && "$before_hash" != "$after_hash" ]]; then
  test_ok "build_info.json config_hash updated after external_components change"
else
  test_fail "Expected build_info.json config_hash to change (before=${before_hash:-empty} after=${after_hash:-empty})"
  exit 1
fi

hash=$(test_build_config_hash "$role")
if [[ "$hash" =~ ^[0-9a-f]{8}$ ]]; then
  test_ok "config_hash recorded after recompile: ${hash}"
else
  test_fail "config_hash missing after recompile (got: ${hash:-empty})"
  exit 1
fi