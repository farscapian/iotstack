#!/bin/bash
# TEST_DESC: Force OTA reflash of ledlightstrip
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac ledlightstrip) || { test_fail "No ledlightstrip device on network"; exit 1; }

test_run_step "iotstack update ${mac} ledlightstrip --erase" \
  test_iotstack update "$mac" ledlightstrip --erase