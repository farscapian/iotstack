#!/bin/bash
# TEST_DESC: List ledlightstrip devices on network (ESP32-S3)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac ledlightstrip) || { test_fail "No ledlightstrip device on network"; exit 1; }

mdns_name=$(yaml_mdns_name_for_role ledlightstrip)
output=$(test_iotstack devices "$mdns_name" --id 2>/dev/null)
test_info "devices ${mdns_name} --id: $output"

if echo "$output" | grep -qi "$mac"; then
  test_ok "Production device includes TEST_MAC_ledlightstrip=$mac"
else
  test_fail "MAC $mac not found in ledlightstrip device list"
  exit 1
fi