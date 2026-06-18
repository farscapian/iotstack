#!/bin/bash
# TEST_DESC: Set boot partition to failsafe (network, by MAC)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

mac=$(test_ensure_mac bleproxy) || { test_fail "No bleproxy MAC on network"; exit 1; }

test_run_step "iotstack set-boot ${mac} failsafe" \
  test_iotstack set-boot "$mac" failsafe

sleep 15
test_discover_mac failsafe >/dev/null 2>&1 || test_warn "failsafe role not visible yet after set-boot"