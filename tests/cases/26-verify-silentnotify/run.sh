#!/bin/bash
# TEST_DESC: Verify silentnotify firmware on reassigned S3 device
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

test_run_step "iotstack verify silentnotify" \
  test_iotstack verify silentnotify