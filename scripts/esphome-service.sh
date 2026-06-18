#!/bin/bash
# esphome-service.sh -- call a native-API user service on an ESPHome device.
# Runs esphome_service.py under the esphome venv python (which ships
# aioesphomeapi).
#
# Usage: scripts/esphome-service.sh <host> <service_name> [api_password [json_variables]]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

host="${1:-}"
service="${2:-}"
password="${3:-}"
json_vars="${4:-}"
if [[ -z "$host" || -z "$service" ]]; then
  echo "usage: $(basename "$0") <host> <service_name> [api_password [json_vars]]" >&2
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

exec "$esphome_py" "${SCRIPT_DIR}/esphome_service.py" "$host" "$service" "$password" "$json_vars"
