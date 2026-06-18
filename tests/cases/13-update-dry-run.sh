#!/bin/bash
# TEST_DESC: Compile bleproxy and dry-run OTA (no flash)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

mac=$(test_ensure_mac bleproxy) || true

if [[ -n "$mac" ]]; then
  test_run_step "iotstack update ${mac} bleproxy --dry-run" \
    test_iotstack update "$mac" bleproxy --dry-run
else
  test_run_step "iotstack update bleproxy --dry-run" \
    test_iotstack update bleproxy --dry-run
fi