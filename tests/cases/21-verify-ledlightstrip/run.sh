#!/bin/bash
# TEST_DESC: Verify ledlightstrip firmware matches current build
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/common.sh"

test_run_step "iotstack verify ledlightstrip" \
  test_iotstack verify ledlightstrip