#!/bin/bash
# TEST_DESC: Flash failsafe on C6 then OTA reassign to bleproxy
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

test_require_tty_failsafe

test_run_step "iotstack flash failsafe ${IOTSTACK_TEST_TTY}" \
  test_iotstack flash failsafe "$IOTSTACK_TEST_TTY"

# Discover failsafe MAC (hostname failsafe-<mac>)
mac=""
mac=$(test_iotstack failsafe --id 2>/dev/null | tr '\n' ' ')
read -r mac _ <<< "$mac"
mac=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
[[ "$mac" =~ ^[0-9a-f]{6}$ ]] || { test_fail "No failsafe device on network after flash"; exit 1; }
test_save_state "TEST_MAC_bleproxy" "$mac"
test_ok "Failsafe MAC: $mac"

test_run_step "iotstack reassign ${mac} bleproxy" \
  test_iotstack reassign "$mac" bleproxy

test_discover_mac bleproxy >/dev/null 2>&1 || true