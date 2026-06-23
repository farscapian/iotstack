#!/bin/bash
# TEST_DESC: Reassign S3 device to silentnotify via bootstrap OTA
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac ledlightstrip-s3-wifi) || { test_fail "No S3 device MAC on network"; exit 1; }

test_run_step "iotstack reassign ${mac} silentnotify" \
  test_iotstack reassign "$mac" silentnotify