#!/bin/bash
# TEST_DESC: Verify bleproxy firmware matches current build
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

test_run_step "iotstack verify bleproxy" \
  test_iotstack verify "$IOTSTACK_TEST_ROLE"