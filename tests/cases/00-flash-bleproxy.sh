#!/bin/bash
# TEST_DESC: Flash bleproxy via serial (failsafe + production OTA)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

test_require_tty_for_role bleproxy

test_run_step "iotstack flash bleproxy ${IOTSTACK_TEST_TTY}" \
  test_iotstack flash bleproxy "$IOTSTACK_TEST_TTY"

if test_discover_mac bleproxy; then
  test_ok "Discovered TEST_MAC_bleproxy=$(test_load_state TEST_MAC_bleproxy)"
else
  test_warn "Could not discover MAC yet — later network tests may skip or retry"
fi