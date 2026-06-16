#!/usr/bin/env bash
# matter-decode-qr.sh — Extract Matter MT: payload from a QR code image.
# Usage: matter-decode-qr.sh <path-to-image>

set -euo pipefail

die() { echo "[error] $*" >&2; exit 1; }

IMAGE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help | help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --)
            shift
            [[ $# -ge 1 ]] || die "Usage: $0 <path-to-image>"
            IMAGE="$1"
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            IMAGE="$1"
            shift
            break
            ;;
    esac
done

[[ -n "${IMAGE}" ]] || die "Usage: $0 <path-to-image>"
[[ -f "${IMAGE}" ]] || die "Not a file: ${IMAGE}"
command -v zbarimg &>/dev/null || die "zbarimg not found. Install with: sudo apt install zbar-tools"

MT_PAYLOAD="$(zbarimg --raw "${IMAGE}" 2>/dev/null | grep "^MT:" | head -1 || true)"
[[ -n "${MT_PAYLOAD}" ]] || die "No Matter QR code found in image: ${IMAGE}"

printf '%s\n' "${MT_PAYLOAD}"