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

# ---------------------------------------------------------------------------
# 1. Helper functions
# ---------------------------------------------------------------------------
die() { echo "[error] $*" >&2; exit 1; }
info() { echo "[info] $*"; }
warn() { echo "[warn] $*"; }

# Get secret from pass store
get_secret() {
    local key="$1"
    pass show "$key" 2>/dev/null || echo ""
}

# Set secret in pass store (requires double-entry for confirmation)
set_secret() {
    local key="$1"
    local value="$2"
    { echo "$value"; echo "$value"; } | pass insert -f "$key" 2>&1 >/dev/null || return 1
}

# ---------------------------------------------------------------------------
# 2. Load secrets from pass store
# ---------------------------------------------------------------------------
info "Loading Matter commissioning secrets from pass..."

THREAD_TLV=$(get_secret "iotstack/common/thread_tlv")
HA_URL=$(get_secret "iotstack/common/ha_url")
HA_TOKEN=$(get_secret "iotstack/common/ha_token")
NEXT_NODE_ID=$(get_secret "iotstack/matter/next_node_id")

# Validate required secrets
[[ -n "${THREAD_TLV:-}" ]] || die "Thread TLV not found. Set with: pass insert iotstack/common/thread_tlv"
[[ -n "${HA_URL:-}" ]] || die "HA_URL not found. Set with: pass insert iotstack/common/ha_url"
[[ -n "${HA_TOKEN:-}" ]] || die "HA_TOKEN not found. Set with: pass insert iotstack/common/ha_token"
[[ -n "${NEXT_NODE_ID:-}" ]] || {
    info "Initializing NEXT_NODE_ID to 1..."
    set_secret "iotstack/matter/next_node_id" "1" || die "Failed to initialize NEXT_NODE_ID"
    NEXT_NODE_ID="1"
}

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

# Matter QR code bit layout:
# Bits 0-2: Version (3)
# Bits 3-14: VID (12)
# Bits 15-26: PID (12)
# Bits 27-39: Discriminator (13)
# Bits 40-66: Passcode (27)
# Bits 67-79: Future use (13)
# Bits 80-87: CRC (8)

discriminator = extract(bits, 27, 13)
passcode      = extract(bits, 40, 27)

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
# 4. Get Matter payload — from QR code image file
# ---------------------------------------------------------------------------
[[ $# -lt 1 ]] && die "Usage: $0 <path-to-qr-image>"

QR_IMAGE="$1"
[[ ! -f "$QR_IMAGE" ]] && die "QR code image not found: $QR_IMAGE"

# Check for zbarimg
command -v zbarimg &>/dev/null || die "zbarimg not found. Install with: sudo apt install zbar-tools"

# Decode QR code from image
info "Decoding QR code from: $QR_IMAGE"
MT_PAYLOAD=$(zbarimg --raw "$QR_IMAGE" 2>/dev/null | grep "^MT:" | head -1 || echo "")

[[ -z "$MT_PAYLOAD" ]] && die "No Matter QR code found in image. Ensure the image contains a valid Matter QR code."

info "Got payload: $MT_PAYLOAD"

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
echo ""

# ---------------------------------------------------------------------------
# 5a. Wait for device to become commissionable
# ---------------------------------------------------------------------------
echo "[info] Ensure the device is powered on and in commissioning mode."
echo "[info] Waiting for device to advertise as commissionable..."
echo ""

MAX_WAIT=60
WAITED=0
FOUND=false

while [[ $WAITED -lt $MAX_WAIT ]]; do
    # Attempt discovery with --discover-once to do a single scan
    DISCOVER_OUTPUT=$(chip-tool discover commissionables --discover-once 2>&1 || true)

    # Check if discriminator was found in output
    if echo "$DISCOVER_OUTPUT" | grep -q "Discriminator: ${DISCRIMINATOR}"; then
        info "Device found! Ready to commission."
        FOUND=true
        break
    fi

    # Show progress every 5 seconds
    if (( WAITED % 5 == 0 )); then
        printf "[info] Scanning... %d/%d seconds (press Ctrl-C to cancel)\n" "$WAITED" "$MAX_WAIT"
    fi

    sleep 1
    WAITED=$((WAITED + 1))
done

echo ""

if [[ "$FOUND" != "true" ]]; then
    warn "Device not found after ${MAX_WAIT} seconds, attempting commissioning anyway..."
fi

# ---------------------------------------------------------------------------
# 6. Commission via chip-tool (Thread)
# ---------------------------------------------------------------------------
echo "[info] Commissioning node ${NODE_ID} via chip-tool (Thread)..."
chip-tool pairing code-thread \
    "${NODE_ID}" \
    "${THREAD_TLV}" \
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
# 9. Increment NEXT_NODE_ID in pass store
# ---------------------------------------------------------------------------
NEXT="$(( NODE_ID + 1 ))"
set_secret "iotstack/matter/next_node_id" "$NEXT" || warn "Failed to update NEXT_NODE_ID in pass"
info "NEXT_NODE_ID incremented to ${NEXT}"

echo "[done] Node ${NODE_ID} commissioned and handed off to HA."
