#!/usr/bin/env bash
# matter-commission.sh
# Scans a Matter QR code via zbarcam, decodes the payload, commissions the device
# via chip-tool (Thread), then opens a commissioning window and hands off to HA.
#
# Device identity across runs uses Matter NodeLabel on the device (not pass).
#
# Dependencies: zbar-tools, chip-tool, curl, python3
# Usage:
#   ./matter-commission.sh <path-to-qr-image>
#   ./matter-commission.sh <manual-pairing-code>   # e.g. 0000-000-0000
#   ./matter-commission.sh "MT:CUO00UDN168Q..."     # Matter QR payload string

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ensure-integration-secrets.sh
source "${SCRIPT_DIR}/ensure-integration-secrets.sh"
# shellcheck source=scripts/ensure-chip-tool-storage.sh
source "${SCRIPT_DIR}/ensure-chip-tool-storage.sh"
# shellcheck source=scripts/ensure-chip-tool-trust-store.sh
source "${SCRIPT_DIR}/ensure-chip-tool-trust-store.sh"
# shellcheck source=scripts/matter-resolve-input.sh
source "${SCRIPT_DIR}/matter-resolve-input.sh"

# ---------------------------------------------------------------------------
# 1. Helper functions
# ---------------------------------------------------------------------------
die() { echo "[error] $*" >&2; exit 1; }
info() { echo "[info] $*" >&2; }
warn() { echo "[warn] $*" >&2; }

UNPAIR_TIMEOUT_SECS=45
CHIP_TOOL_OP_TIMEOUT_SECS=20
OPERATIONAL_CHIP_TOOL_TIMEOUT_SECS=45
OPERATIONAL_DISCOVERY_WAIT_SECS=300
OPERATIONAL_DISCOVERY_POLL_SECS=5
OPERATIONAL_POST_COMMISSION_GRACE_SECS=20
OPERATIONAL_MDNS_BROWSE_SECS=12
# chip-tool single-command timeout (seconds); commission includes operational CASE.
CHIP_TOOL_COMMISSION_TIMEOUT_SECS=600
# Keep sleepy ICD devices (e.g. IKEA MYGGSPRAY) awake through operational CASE.
ICD_STAY_ACTIVE_MS=180000
NODE_LABEL_PREFIX="iotstack:"

CHIP_TOOL_STORAGE="$(resolve_chip_tool_storage_dir)"
IOTSTACK_CHIP_TOOL_DIR="$(canonical_chip_tool_storage_dir)"

chip_tool_args() {
    echo --storage-directory "${CHIP_TOOL_STORAGE}"
    chip_tool_attestation_args
}

run_chip_tool() {
    # shellcheck disable=SC2046
    chip-tool "$@" $(chip_tool_args)
}

# Run chip-tool, capture full output in a named variable, and optionally stream
# lines as they arrive (MATTER_VERBOSE=1).
run_chip_tool_capture() {
    local var_name="$1"
    shift
    local tmp status
    tmp="$(mktemp)"

    if [[ "${MATTER_VERBOSE}" -eq 1 ]]; then
        set +e
        run_chip_tool "$@" 2>&1 | tee "$tmp"
        status=${PIPESTATUS[0]}
        set -e
    else
        set +e
        run_chip_tool "$@" 2>&1 >"$tmp"
        status=$?
        set -e
        cat "$tmp"
    fi

    printf -v "$var_name" '%s' "$(<"$tmp")"
    rm -f "$tmp"
    return "$status"
}

