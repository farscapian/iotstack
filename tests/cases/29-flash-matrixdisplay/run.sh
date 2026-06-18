#!/bin/bash
# TEST_DESC: Flash matrixdisplay on ESP32-S3 (OTA if on network, else serial)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

test_require_tty_for_role matrixdisplay

test_run_step "iotstack flash matrixdisplay ${IOTSTACK_TEST_TTY}" \
  test_iotstack flash matrixdisplay "$IOTSTACK_TEST_TTY"

test_discover_mac matrixdisplay >/dev/null 2>&1 || \
  test_warn "matrixdisplay not on network yet after flash"