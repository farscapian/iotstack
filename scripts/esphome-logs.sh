#!/bin/bash
# esphome-logs.sh -- stream logs from an ESPHome device (native API).
# Runs esphome_logs.py under the esphome venv python (which ships aioesphomeapi).
# The device API key is passed in IOTSTACK_API_NOISE_PSK, never written to disk.
#
# Usage: IOTSTACK_API_NOISE_PSK=<b64> scripts/esphome-logs.sh <host>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

host="${1:-}"
if [[ -z "$host" ]]; then
  echo "usage: $(basename "$0") <host>" >&2
  exit 64
fi

# Locate the esphome venv python (ships aioesphomeapi)
esphome_py=""
if command -v esphome >/dev/null 2>&1; then
  esphome_py=$(head -1 "$(command -v esphome)" | sed 's/^#!//')
fi
[[ -x "$esphome_py" ]] || esphome_py="${HOME}/.local/esphome/venv/bin/python3"
if [[ ! -x "$esphome_py" ]]; then
  echo "[ERROR] esphome venv python (with aioesphomeapi) not found" >&2
  exit 1
fi

exec "$esphome_py" -u "${SCRIPT_DIR}/esphome_logs.py" "$host"
