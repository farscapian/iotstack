#!/bin/bash
# TEST_DESC: Flash bootstrap on C6 then OTA reassign to bleproxy
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

test_require_tty_bootstrap

test_run_step "iotstack flash bootstrap ${IOTSTACK_TEST_TTY}" \
  test_iotstack flash bootstrap "$IOTSTACK_TEST_TTY"

# Discover bootstrap MAC (hostname bootstrap-<mac>)
mac=""
mac=$(test_iotstack bootstrap --id 2>/dev/null | tr '\n' ' ')
read -r mac _ <<< "$mac"
mac=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
[[ "$mac" =~ ^[0-9a-f]{6}$ ]] || { test_fail "No bootstrap device on network after flash"; exit 1; }
test_save_state "TEST_MAC_bleproxy" "$mac"
test_ok "Bootstrap MAC: $mac"

test_run_step "iotstack reassign ${mac} bleproxy" \
  test_iotstack reassign "$mac" bleproxy

test_discover_mac bleproxy >/dev/null 2>&1 || true