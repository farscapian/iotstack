#!/usr/bin/env bash
# matter-configure-trust-store.sh
# Interactive Matter attestation trust store for chip-tool commissioning.
#
# Usage:
#   ./matter-configure-trust-store.sh
#   ./matter-configure-trust-store.sh <manual-pairing-code>
#   ./matter-configure-trust-store.sh "MT:..."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ensure-chip-tool-trust-store.sh
source "${SCRIPT_DIR}/ensure-chip-tool-trust-store.sh"

die() { echo "[error] $*" >&2; exit 1; }

INPUT="${1:-}"
PAYLOAD=""

if [[ -n "$INPUT" ]]; then
    if [[ "$INPUT" =~ ^MT: ]]; then
        PAYLOAD="$INPUT"
    elif [[ "$INPUT" =~ ^[0-9]{4}-[0-9]{3}-[0-9]{4}$ ]]; then
        PAYLOAD="${INPUT//-/}"
    elif [[ "$INPUT" =~ ^[0-9]{11}$ ]]; then
        PAYLOAD="$INPUT"
    else
        die "Optional argument must be a manual pairing code (0000-000-0000) or MT: payload"
    fi
fi

configure_chip_tool_attestation_trust "${PAYLOAD}"