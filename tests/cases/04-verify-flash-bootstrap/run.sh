#!/bin/bash
# TEST_DESC: Verify bootstrap partition checksums on device flash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

test_require_tty_bootstrap

test_run_step "iotstack verify-flash bootstrap ${IOTSTACK_TEST_TTY}" \
  test_iotstack verify-flash bootstrap "$IOTSTACK_TEST_TTY"