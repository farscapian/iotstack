#!/bin/bash
# TEST_DESC: iotstack devices reports both slot hashes (from the shared NVS namespace)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac bleproxy) || { test_fail "No bleproxy device on network"; exit 1; }

row=$(test_iotstack devices --json 2>/dev/null | jq -c --arg id "$mac" '.[] | select(.id == $id)')
[[ -z "$row" ]] && { test_fail "TEST_MAC=$mac not in devices --json"; exit 1; }

bootstrap_hash=$(echo "$row" | jq -r '.bootstrap_image_hash // ""')
production_hash=$(echo "$row" | jq -r '.production_image_hash // ""')
test_info "bootstrap_image_hash=${bootstrap_hash:-<none>} production_image_hash=${production_hash:-<none>}"

rc=0
# Both hashes come from the shared iotstack NVS namespace, so the running slot
# reports the other slot too -- whichever partition the device booted from.
if [[ -z "$production_hash" ]]; then
  test_fail "No production_image_hash for $mac"
  rc=1
fi
if [[ -z "$bootstrap_hash" ]]; then
  test_fail "No bootstrap_image_hash for $mac (device may predate the NVS image hashes)"
  rc=1
fi
[[ $rc -eq 0 ]] && test_ok "Both slot hashes reported for TEST_MAC=$mac"
exit $rc
