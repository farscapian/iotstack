#!/bin/bash
# TEST_DESC: List bleproxy production devices on network
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac bleproxy) || { test_fail "No bleproxy device on network"; exit 1; }

output=$(test_iotstack devices bleproxy --production --id 2>/dev/null)
test_info "devices bleproxy --production --id: $output"

if echo "$output" | grep -qi "$mac"; then
  test_ok "Production device includes TEST_MAC=$mac"
else
  test_fail "TEST_MAC=$mac not found in bleproxy device list"
  exit 1
fi