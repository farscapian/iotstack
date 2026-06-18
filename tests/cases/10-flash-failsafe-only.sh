#!/bin/bash
# TEST_DESC: Re-flash failsafe image via serial (before set-boot tests)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

test_require_tty_failsafe

test_run_step "iotstack flash failsafe ${IOTSTACK_TEST_TTY}" \
  test_iotstack flash failsafe "$IOTSTACK_TEST_TTY"