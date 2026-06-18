#!/bin/bash
# TEST_DESC: List failsafe devices on network (mDNS)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac bleproxy) || true

output=$(test_iotstack failsafe --id 2>/dev/null || true)
test_info "failsafe --id: ${output:-<none>}"

if [[ -n "$mac" ]] && echo "$output" | grep -qi "$mac"; then
  test_ok "Failsafe device includes TEST_MAC=$mac"
else
  test_warn "TEST_MAC not in failsafe list (device may be on production partition)"
fi