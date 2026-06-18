#!/bin/bash
# TEST_DESC: Reassign device back to bleproxy
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac bleproxy) || mac=$(test_ensure_mac mmwave) || { test_fail "No device MAC on network"; exit 1; }

test_run_step "iotstack reassign ${mac} bleproxy" \
  test_iotstack reassign "$mac" bleproxy