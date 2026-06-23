#!/bin/bash
# TEST_DESC: Compile ledlightstrip-s3-wifi and dry-run OTA (ESP32-S3)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac ledlightstrip-s3-wifi) || true

if [[ -n "$mac" ]]; then
  test_run_step "iotstack update ${mac} ledlightstrip-s3-wifi --dry-run" \
    test_iotstack update "$mac" ledlightstrip-s3-wifi --dry-run
else
  test_run_step "iotstack update ledlightstrip-s3-wifi --dry-run" \
    test_iotstack update ledlightstrip-s3-wifi --dry-run
fi