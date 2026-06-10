#!/usr/bin/env bash
# matter-commission.sh
# Scans a Matter QR code via zbarcam, decodes the payload, commissions the device
# via chip-tool (Thread), then opens a commissioning window and hands off to HA.
#
# Dependencies: zbar-tools, chip-tool, curl, python3
# Usage:
#   ./matter-commission.sh                        # scan via zbarcam
#   ./matter-commission.sh "MT:CUO00UDN168Q..."   # use provided payload directly

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HOME}/.iotstack/matter-commission.env"

# ---------------------------------------------------------------------------
# 1. Stub out .env if it doesn't exist
# ---------------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
    mkdir -p "$(dirname "${ENV_FILE}")"
    cat > "${ENV_FILE}" << 'EOF'
# Thread dataset in hex (from: ot-ctl dataset active -x  or  dbus-send to OTBR)
THREAD_DATASET_HEX=""

# Home Assistant
HA_URL="http://homeassistant.local:8123"
HA_TOKEN=""

# Auto-incrementing node ID (updated by script after each successful commission)
NEXT_NODE_ID=1
EOF
    echo "[info] Created stub ${ENV_FILE} — fill it in and re-run."
    exit 0
fi

# shellcheck source=/dev/null
source "${ENV_FILE}"

# ---------------------------------------------------------------------------
# 2. Validate required env vars
# ---------------------------------------------------------------------------
die() { echo "[error] $*" >&2; exit 1; }

[[ -n "${THREAD_DATASET_HEX:-}" ]] || die "THREAD_DATASET_HEX is not set in ${ENV_FILE}"
[[ -n "${HA_URL:-}"             ]] || die "HA_URL is not set in ${ENV_FILE}"
[[ -n "${HA_TOKEN:-}"           ]] || die "HA_TOKEN is not set in ${ENV_FILE}"
[[ -n "${NEXT_NODE_ID:-}"       ]] || die "NEXT_NODE_ID is not set in ${ENV_FILE}"

NODE_ID="${NEXT_NODE_ID}"

# ---------------------------------------------------------------------------
# 3. Decode Matter QR payload  (pure Python, no extra deps)
# ---------------------------------------------------------------------------
decode_matter_qr() {
    local payload="$1"
    python3 - "${payload}" << 'PYEOF'
import sys

BASE38 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-."

def b38_decode(s):
    v = 0
    for c in reversed(s):
        v = v * 38 + BASE38.index(c)
    return v

payload = sys.argv[1]
assert payload.startswith("MT:"), "Not a Matter payload"
encoded = payload[3:]

bits = 0
bit_len = 0
i = 0
while i < len(encoded):
    chunk = encoded[i:i+5]
    val = b38_decode(chunk)
    if len(chunk) == 5:
        nbits = 24
    elif len(chunk) == 4:
        nbits = 20
    elif len(chunk) == 3:
        nbits = 16
    elif len(chunk) == 2:
        nbits = 12
    else:
        nbits = 6
    bits |= val << bit_len
    bit_len += nbits
    i += 5

def extract(v, start, length):
    return (v >> start) & ((1 << length) - 1)

discriminator = extract(bits, 45, 12)
passcode      = extract(bits, 57, 27)

# Build 11-digit manual pairing code
short_disc  = (discriminator >> 8) & 0xF
chunk2_val  = (short_disc << 14) | (passcode & 0x3FFF)
chunk3_val  = passcode >> 14
digits      = f"{chunk2_val:06d}{chunk3_val:04d}"

MULT = [
    [0,1,2,3,4,5,6,7,8,9],[1,2,3,4,0,6,7,8,9,5],[2,3,4,0,1,7,8,9,5,6],
    [3,4,0,1,2,8,9,5,6,7],[4,0,1,2,3,9,5,6,7,8],[5,9,8,7,6,0,4,3,2,1],
    [6,5,9,8,7,1,0,4,3,2],[7,6,5,9,8,2,1,0,4,3],[8,7,6,5,9,3,2,1,0,4],
    [9,8,7,6,5,4,3,2,1,0],
]
PERM = [
    [0,1,2,3,4,5,6,7,8,9],[1,5,7,6,2,8,3,0,9,4],[5,8,0,3,7,9,6,1,4,2],
    [8,9,1,6,0,4,3,5,2,7],[9,4,5,3,1,2,6,8,7,0],[4,2,8,6,5,7,3,9,0,1],
    [2,7,9,3,8,0,6,4,1,5],[7,0,4,6,9,1,3,2,5,8],
]
INV = [0,4,3,2,1,9,8,7,6,5]

c = 0
for i2, ch in enumerate(reversed(digits)):
    c = MULT[c][PERM[(i2+1) % 8][int(ch)]]
check = INV[c]
full = digits + str(check)

print(f"DISCRIMINATOR={discriminator}")
print(f"PASSCODE={passcode}")
print(f"MANUAL_CODE={full}")
PYEOF
}

# ---------------------------------------------------------------------------
# 4. Get Matter payload — from argument or zbarcam
# ---------------------------------------------------------------------------
MT_PAYLOAD=""

