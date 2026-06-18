#!/bin/bash
# TEST_DESC: Verify mmwave firmware on reassigned device
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

test_run_step "iotstack verify mmwave" \
  test_iotstack verify mmwave