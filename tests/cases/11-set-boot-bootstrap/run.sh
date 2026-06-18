#!/bin/bash
# TEST_DESC: Set boot partition to bootstrap (network, by MAC)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac bleproxy) || { test_fail "No bleproxy MAC on network"; exit 1; }

test_run_step "iotstack set-boot ${mac} bootstrap" \
  test_iotstack set-boot "$mac" bootstrap

sleep 15
test_discover_mac bootstrap >/dev/null 2>&1 || test_warn "bootstrap role not visible yet after set-boot"