if [[ $# -ge 1 ]]; then
    ARG="${1}"
    if [[ "${ARG}" == MT:* ]]; then
        MT_PAYLOAD="${ARG}"
        echo "[info] Using provided payload: ${MT_PAYLOAD}"
    else
        die "Argument does not look like a Matter payload (expected MT:...): ${ARG}"
    fi
else
    echo "[info] Point camera at Matter QR code... (Ctrl-C to abort)"
    while [[ -z "${MT_PAYLOAD}" ]]; do
        RAW="$(zbarcam --raw --oneshot -q 2>/dev/null | tr -d '[:space:]')" || true
        if [[ "${RAW}" == MT:* ]]; then
            MT_PAYLOAD="${RAW}"
            echo "[info] Got payload: ${MT_PAYLOAD}"
        else
            [[ -n "${RAW}" ]] && echo "[info] Ignoring non-Matter scan: ${RAW}"
        fi
    done
fi

# ---------------------------------------------------------------------------
# 5. Decode
# ---------------------------------------------------------------------------
echo "[info] Decoding Matter payload..."
DECODED="$(decode_matter_qr "${MT_PAYLOAD}")"
echo "${DECODED}"

eval "${DECODED}"   # sets DISCRIMINATOR, PASSCODE, MANUAL_CODE

echo "[info] Node ID:      ${NODE_ID}"
echo "[info] Discriminator: ${DISCRIMINATOR}"
echo "[info] Passcode:      ${PASSCODE}"
echo "[info] Manual code:   ${MANUAL_CODE:0:4}-${MANUAL_CODE:4:3}-${MANUAL_CODE:7}"

# ---------------------------------------------------------------------------
# 6. Commission via chip-tool (Thread)
# ---------------------------------------------------------------------------
echo "[info] Commissioning node ${NODE_ID} via chip-tool (Thread)..."
chip-tool pairing code-thread \
    "${NODE_ID}" \
    "${THREAD_DATASET_HEX}" \
    "${MT_PAYLOAD}"

echo "[info] Commission complete."

# ---------------------------------------------------------------------------
# 7. Open commissioning window (Enhanced Commissioning Method, 15 min timeout)
# ---------------------------------------------------------------------------
echo "[info] Opening commissioning window for HA handoff..."

# endpoint 0, timeout 900s, iterations 1000, discriminator reuse
WINDOW_OUTPUT="$(chip-tool pairing open-commissioning-window \
    "${NODE_ID}" \
    1 \
    900 \
    1000 \
    "${DISCRIMINATOR}" 2>&1)"

echo "${WINDOW_OUTPUT}"

# Extract the pairing code printed by chip-tool for the new window
WINDOW_CODE="$(echo "${WINDOW_OUTPUT}" \
    | grep -oP '(?<=Manual pairing code: \[)[^\]]+' \
    || echo "")"

if [[ -z "${WINDOW_CODE}" ]]; then
    echo "[warn] Could not extract window pairing code from chip-tool output."
    echo "[info] You may need to enter the device manually in HA."
fi

# ---------------------------------------------------------------------------
# 8. Notify HA via WebSocket / REST to adopt the device
# ---------------------------------------------------------------------------
echo "[info] Triggering HA Matter commission..."

# HA Matter integration accepts a manual code via the config_entries/flow API
FLOW_RESPONSE="$(curl -sf \
    -X POST \
    -H "Authorization: Bearer ${HA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{"handler":"matter","show_advanced_options":false}' \
    "${HA_URL}/api/config/config_entries/flow")"

FLOW_ID="$(echo "${FLOW_RESPONSE}" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('flow_id',''))")"

if [[ -z "${FLOW_ID}" ]]; then
    die "Failed to start HA Matter config flow. Response: ${FLOW_RESPONSE}"
fi

echo "[info] HA flow ID: ${FLOW_ID}"

# Submit the manual pairing code to the flow
ADOPT_RESPONSE="$(curl -sf \
    -X POST \
    -H "Authorization: Bearer ${HA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"code\":\"${WINDOW_CODE}\"}" \
    "${HA_URL}/api/config/config_entries/flow/${FLOW_ID}")"

echo "[info] HA adoption response: ${ADOPT_RESPONSE}"

RESULT_TYPE="$(echo "${ADOPT_RESPONSE}" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('type',''))")"

if [[ "${RESULT_TYPE}" == "create_entry" ]]; then
    echo "[info] HA successfully adopted the device."
else
    echo "[warn] HA flow result type: '${RESULT_TYPE}' — may need manual follow-up in HA UI."
    echo "[info] Manual pairing code for HA: ${WINDOW_CODE}"
fi

# ---------------------------------------------------------------------------
# 9. Increment NEXT_NODE_ID in .env
# ---------------------------------------------------------------------------
NEXT="$(( NODE_ID + 1 ))"
sed -i "s/^NEXT_NODE_ID=.*/NEXT_NODE_ID=${NEXT}/" "${ENV_FILE}"
echo "[info] NEXT_NODE_ID incremented to ${NEXT} in ${ENV_FILE}"

echo "[done] Node ${NODE_ID} commissioned and handed off to HA."
