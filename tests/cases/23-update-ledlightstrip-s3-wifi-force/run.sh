#!/bin/bash
# TEST_DESC: Update ledlightstrip-s3-wifi (already current after flash -- confirms delta skip, no error)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

mac=$(test_ensure_mac ledlightstrip-s3-wifi) || { test_fail "No ledlightstrip-s3-wifi device on network"; exit 1; }

test_run_step "iotstack update ${mac} ledlightstrip-s3-wifi" \
  test_iotstack update "$mac" ledlightstrip-s3-wifi
