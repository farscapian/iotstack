#!/bin/bash
# TEST_DESC: Re-flash bootstrap image via serial (before set-boot tests)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

test_require_tty_bootstrap

test_run_step "iotstack flash bootstrap ${IOTSTACK_TEST_TTY}" \
  test_iotstack flash bootstrap "$IOTSTACK_TEST_TTY"