matter_fabric_py() {
    python3 - "$@" <<'PY'
import os
import re
import sys

action = sys.argv[1]
storage_dir = sys.argv[2] if len(sys.argv) > 2 else ""
node_id = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[3] else 0

def fabric_has_root(storage: str) -> bool:
    if not storage or not os.path.isdir(storage):
        return False
    for name in os.listdir(storage):
        if not name.startswith("chip_tool_config"):
            continue
        path = os.path.join(storage, name)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                if line.startswith("f/1/n=") or line.startswith("f/1/g="):
                    return True
    return False

def fabric_node_ids(storage: str) -> list[int]:
    if not storage or not os.path.isdir(storage):
        return []
    ids: set[int] = set()
    for name in os.listdir(storage):
        if not name.startswith("chip_tool_config"):
            continue
        path = os.path.join(storage, name)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                match = re.match(r"f/1/s/([0-9a-fA-F]{16})=", line)
                if match:
                    ids.add(int(match.group(1), 16))
    # --skip-commissioning-complete persists the fabric (f/1/n) before f/1/s sessions exist.
    if not ids and fabric_has_root(storage):
        ids.add(1)
    return sorted(ids)

def purge_local_node(storage: str, node_id: int) -> bool:
    if not storage or not os.path.isdir(storage):
        return False
    node_key = f"f/1/s/{node_id:016x}"
    changed = False
    for name in os.listdir(storage):
        if not name.startswith("chip_tool_config"):
            continue
        path = os.path.join(storage, name)
        if not os.path.isfile(path):
            continue
        with open(path, encoding="utf-8", errors="ignore") as handle:
            lines = handle.readlines()
        new_lines = [line for line in lines if not line.startswith(node_key + "=")]
        if len(new_lines) != len(lines):
            with open(path, "w", encoding="utf-8") as handle:
                handle.writelines(new_lines)
            changed = True
    return changed

if action == "fabric_nodes":
    for value in fabric_node_ids(storage_dir):
        print(value)
    sys.exit(0)

if action == "next_free_node_id":
    ids = fabric_node_ids(storage_dir)
    print((max(ids) + 1) if ids else 1)
    sys.exit(0)

if action == "purge":
    print("yes" if purge_local_node(storage_dir, node_id) else "no")
    sys.exit(0)

sys.exit(2)
PY
}

device_tag_for_pairing_key() {
    python3 - "$NODE_LABEL_PREFIX" "$1" <<'PY'
import hashlib
import sys

prefix = sys.argv[1]
pairing_key = sys.argv[2]
candidate = prefix + pairing_key
if len(candidate) <= 32:
    print(candidate)
else:
    digest = hashlib.sha256(pairing_key.encode()).hexdigest()[:12]
    print(prefix + digest)
PY
}

parse_node_label_from_chip_tool_output() {
    python3 - <<'PY'
import re
import sys

text = sys.stdin.read()
patterns = [
    r'NodeLabel[^"\n]*"([^"]+)"',
    r'"NodeLabel"\s*:\s*"([^"]+)"',
    r'node-label[^"\n]*"([^"]+)"',
    r'Data\s*=\s*"([^"]+)"',
]
for pattern in patterns:
    match = re.search(pattern, text, re.IGNORECASE)
    if match:
        print(match.group(1))
        break
PY
}

fabric_node_ids() {
    matter_fabric_py fabric_nodes "${CHIP_TOOL_STORAGE}"
}

next_free_fabric_node_id() {
    matter_fabric_py next_free_node_id "${CHIP_TOOL_STORAGE}"
}

read_device_node_label() {
    local node_id="$1"
    local output=""

    if ! output="$(timeout "${CHIP_TOOL_OP_TIMEOUT_SECS}" \
        run_chip_tool basicinformation read node-label "${node_id}" 0 2>&1)"; then
        return 1
    fi

    parse_node_label_from_chip_tool_output <<<"${output}"
}

write_device_node_label() {
    local node_id="$1"
    local tag="$2"

    timeout "${CHIP_TOOL_OP_TIMEOUT_SECS}" \
        run_chip_tool basicinformation write node-label "${tag}" "${node_id}" 0
}

find_node_by_device_tag() {
    local expected_tag="$1"
    local node_id="" label=""

    while IFS= read -r node_id; do
        [[ -n "${node_id}" ]] || continue
        label="$(read_device_node_label "${node_id}" 2>/dev/null || true)"
        if [[ "${label}" == "${expected_tag}" ]]; then
            printf '%s' "${node_id}"
            return 0
        fi
    done < <(fabric_node_ids)

    return 1
}

