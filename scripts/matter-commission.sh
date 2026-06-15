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
# shellcheck source=scripts/ensure-integration-secrets.sh
source "${SCRIPT_DIR}/ensure-integration-secrets.sh"

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
    { echo "$value"; echo "$value"; } | pass insert -f "$key" >/dev/null 2>&1 || return 1
}

# ---------------------------------------------------------------------------
# 2. Load and validate integration secrets (prompt if missing)
# ---------------------------------------------------------------------------
info "Checking Matter commissioning prerequisites..."

ensure_ha_integration
ensure_thread_tlv "false"

NEXT_NODE_ID=$(get_secret "iotstack/matter/next_node_id")
[[ -n "${NEXT_NODE_ID:-}" ]] || {
    info "Initializing NEXT_NODE_ID to 1..."
    set_secret "iotstack/matter/next_node_id" "1" || die "Failed to initialize NEXT_NODE_ID"
    NEXT_NODE_ID="1"
}

NODE_ID="${NEXT_NODE_ID}"


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
# 5. Validate payload format
# ---------------------------------------------------------------------------
if [[ ! "${MT_PAYLOAD}" =~ ^MT:[A-Z0-9\.\-]+$ ]]; then
    die "Invalid Matter payload format: ${MT_PAYLOAD}"
fi

echo "[info] QR payload: ${MT_PAYLOAD}"
echo "[info] Node ID:   ${NODE_ID}"
echo "[info] chip-tool will decode the payload during commissioning"
echo ""

# ---------------------------------------------------------------------------
# 5a. Wait for device to become commissionable
# ---------------------------------------------------------------------------
echo "[info] Ensure the device is powered on and in commissioning mode."
echo "[info] Waiting for device to advertise as commissionable..."
echo ""

MAX_WAIT=60
WAITED=0

while [[ $WAITED -lt $MAX_WAIT ]]; do
    # Attempt discovery with --discover-once to do a single scan
    DISCOVER_OUTPUT=$(chip-tool discover commissionables --discover-once 2>&1 || true)

    # Check if any commissionable devices were found
    if echo "$DISCOVER_OUTPUT" | grep -q "Discriminator:"; then
        info "Commissionable device(s) found!"
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
# 8. Notify HA via WebSocket to adopt the device
# ---------------------------------------------------------------------------
echo "[info] Triggering HA Matter commission via WebSocket..."

# Use Python to handle WebSocket connection and commissioning
python3 << 'PYTHON_EOF' "${HA_URL}" "${HA_TOKEN}" "${WINDOW_CODE}"
import sys
import json
import websocket
import time

ha_url = sys.argv[1]
ha_token = sys.argv[2]
window_code = sys.argv[3]

# Convert HTTP(S) URL to WebSocket URL
ws_url = ha_url.replace("http://", "ws://").replace("https://", "wss://")
ws_url = f"{ws_url}/api/websocket"

try:
    ws = websocket.create_connection(ws_url, timeout=10)

    # Step 1: Receive type: auth_required
    auth_msg = json.loads(ws.recv())
    if auth_msg.get("type") != "auth_required":
        print(f"[error] Unexpected message type: {auth_msg.get('type')}")
        sys.exit(1)

    # Step 2: Send authentication
    ws.send(json.dumps({
        "type": "auth",
        "access_token": ha_token
    }))

    # Step 3: Receive auth_ok
    auth_ok = json.loads(ws.recv())
    if auth_ok.get("type") != "auth_ok":
        print(f"[error] Authentication failed: {auth_ok.get('message', 'Unknown error')}")
        sys.exit(1)

    print("[info] HA WebSocket authenticated successfully")

    # Step 4: Subscribe to config entry flow updates
    ws.send(json.dumps({
        "id": 1,
        "type": "subscribe_events",
        "event_type": "config_entry_options_updated"
    }))

    # Step 5: Start Matter commissioning flow
    ws.send(json.dumps({
        "id": 2,
        "type": "call_service",
        "domain": "config_entries",
        "service": "flow_start",
        "service_data": {
            "handler": "matter"
        }
    }))

    # Step 6: Wait for flow start response and extract flow_id
    flow_id = None
    max_wait = 5
    start_time = time.time()

    while time.time() - start_time < max_wait:
        try:
            msg = json.loads(ws.recv())
            if msg.get("id") == 2 and msg.get("type") == "result":
                if msg.get("success"):
                    print("[info] HA Matter commissioning flow started")
                    flow_id = msg.get("result", {}).get("flow_id")
                    break
                else:
                    print(f"[error] Failed to start flow: {msg.get('error', {}).get('message')}")
                    sys.exit(1)
        except json.JSONDecodeError:
            continue

    if not flow_id:
        print("[error] Timeout waiting for flow_id")
        sys.exit(1)

    print(f"[info] HA flow ID: {flow_id}")

    # Step 7: Submit the pairing code to the flow
    ws.send(json.dumps({
        "id": 3,
        "type": "call_service",
        "domain": "config_entries",
        "service": "flow_progress",
        "service_data": {
            "flow_id": flow_id,
            "user_input": {
                "code": window_code
            }
        }
    }))

    # Step 8: Wait for commissioning result
    max_wait = 30
    start_time = time.time()

    while time.time() - start_time < max_wait:
        try:
            msg = json.loads(ws.recv())
            if msg.get("id") == 3 and msg.get("type") == "result":
                if msg.get("success"):
                    result = msg.get("result", {})
                    if result.get("type") == "create_entry":
                        print("[info] HA successfully adopted the device via WebSocket")
                    else:
                        print(f"[warn] HA flow result type: '{result.get('type')}' — may need manual follow-up")
                        print(f"[info] Manual pairing code: {window_code}")
                else:
                    print(f"[warn] Flow submission failed: {msg.get('error', {}).get('message')}")
                    print(f"[info] Manual pairing code for HA: {window_code}")
                break
        except json.JSONDecodeError:
            continue

    ws.close()

except Exception as e:
    print(f"[error] WebSocket error: {e}")
    print(f"[info] Manual pairing code for HA: {window_code}")
    sys.exit(1)

PYTHON_EOF

# ---------------------------------------------------------------------------
# 9. Increment NEXT_NODE_ID in pass store
# ---------------------------------------------------------------------------
NEXT="$(( NODE_ID + 1 ))"
set_secret "iotstack/matter/next_node_id" "$NEXT" || warn "Failed to update NEXT_NODE_ID in pass"
info "NEXT_NODE_ID incremented to ${NEXT}"

echo "[done] Node ${NODE_ID} commissioned and handed off to HA."
