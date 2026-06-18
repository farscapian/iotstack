#!/bin/bash
# TEST_DESC: OTA update bleproxy (delta -- skip if hash matches)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac bleproxy) || { test_fail "No bleproxy device on network"; exit 1; }

test_run_step "iotstack update ${mac} bleproxy (delta)" \
  test_iotstack update "$mac" bleproxy