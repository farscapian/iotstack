#!/bin/bash
# TEST_DESC: Reassign test device to mmwave via failsafe OTA
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac bleproxy) || { test_fail "No bleproxy MAC on network"; exit 1; }

test_run_step "iotstack reassign ${mac} mmwave" \
  test_iotstack reassign "$mac" mmwave