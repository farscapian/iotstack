#!/bin/bash
# TEST_DESC: Flash matrixdisplay on ESP32-S3 with --erase (erase flash, USB bootstrap, production OTA)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

test_require_tty_for_role matrixdisplay

test_run_step "iotstack flash matrixdisplay ${IOTSTACK_TEST_TTY} --erase" \
  test_iotstack flash matrixdisplay "$IOTSTACK_TEST_TTY" --erase

if test_discover_mac matrixdisplay; then
  test_ok "Discovered TEST_MAC_matrixdisplay=$(test_load_state TEST_MAC_matrixdisplay)"
else
  test_warn "Could not discover matrixdisplay MAC yet -- later network tests may skip or retry"
fi
