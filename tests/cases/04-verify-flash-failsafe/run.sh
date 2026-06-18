#!/bin/bash
# TEST_DESC: Verify failsafe partition checksums on device flash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

test_require_tty_failsafe

test_run_step "iotstack verify-flash failsafe ${IOTSTACK_TEST_TTY}" \
  test_iotstack verify-flash failsafe "$IOTSTACK_TEST_TTY"