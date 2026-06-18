#!/bin/bash
# TEST_DESC: Reassign S3 device back to ledlightstrip
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac silentnotify) || mac=$(test_ensure_mac ledlightstrip) || {
  test_fail "No S3 device MAC on network"; exit 1;
}

test_run_step "iotstack reassign ${mac} ledlightstrip" \
  test_iotstack reassign "$mac" ledlightstrip

test_discover_mac ledlightstrip >/dev/null 2>&1 || true