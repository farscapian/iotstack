#!/bin/bash
# TEST_DESC: Compilation cache hit and config_hash backfill (bleproxy smart_compile)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

role=bleproxy
yaml_name="${role}.yaml"

test_info "Seeding compilation cache for ${role} (compile if needed)"
test_run_step "smart_compile ${role} (seed)" test_run_smart_compile "$role"

test_strip_compilation_cache_config_hash "$yaml_name" \
  || test_fail "Could not strip config_hash from compilation-cache row for ${yaml_name}"

test_info "smart_compile ${role} (expect cache hit + config_hash backfill)"
output=""
set +e
output=$(test_run_smart_compile "$role" 2>&1)
rc=$?
set -e
[[ -n "$output" ]] && printf '%s\n' "$output"
[[ $rc -eq 0 ]] || { test_fail "smart_compile ${role} failed"; exit 1; }

test_assert_output_contains "Compilation cache hit" "$output"

hash=$(test_compilation_cache_config_hash "$yaml_name")
if [[ "$hash" =~ ^[0-9a-f]{8}$ ]]; then
  test_ok "config_hash backfilled: ${hash}"
else
  test_fail "config_hash not backfilled in compilation-cache.csv (got: ${hash:-empty})"
  exit 1
fi