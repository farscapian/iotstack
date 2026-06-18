#!/bin/bash
# TEST_DESC: Compilation cache miss after external_components change (partition_manager)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

role=bleproxy
yaml_name="${role}.yaml"

cleanup() {
  test_restore_external_component_cache_bump
}
trap cleanup EXIT

test_info "Seeding compilation cache for ${role}"
test_run_step "smart_compile ${role} (seed)" test_run_smart_compile "$role"

test_info "smart_compile ${role} (confirm cache hit)"
output=""
set +e
output=$(test_run_smart_compile "$role" 2>&1)
rc=$?
set -e
[[ -n "$output" ]] && printf '%s\n' "$output"
[[ $rc -eq 0 ]] || { test_fail "smart_compile ${role} failed"; exit 1; }
test_assert_output_contains "Compilation cache hit" "$output"

test_bump_external_component_for_cache_miss

before_sha=$(test_compilation_cache_row "$yaml_name" | awk -F, '{ print $2 }')

test_info "smart_compile ${role} (expect cache miss after partition_manager bump)"
output=""
set +e
output=$(test_run_smart_compile "$role" 2>&1)
rc=$?
set -e
[[ -n "$output" ]] && printf '%s\n' "$output"
[[ $rc -eq 0 ]] || { test_fail "smart_compile ${role} failed after bump"; exit 1; }

test_assert_output_contains "Compilation cache miss" "$output"
test_assert_output_contains "Compiling production firmware" "$output"

after_sha=$(test_compilation_cache_row "$yaml_name" | awk -F, '{ print $2 }')
if [[ -n "$before_sha" && -n "$after_sha" && "$before_sha" != "$after_sha" ]]; then
  test_ok "compilation-cache yaml_sha updated after external_components change"
else
  test_fail "Expected compilation-cache yaml_sha to change (before=${before_sha:-empty} after=${after_sha:-empty})"
  exit 1
fi

hash=$(test_compilation_cache_config_hash "$yaml_name")
if [[ "$hash" =~ ^[0-9a-f]{8}$ ]]; then
  test_ok "config_hash recorded after recompile: ${hash}"
else
  test_fail "config_hash missing after recompile (got: ${hash:-empty})"
  exit 1
fi