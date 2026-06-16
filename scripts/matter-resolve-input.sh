#!/usr/bin/env bash
# matter-resolve-input.sh — Resolve Matter onboarding input to an MT/manual payload.
#
# Accepts:
#   - MT: setup payload string (from decode-qr or label)
#   - manual pairing code 0000-000-0000
#   - path to a QR code image (decoded with zbarimg)
#
# Sets: MATTER_RESOLVED_PAYLOAD, MATTER_RESOLVED_INPUT_KIND
# Exits non-zero with message on stderr when resolution fails.

set -euo pipefail

matter_resolve_onboarding_input() {
    local input="${1:-}"
    local trimmed="" payload="" kind=""

    trimmed="$(printf '%s' "${input}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -n "${trimmed}" ]] || return 1

    MATTER_RESOLVED_PAYLOAD=""
    MATTER_RESOLVED_INPUT_KIND=""

    if [[ "${trimmed}" =~ ^[0-9]{4}-[0-9]{3}-[0-9]{4}$ ]]; then
        payload="${trimmed//-}"
        kind="manual pairing code"
    elif [[ "${trimmed}" =~ ^[Mm][Tt]:[A-Za-z0-9.\-]+$ ]]; then
        payload="MT:${trimmed#*[Mm][Tt]:}"
        kind="Matter QR payload"
    elif [[ -f "${trimmed}" ]]; then
        command -v zbarimg &>/dev/null || {
            echo "[error] zbarimg not found. Install with: sudo apt install zbar-tools" >&2
            return 1
        }
        payload="$(zbarimg --raw "${trimmed}" 2>/dev/null | grep "^MT:" | head -1 || true)"
        [[ -n "${payload}" ]] || {
            echo "[error] No Matter QR code found in image: ${trimmed}" >&2
            return 1
        }
        kind="QR image"
    else
        echo "[error] Not a QR image, manual pairing code (0000-000-0000), or MT: payload: ${trimmed}" >&2
        return 1
    fi

    if [[ "${kind}" == "manual pairing code" ]]; then
        [[ "${payload}" =~ ^[0-9]{11}$ ]] || {
            echo "[error] Invalid manual pairing code: ${trimmed}" >&2
            return 1
        }
    elif [[ ! "${payload}" =~ ^MT:[A-Za-z0-9.\-]+$ ]]; then
        echo "[error] Invalid Matter payload format: ${payload}" >&2
        return 1
    fi

    export MATTER_RESOLVED_PAYLOAD="${payload}"
    export MATTER_RESOLVED_INPUT_KIND="${kind}"
    return 0
}