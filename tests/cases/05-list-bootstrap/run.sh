#!/bin/bash
# TEST_DESC: List bootstrap devices on network (mDNS)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac bleproxy) || true

output=$(test_iotstack devices --bootstrap --id 2>/dev/null || true)
test_info "devices --bootstrap --id: ${output:-<none>}"

if [[ -n "$mac" ]] && echo "$output" | grep -qi "$mac"; then
  test_ok "Bootstrap device includes TEST_MAC=$mac"
else
  test_warn "TEST_MAC not in bootstrap list (device may be on production partition)"
fi