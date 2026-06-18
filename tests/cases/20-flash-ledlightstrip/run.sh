#!/bin/bash
# TEST_DESC: Flash ledlightstrip on ESP32-S3 (OTA if on network, else serial)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

test_require_tty_for_role ledlightstrip

test_run_step "iotstack flash ledlightstrip ${IOTSTACK_TEST_TTY}" \
  test_iotstack flash ledlightstrip "$IOTSTACK_TEST_TTY"

test_discover_mac ledlightstrip >/dev/null 2>&1 || \
  test_warn "ledlightstrip not on network yet after flash"