#!/bin/bash
# TEST_DESC: List ledlightstrip-s3-wifi devices on network (ESP32-S3)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac ledlightstrip-s3-wifi) || { test_fail "No ledlightstrip-s3-wifi device on network"; exit 1; }

mdns_name=$(yaml_mdns_name_for_role ledlightstrip-s3-wifi)
output=$(test_iotstack devices "$mdns_name" --production --id 2>/dev/null)
test_info "devices ${mdns_name} --production --id: $output"

if echo "$output" | grep -qi "$mac"; then
  test_ok "Production device includes TEST_MAC_ledlightstrip-s3-wifi=$mac"
else
  test_fail "MAC $mac not found in ledlightstrip-s3-wifi device list"
  exit 1
fi