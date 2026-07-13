#!/bin/bash
# esphome-button.sh -- press a button entity on an ESPHome device (native API).
# Runs esphome_button.py under the esphome venv python (which ships
# aioesphomeapi).
#
# Usage: scripts/esphome-button.sh <host> <object_id> [api_password]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

host="${1:-}"
object_id="${2:-}"
password="${3:-}"
if [[ -z "$host" || -z "$object_id" ]]; then
  echo "usage: $(basename "$0") <host> <object_id> [api_password]" >&2
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

exec "$esphome_py" "${SCRIPT_DIR}/esphome_button.py" "$host" "$object_id" "$password"
