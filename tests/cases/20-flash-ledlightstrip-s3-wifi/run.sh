#!/bin/bash
# TEST_DESC: Flash ledlightstrip-s3-wifi on ESP32-S3 (OTA if on network, else serial)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

test_require_tty_for_role ledlightstrip-s3-wifi

test_run_step "iotstack flash ledlightstrip-s3-wifi ${IOTSTACK_TEST_TTY}" \
  test_iotstack flash ledlightstrip-s3-wifi "$IOTSTACK_TEST_TTY"

test_discover_mac ledlightstrip-s3-wifi >/dev/null 2>&1 || \
  test_warn "ledlightstrip-s3-wifi not on network yet after flash"