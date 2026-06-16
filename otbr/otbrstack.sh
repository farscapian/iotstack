#!/usr/bin/env bash
# Backward-compatible wrapper — prefer: iotstack otbr ...

_IOTSTACK_SCRIPT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/iotstack.sh"

if [[ ! -x "$_IOTSTACK_SCRIPT" ]]; then
    echo "[otbr] iotstack.sh not found at ${_IOTSTACK_SCRIPT}" >&2
    exit 1
fi

echo "[otbr] Note: otbrstack is deprecated; use: iotstack otbr ..." >&2
exec "$_IOTSTACK_SCRIPT" otbr "$@"