resolve_fabric_node_id() {
    local device_tag="$1"
    local node_id="" fabric_ids=()

    mapfile -t fabric_ids < <(fabric_node_ids)

    node_id="$(find_node_by_device_tag "${device_tag}" 2>/dev/null || true)"
    if [[ -n "${node_id}" ]]; then
        info "Found device on chip-tool fabric as node ${node_id} (NodeLabel match)"
        printf '%s already' "${node_id}"
        return 0
    fi

    if [[ ${#fabric_ids[@]} -eq 1 ]]; then
        node_id="${fabric_ids[0]}"
        warn "Single node ${node_id} on fabric without matching NodeLabel; reusing for bridge handoff"
        printf '%s reuse' "${node_id}"
        return 0
    fi

    node_id="$(next_free_fabric_node_id)"
    info "Assigning new chip-tool fabric node ID ${node_id}"
    printf '%s new' "${node_id}"
}

node_on_local_fabric() {
    local node_id="$1"
    local fabric_id

    while IFS= read -r fabric_id; do
        [[ "${fabric_id}" == "${node_id}" ]] && return 0
    done < <(fabric_node_ids)
    return 1
}

chip_tool_fabric_ini_present() {
    local config="${CHIP_TOOL_STORAGE}/chip_tool_config.ini"
    [[ -f "${config}" ]] && grep -qE '^f/1/(n|g)=' "${config}"
}

commission_output_confirms_node() {
    local node_id="$1"
    local output="$2"
    grep -qE "Commissioning complete for node ID 0x0*${node_id}: success" <<<"${output}"
}

commission_output_thread_joined() {
    local output="$1"
    grep -qE "Successfully finished commissioning step '(ThreadNetworkEnable|Cleanup|CommissioningComplete)'" <<<"${output}"
}

commission_output_ble_pase_failed() {
    local output="$1"
    grep -qiE 'Secure Pairing Failed|PASESession timed out|ack recv timeout|Pairing Failure:.*Timeout' <<<"${output}"
}

node_persisted_after_commission() {
    local node_id="$1"
    local output="$2"

    if node_on_local_fabric "${node_id}"; then
        return 0
    fi
    if commission_output_confirms_node "${node_id}" "${output}" && chip_tool_fabric_ini_present; then
        warn "Fabric persisted for node ${node_id} (f/1/n present; f/1/s session not written yet — normal with --skip-commissioning-complete)"
        return 0
    fi
    return 1
}

reset_chip_tool_fabric_storage() {
    local name=""

    info "Resetting chip-tool local fabric storage under ${CHIP_TOOL_STORAGE}..."
    shopt -s nullglob
    for name in \
        "${CHIP_TOOL_STORAGE}"/chip_tool_config*.ini \
        "${CHIP_TOOL_STORAGE}"/chip_tool_kvs \
        "${CHIP_TOOL_STORAGE}"/.compressed-fabric-id; do
        [[ -e "${name}" ]] && rm -f "${name}"
    done
    shopt -u nullglob
}

remove_node_from_local_fabric() {
    local node_id="$1"
    local unpair_output=""

    node_on_local_fabric "${node_id}" || return 0

    info "Removing node ${node_id} from chip-tool local fabric..."
    if unpair_output="$(timeout "${UNPAIR_TIMEOUT_SECS}" run_chip_tool pairing unpair "${node_id}" 2>&1)"; then
        info "chip-tool unpair succeeded for node ${node_id}"
        return 0
    fi

    if grep -qiE 'node.*not found|no such|unknown node|0x0000002F' <<<"${unpair_output}"; then
        return 0
    fi

    warn "chip-tool unpair failed or timed out for node ${node_id}; purging local storage entry"
    if [[ "$(matter_fabric_py purge "${CHIP_TOOL_STORAGE}" "${node_id}")" == "yes" ]]; then
        info "Purged local chip-tool storage for node ${node_id}"
    else
        warn "No local chip-tool storage entry found for node ${node_id}"
    fi
}

capture_chip_tool_compressed_fabric_id() {
    local output="" fabric_id="" window_disc="3840"

    set +e
    output="$(timeout 8 run_chip_tool pairing open-commissioning-window \
        1 1 1 1000 "${window_disc}" 2>&1)"
    set -e
    fabric_id="$(chip_tool_parse_compressed_fabric_id_from_output "${output}" || true)"
    if [[ -n "${fabric_id}" ]]; then
        chip_tool_save_compressed_fabric_id "${fabric_id}" || true
    fi
    printf '%s' "${fabric_id}"
}

ensure_chip_tool_compressed_fabric_id() {
    local output="${1:-}" fabric_id=""

    fabric_id="$(chip_tool_read_compressed_fabric_id 2>/dev/null || true)"
    [[ -n "${fabric_id}" ]] && printf '%s' "${fabric_id}" && return 0

    fabric_id="$(chip_tool_parse_compressed_fabric_id_from_output "${output}" || true)"
    if [[ -n "${fabric_id}" ]]; then
        chip_tool_save_compressed_fabric_id "${fabric_id}" || true
        printf '%s' "${fabric_id}"
        return 0
    fi

    fabric_id="$(chip_tool_probe_compressed_fabric_id_from_storage 2>/dev/null || true)"
    [[ -n "${fabric_id}" ]] && printf '%s' "${fabric_id}" && return 0

    fabric_id="$(capture_chip_tool_compressed_fabric_id)"
    [[ -n "${fabric_id}" ]] && printf '%s' "${fabric_id}" && return 0
    return 1
}

device_reachable_on_thread() {
    local node_id="$1"
    local output="" fabric_id="" mdns_visible=0

    if chip_tool_operational_mdns_visible "${node_id}"; then
        mdns_visible=1
    fi

    if ! output="$(timeout "${OPERATIONAL_CHIP_TOOL_TIMEOUT_SECS}" \
        run_chip_tool basicinformation read vendor-name "${node_id}" 0 2>&1)"; then
        if [[ "${mdns_visible}" -eq 1 ]]; then
            warn "Matter mDNS visible for node ${node_id} but CASE read timed out — wake the sensor and retry"
        fi
        return 1
    fi

    fabric_id="$(chip_tool_parse_compressed_fabric_id_from_output "${output}" || true)"
    if [[ -n "${fabric_id}" ]]; then
        chip_tool_save_compressed_fabric_id "${fabric_id}" || true
    fi
    return 0
}

wait_for_operational_node() {
    local node_id="$1"
    local waited=0
    local mdns_instance="" fabric_id=""

    fabric_id="$(ensure_chip_tool_compressed_fabric_id "" || true)"
    if [[ -n "${fabric_id}" ]]; then
        mdns_instance="$(chip_tool_operational_mdns_instance "${node_id}" 2>/dev/null || true)"
    fi

    info "Waiting for node ${node_id} on Thread (operational mDNS)..."
    if [[ -n "${mdns_instance}" ]]; then
        info "Expected _matter._tcp instance: ${mdns_instance}"
        info "Narrow check: iotstack matter mdns ${node_id}"
    fi
    info "Note: chip-tool shutdown log 'Forgetting fabric' is in-memory cleanup only; fabric is stored under ${CHIP_TOOL_STORAGE}"
    if [[ -f "${CHIP_TOOL_STORAGE}/chip_tool_config.ini" ]]; then
        info "Fabric ini present: ${CHIP_TOOL_STORAGE}/chip_tool_config.ini"
    fi

    while [[ "${waited}" -lt "${OPERATIONAL_DISCOVERY_WAIT_SECS}" ]]; do
        if chip_tool_operational_mdns_visible "${node_id}" "${OPERATIONAL_MDNS_BROWSE_SECS}"; then
            info "Operational mDNS visible for node ${node_id} (${waited}s) — establishing CASE session..."
            if device_reachable_on_thread "${node_id}"; then
                info "Device reachable on Thread after ${waited}s"
                return 0
            fi
        elif [[ $((waited % 30)) -eq 0 ]]; then
            # Occasional CASE probe when browse is empty (some hosts see DNS-SD late).
            if device_reachable_on_thread "${node_id}"; then
                info "Device reachable on Thread after ${waited}s (CASE ok before mDNS browse matched)"
                return 0
            fi
        fi
        sleep "${OPERATIONAL_DISCOVERY_POLL_SECS}"
        waited=$((waited + OPERATIONAL_DISCOVERY_POLL_SECS))
        if [[ $((waited % 15)) -eq 0 ]]; then
            info "Still waiting for operational discovery (${waited}/${OPERATIONAL_DISCOVERY_WAIT_SECS}s)..."
            if [[ -n "${mdns_instance}" ]]; then
                if chip_tool_operational_mdns_visible "${node_id}" "${OPERATIONAL_MDNS_BROWSE_SECS}"; then
                    info "mDNS shows ${mdns_instance} but CASE not up yet — trigger the sensor to keep MYGGSPRAY awake"
                else
                    info "No _matter._tcp match for ${mdns_instance} on this host yet — keep triggering the sensor (sleepy ICD); browse listens ${OPERATIONAL_MDNS_BROWSE_SECS}s per poll"
                fi
            fi
        fi
    done

    warn "Device not reachable via operational discovery after ${OPERATIONAL_DISCOVERY_WAIT_SECS}s"
    return 1
}

tag_device_on_fabric() {
    local node_id="$1"
    local device_tag="$2"
    local output=""
    local status=0

    info "Tagging node ${node_id} with NodeLabel: ${device_tag}"
    set +e
    output="$(write_device_node_label "${node_id}" "${device_tag}" 2>&1)"
    status=$?
    set -e

    if [[ ${status} -eq 0 ]]; then
        info "NodeLabel write succeeded"
        return 0
    fi

    echo "${output}" >&2
    warn "Could not write NodeLabel on node ${node_id} (device may not support it)"
    return 1
}

commission_with_ha() {
    local window_code="$1"
    [[ -n "${window_code}" ]] || die "No commissioning window code available for Home Assistant handoff"

    info "Commissioning device into Home Assistant Matter fabric..."
    python3 "${SCRIPT_DIR}/ha_websocket.py" \
        --ha-url "${HA_URL}" \
        --ha-token "${HA_TOKEN}" \
        query \
        --type matter/commission \
        --data "$(python3 -c 'import json,sys; print(json.dumps({"code": sys.argv[1]}))' "${window_code}")"
    info "Home Assistant Matter commission request completed"
}

# Canonicalize Thread dataset hex (strip whitespace/0x prefix and HA-only leading TLV).
canonical_thread_dataset() {
    local raw="$1"
    python3 - "$raw" <<'PY'
import re
import sys

tlv = re.sub(r"\s+", "", sys.argv[1])
tlv = re.sub(r"^0x", "", tlv, flags=re.IGNORECASE)

if not re.fullmatch(r"[0-9a-fA-F]+", tlv) or len(tlv) % 2:
    print("invalid hex thread dataset", file=sys.stderr)
    sys.exit(1)

# HA otbr/info active_dataset_tlvs may prefix a non-MeshCoP TLV (type 0x4a) that
# strict Thread endpoints reject with networkingStatus=1 (OutOfRange).
if tlv.lower().startswith("4a03"):
    tlv_len = int(tlv[2:4], 16)
    tlv = tlv[4 + tlv_len * 2 :]

if not tlv.lower().startswith("0e"):
    print(
        "thread dataset does not start with Active Timestamp TLV (0x0e); "
        "copy fresh hex from HA Settings → Thread or ot-ctl dataset active -x",
        file=sys.stderr,
    )
    sys.exit(1)

print(tlv.lower())
PY
}

format_thread_dataset_for_chip_tool() {
    echo "hex:$(canonical_thread_dataset "$1")"
}

log_matter_setup_payload_summary() {
    local payload="$1"
    local parsed vendor product long_disc discovery

    parsed="$(chip-tool payload parse-setup-payload "${payload}" 2>&1 || true)"
    vendor="$(sed -n 's/.*VendorID:[[:space:]]*\([0-9]*\).*/\1/p' <<<"${parsed}" | head -1)"
    product="$(sed -n 's/.*ProductID:[[:space:]]*\([0-9]*\).*/\1/p' <<<"${parsed}" | head -1)"
    long_disc="$(sed -n 's/.*Long discriminator:[[:space:]]*\([0-9]*\).*/\1/p' <<<"${parsed}" | head -1)"
    discovery="$(sed -n 's/.*Discovery Bitmask:[[:space:]]*\(0x[0-9a-fA-F]*\).*/\1/p' <<<"${parsed}" | head -1)"

    if [[ -n "${vendor}" ]]; then
        info "Setup payload: VID=${vendor} PID=${product} discriminator=${long_disc:-?} discovery=${discovery:-?}"
    fi
    if [[ "${discovery}" == "0x02" ]]; then
        info "Device advertises BLE-only commissioning — keep it in pairing mode and stay within ~1m of pangolin"
    fi
}

# Discriminator for ECM commissioning window (parse from payload, else common default).
parse_commissioning_window_discriminator() {
    local payload="$1"
    local parsed long_disc short_disc

    parsed="$(chip-tool payload parse-setup-payload "$payload" 2>&1 || true)"
    long_disc="$(sed -n 's/.*Long discriminator:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$parsed" | head -1)"
    short_disc="$(sed -n 's/.*Short discriminator:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$parsed" | head -1)"

    if [[ -n "$long_disc" ]]; then
        echo "$long_disc"
    elif [[ -n "$short_disc" ]]; then
        echo "$short_disc"
    else
        echo "3840"
    fi
}

fetch_thread_dataset_from_ha() {
    [[ -n "${HA_URL:-}" && -n "${HA_TOKEN:-}" ]] || return 1

    python3 "${SCRIPT_DIR}/ha_websocket.py" \
        --ha-url "$HA_URL" \
        --ha-token "$HA_TOKEN" \
        query --type otbr/info --data '{}' 2>/dev/null \
        | python3 -c "
import json
import sys

data = json.load(sys.stdin)
for border_router in data.values():
    dataset = border_router.get('active_dataset_tlvs', '')
    if dataset:
        print(dataset)
        break
"
}

# Resolve Thread dataset: prefer HA, sanity-check local copy when both exist.
resolve_thread_dataset() {
    local from_ha="" stored_tlv="" canonical_ha="" canonical_local=""

    from_ha="$(fetch_thread_dataset_from_ha 2>/dev/null || true)"
    stored_tlv="${THREAD_TLV:-}"
    if [[ "$stored_tlv" == "CONFIGURE_ME" ]]; then
        stored_tlv=""
    fi

    if [[ -n "$from_ha" && -n "$stored_tlv" ]]; then
        canonical_ha="$(canonical_thread_dataset "$from_ha")" \
            || die "Home Assistant returned an invalid Thread dataset"
        canonical_local="$(canonical_thread_dataset "$stored_tlv")" \
            || die "Local pass store Thread dataset is invalid (iotstack/common/thread_tlv)"

        if [[ "$canonical_ha" == "$canonical_local" ]]; then
            info "Local Thread dataset matches Home Assistant OTBR"
        else
            warn "Local Thread dataset differs from Home Assistant OTBR; using HA dataset"
            if { echo "$from_ha"; echo "$from_ha"; } | pass insert -f "iotstack/common/thread_tlv" >/dev/null 2>&1; then
                info "Updated iotstack/common/thread_tlv in pass to match HA"
            else
                warn "Could not update pass store; continuing with HA dataset"
            fi
        fi
        format_thread_dataset_for_chip_tool "$from_ha"
        return
    fi

    if [[ -n "$from_ha" ]]; then
        info "Using Thread dataset from Home Assistant OTBR (no local copy in pass)"
        format_thread_dataset_for_chip_tool "$from_ha"
        return
    fi

    if [[ -n "$stored_tlv" ]]; then
        warn "Could not fetch Thread dataset from Home Assistant; using local pass store value"
        format_thread_dataset_for_chip_tool "$stored_tlv"
        return
    fi

    die "No Thread dataset available. Ensure HA OTBR is running, or store one with: pass insert iotstack/common/thread_tlv"
}

# ---------------------------------------------------------------------------
# 2. Load and validate integration secrets (prompt if missing)
# ---------------------------------------------------------------------------
info "Checking Matter commissioning prerequisites..."

setup_chip_tool_snap_enabled || true
ensure_chip_tool_snap_interfaces
ensure_ha_integration

THREAD_TLV="$(get_pass_secret "iotstack/common/thread_tlv")"
export THREAD_TLV

# ---------------------------------------------------------------------------
# 3. Parse args — pairing input
# ---------------------------------------------------------------------------
MATTER_VERBOSE=0
MATTER_FORCE=0
if [[ "${IOTSTACK_MATTER_VERBOSE:-0}" -eq 1 || "${VERBOSE:-0}" -eq 1 ]]; then
    MATTER_VERBOSE=1
fi
if [[ "${IOTSTACK_MATTER_FORCE:-0}" -eq 1 ]]; then
    MATTER_FORCE=1
fi

INPUT=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        -f | --force)
            MATTER_FORCE=1
            shift
            ;;
        -v | --verbose)
            MATTER_VERBOSE=1
            shift
            ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

