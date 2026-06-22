#!/usr/bin/env bash
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "/home/derek/Sync/mini_projects/iotstack")"
exec "${ROOT}/.agentstartstack/scripts/init_grok_session.sh" "$@"
