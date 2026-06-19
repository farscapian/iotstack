#!/bin/bash
# TEST_DESC: Compilation cache hit and image_hash backfill (iotstack flash -> smart_compile)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

role=bleproxy
yaml_name="${role}.yaml"

test_require_tty_for_role "$role"

test_run_step "iotstack flash ${role} ${IOTSTACK_TEST_TTY} (seed)" \
  test_iotstack flash "$role" "$IOTSTACK_TEST_TTY"

test_strip_compilation_cache_image_hash "$yaml_name" \
  || test_fail "Could not strip image_hash from compilation-cache row for ${yaml_name}"

test_info "iotstack flash ${role} ${IOTSTACK_TEST_TTY} (expect cache hit + image_hash backfill)"
output=""
set +e
output=$(test_iotstack flash "$role" "$IOTSTACK_TEST_TTY" 2>&1)
rc=$?
set -e
[[ -n "$output" ]] && printf '%s\n' "$output"
[[ $rc -eq 0 ]] || { test_fail "iotstack flash ${role} failed"; exit 1; }

test_assert_output_contains "Compilation cache hit" "$output"

hash=$(test_compilation_cache_image_hash "$yaml_name")
if [[ "$hash" =~ ^[0-9a-f]{8}$ ]]; then
  test_ok "image_hash backfilled: ${hash}"
else
  test_fail "image_hash not backfilled in compilation-cache.csv (got: ${hash:-empty})"
  exit 1
fi