[[ ${#POSITIONAL[@]} -ge 1 ]] || die "Usage: $0 <qr-image>|<manual-pairing-code>|<MT:payload>"

INPUT="${POSITIONAL[0]}"

# ---------------------------------------------------------------------------
# 4. Get Matter onboarding payload — image file, manual code, or MT: string
# ---------------------------------------------------------------------------
MT_PAYLOAD=""
INPUT_KIND=""

if ! matter_resolve_onboarding_input "${INPUT}"; then
    exit 1
fi
MT_PAYLOAD="${MATTER_RESOLVED_PAYLOAD}"
INPUT_KIND="${MATTER_RESOLVED_INPUT_KIND}"

if [[ "${INPUT_KIND}" == "QR image" ]]; then
    info "Decoding QR code from: ${INPUT}"
fi

PAIRING_KEY="${MT_PAYLOAD}"
DEVICE_TAG="$(device_tag_for_pairing_key "${PAIRING_KEY}")"

ALREADY_ON_FABRIC="false"
if [[ "${MATTER_FORCE}" -eq 1 ]]; then
    reset_chip_tool_fabric_storage
    NODE_ID=1
    NODE_STATE="new"
    info "Force: cleared chip-tool fabric; commissioning fresh as node ${NODE_ID}"
else
    RESOLVE_RESULT="$(resolve_fabric_node_id "${DEVICE_TAG}")"
    NODE_ID="${RESOLVE_RESULT%% *}"
    NODE_STATE="${RESOLVE_RESULT##* }"
    if [[ "${NODE_STATE}" == "already" || "${NODE_STATE}" == "reuse" ]]; then
        ALREADY_ON_FABRIC="true"
    fi
fi

info "Using ${INPUT_KIND}: ${MT_PAYLOAD}"
log_matter_setup_payload_summary "${MT_PAYLOAD}"
echo "[info] Node ID: ${NODE_ID}"
info "Device tag (NodeLabel): ${DEVICE_TAG}"
info "chip-tool storage: ${IOTSTACK_CHIP_TOOL_DIR}"
echo "[info] chip-tool will decode the payload during commissioning"
echo ""
echo "[info] Ensure the device is powered on and in commissioning mode."
echo "[info] For sleepy motion/contact sensors: trigger the sensor now and keep it awake during commissioning."
echo ""

THREAD_DATASET="$(resolve_thread_dataset)" || die "Invalid Thread operational dataset"

if [[ "${ALREADY_ON_FABRIC}" != "true" ]]; then
    apply_chip_tool_attestation_trust "${MT_PAYLOAD}" \
        || die "Attestation trust store not configured. Run: iotstack matter configure-trust-store"
fi

# ---------------------------------------------------------------------------
# 5. Commission via chip-tool (Thread) when not already on fabric
# ---------------------------------------------------------------------------
if [[ "${ALREADY_ON_FABRIC}" == "true" ]]; then
    info "Skipping chip-tool commissioning; device is already on the local fabric"
else
    remove_node_from_local_fabric "${NODE_ID}"

    echo "[info] Commissioning node ${NODE_ID} via chip-tool (Thread)..."
    COMMISSION_OUTPUT=""
    COMMISSION_STATUS=0
    set +e
    # Send CommissioningComplete over BLE (do not use --skip-commissioning-complete:
    # skipping it leaves sleepy ICD devices off operational mDNS for a long time).
    # Allow a long chip-tool --timeout; we still wait ourselves if operational CASE
    # is slow after BLE teardown.
    run_chip_tool_capture COMMISSION_OUTPUT pairing code-thread \
        "${NODE_ID}" \
        "${THREAD_DATASET}" \
        "${MT_PAYLOAD}" \
        --icd-stay-active-duration "${ICD_STAY_ACTIVE_MS}" \
        --timeout "${CHIP_TOOL_COMMISSION_TIMEOUT_SECS}"
    COMMISSION_STATUS=$?
    set -e
    if [[ ${COMMISSION_STATUS} -ne 0 ]]; then
        if commission_output_thread_joined "${COMMISSION_OUTPUT}"; then
            if node_on_local_fabric "${NODE_ID}" || chip_tool_fabric_ini_present; then
                warn "Device joined Thread; chip-tool exited non-zero during operational CASE but fabric persisted for node ${NODE_ID} — continuing"
            else
                die "Device joined Thread but chip-tool could not persist the fabric. Factory-reset the device, trigger motion to keep it awake, ensure pangolin receives Matter mDNS from your OTBR (try: iotstack matter mdns 1), then retry."
            fi
        elif commission_output_ble_pase_failed "${COMMISSION_OUTPUT}"; then
            die "BLE pairing failed before Thread join (PASE/ack timeout after GATT connect). Factory-reset the plug, enter pairing mode, run within 30s: iotstack matter commission -f -v <MT:payload>. Ensure snap interfaces: sudo snap connect chip-tool:process-control (and bluez/avahi-observe if warned above). Keep pangolin within 1m; confirm the MT: payload is from this plug's QR."
        else
            die "chip-tool commissioning failed (see -v output above)"
        fi
    fi

    node_persisted_after_commission "${NODE_ID}" "${COMMISSION_OUTPUT}" \
        || die "chip-tool reported success but did not persist node ${NODE_ID} on the local fabric (check chip-tool storage: ${IOTSTACK_CHIP_TOOL_DIR})"

    ensure_chip_tool_compressed_fabric_id "${COMMISSION_OUTPUT}" || true
    info "chip-tool fabric saved under ${CHIP_TOOL_STORAGE} (shutdown 'Forgetting fabric' in chip-tool logs is normal)"
    info "Giving Thread/mDNS ${OPERATIONAL_POST_COMMISSION_GRACE_SECS}s after BLE teardown — trigger the sensor now to keep it awake"
    sleep "${OPERATIONAL_POST_COMMISSION_GRACE_SECS}"

    wait_for_operational_node "${NODE_ID}" \
        || die "Device is on the chip-tool fabric but not reachable yet. Keep triggering the sensor, run: iotstack matter mdns ${NODE_ID}. If mDNS appears later, resume without -f: iotstack matter commission <pairing-code>"

    tag_device_on_fabric "${NODE_ID}" "${DEVICE_TAG}" || true
    echo "[info] Commission complete."
fi

if [[ "${ALREADY_ON_FABRIC}" == "true" ]]; then
    wait_for_operational_node "${NODE_ID}" \
        || die "Device is on the chip-tool fabric but not reachable on Thread for HA handoff. If you factory-reset the device, retry with: iotstack matter commission -f <pairing-code>"
fi

# ---------------------------------------------------------------------------
# 6. Open commissioning window (Enhanced Commissioning Method, 15 min timeout)
# ---------------------------------------------------------------------------
echo "[info] Opening commissioning window for HA handoff..."

WINDOW_DISCRIMINATOR="$(parse_commissioning_window_discriminator "$MT_PAYLOAD")"
info "Using commissioning window discriminator: ${WINDOW_DISCRIMINATOR}"

# endpoint 1, timeout 900s, iterations 1000, ECM discriminator
WINDOW_OUTPUT=""
run_chip_tool_capture WINDOW_OUTPUT pairing open-commissioning-window \
    "${NODE_ID}" \
    1 \
    900 \
    1000 \
    "${WINDOW_DISCRIMINATOR}"

# Extract the pairing code printed by chip-tool for the new window
WINDOW_CODE="$(echo "${WINDOW_OUTPUT}" \
    | sed -n 's/.*Manual pairing code: \[\([^]]*\)\].*/\1/p' \
    | head -1)"
if [[ -z "${WINDOW_CODE}" ]]; then
    WINDOW_CODE="$(echo "${WINDOW_OUTPUT}" \
        | sed -n 's/.*SetupQRCode: \[\([^]]*\)\].*/\1/p' \
        | head -1)"
fi

if [[ -z "${WINDOW_CODE}" ]]; then
    warn "Could not extract window pairing code from chip-tool output."
    warn "You may need to enter the device manually in HA."
else
    info "HA handoff pairing code: ${WINDOW_CODE}"
fi

# ---------------------------------------------------------------------------
# 7. Notify HA via WebSocket to adopt the device
# ---------------------------------------------------------------------------
echo "[info] Triggering HA Matter commission via WebSocket..."
if [[ -n "${WINDOW_CODE}" ]]; then
    commission_with_ha "${WINDOW_CODE}"
else
    warn "Skipped Home Assistant Matter commission because no window code was available"
fi

echo "[done] Node ${NODE_ID} commissioned and handed off to HA."