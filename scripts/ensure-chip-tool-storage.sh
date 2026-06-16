#!/usr/bin/env bash
# ensure-chip-tool-storage.sh
# Matter/chip-tool layout under ~/.iotstack/chip-tool/
#
#   ~/.iotstack/chip-tool/common/        fabric storage (--storage-directory)
#   ~/.iotstack/chip-tool/common/trust/  attestation PAA/CD certs (*.der)
#   ~/.iotstack/chip-tool/paa-mirror/    connectedhomeip PAA index (scripts only)
#
# When chip-tool is the snap, one symlink covers the tree:
#   ~/.iotstack/chip-tool -> ~/snap/chip-tool

set -euo pipefail

IOTSTACK_CHIP_TOOL_BASE="${IOTSTACK_CHIP_TOOL_BASE:-${HOME}/.iotstack/chip-tool}"
IOTSTACK_CHIP_TOOL_COMMON="${IOTSTACK_CHIP_TOOL_COMMON:-${IOTSTACK_CHIP_TOOL_BASE}/common}"
IOTSTACK_CHIP_TOOL_TRUST="${IOTSTACK_CHIP_TOOL_TRUST:-${IOTSTACK_CHIP_TOOL_COMMON}/trust}"
CHIP_TOOL_PAA_MIRROR_DIR="${CHIP_TOOL_PAA_MIRROR_DIR:-${IOTSTACK_CHIP_TOOL_BASE}/paa-mirror}"

SNAP_CHIP_TOOL_BASE="${SNAP_CHIP_TOOL_BASE:-${HOME}/snap/chip-tool}"
SNAP_CHIP_TOOL_COMMON="${SNAP_CHIP_TOOL_COMMON:-${SNAP_CHIP_TOOL_BASE}/common}"
SNAP_CHIP_TOOL_TRUST="${SNAP_CHIP_TOOL_TRUST:-${SNAP_CHIP_TOOL_COMMON}/trust}"
SNAP_CHIP_TOOL_PAA_MIRROR="${SNAP_CHIP_TOOL_PAA_MIRROR:-${SNAP_CHIP_TOOL_BASE}/paa-mirror}"

LEGACY_IOTSTACK_CHIP_TOOL_TRUST="${LEGACY_IOTSTACK_CHIP_TOOL_TRUST:-${HOME}/.iotstack/chip-tool-trust}"
LEGACY_CHIP_TOOL_PAA_MIRROR="${LEGACY_CHIP_TOOL_PAA_MIRROR:-${HOME}/.iotstack/connectedhomeip-paa-mirror}"
LEGACY_SNAP_CHIP_TOOL_TRUST="${LEGACY_SNAP_CHIP_TOOL_TRUST:-${SNAP_CHIP_TOOL_COMMON}/chip-tool-trust}"
LEGACY_TOPLEVEL_TRUST="${LEGACY_TOPLEVEL_TRUST:-${HOME}/.iotstack/chip-tool/trust}"

chip_tool_is_snap() {
    local chip_tool_path
    chip_tool_path="$(command -v chip-tool 2>/dev/null || true)"
    [[ "${chip_tool_path}" == /snap/* ]]
}

# Snap plugs recommended for chip-tool (BLE commissioning, mDNS, reliability).
CHIP_TOOL_SNAP_PLUGS=(
    chip-tool:bluez
    chip-tool:avahi-observe
    chip-tool:process-control
)

# True when chip-tool snap plug has a connected slot (slot column is not "-").
chip_tool_snap_interface_connected() {
    local plug="${1:-}"
    [[ -n "${plug}" ]] || return 1
    command -v snap &>/dev/null || return 1
    chip_tool_is_snap || return 0
    snap connections chip-tool 2>/dev/null \
        | awk -v plug="${plug}" '$2 == plug && $3 != "-" { found = 1 } END { exit(found ? 0 : 1) }'
}

_chip_tool_snap_log() {
    printf '%s\n' "$*" >&2
}

chip_tool_snap_is_installed() {
    command -v snap &>/dev/null || return 1
    snap list chip-tool 2>/dev/null | awk 'NR == 2 { found = 1 } END { exit(found ? 0 : 1) }'
}

chip_tool_snap_is_disabled() {
    command -v snap &>/dev/null || return 1
    snap list chip-tool 2>/dev/null | awk 'NR == 2 && $NF == "disabled" { found = 1 } END { exit(found ? 0 : 1) }'
}

# Re-enable chip-tool after a failed `snap remove` (leaves snap installed but disabled).
setup_chip_tool_snap_enabled() {
    chip_tool_snap_is_installed || return 0
    chip_tool_snap_is_disabled || return 0

    _chip_tool_snap_log "[info] chip-tool snap is installed but disabled (common after a failed snap remove)"
    if sudo snap enable chip-tool 2>/dev/null; then
        _chip_tool_snap_log "[OK] Enabled chip-tool snap"
        return 0
    fi

    _chip_tool_snap_log "[WARN] Could not enable chip-tool snap"
    _chip_tool_snap_log "[WARN] Try: sudo snap remove chip-tool && sudo snap install chip-tool"
    return 1
}

# Install, enable, and connect chip-tool snap interfaces (setup.sh).
setup_chip_tool_snap() {
    command -v snap &>/dev/null || return 0

    if ! chip_tool_snap_is_installed; then
        if sudo snap install chip-tool 2>/dev/null; then
            _chip_tool_snap_log "[OK] Installed chip-tool snap"
        else
            _chip_tool_snap_log "[WARN] Failed to install chip-tool snap"
            return 1
        fi
    fi

    setup_chip_tool_snap_enabled || true
    setup_chip_tool_snap_interfaces || true
}

# Connect chip-tool snap interfaces (setup.sh). Requires sudo for snap connect.
setup_chip_tool_snap_interfaces() {
    local plug="" missing=0

    chip_tool_is_snap || return 0
    command -v snap &>/dev/null || return 0

    for plug in "${CHIP_TOOL_SNAP_PLUGS[@]}"; do
        if chip_tool_snap_interface_connected "${plug}"; then
            continue
        fi
        missing=1
        if sudo snap connect "${plug}" 2>/dev/null; then
            _chip_tool_snap_log "[OK] Connected ${plug}"
        else
            _chip_tool_snap_log "[WARN] Could not connect ${plug} (run: sudo snap connect ${plug})"
        fi
    done

    if [[ "${missing}" -eq 0 ]]; then
        _chip_tool_snap_log "[OK] chip-tool snap interfaces already connected"
    fi
}

# Remove chip-tool snap and all persisted Matter data (reset.sh).
purge_chip_tool_snap_and_data() {
    local path="" name=""

    if command -v snap &>/dev/null && chip_tool_snap_is_installed; then
        _chip_tool_snap_log "[info] Removing chip-tool snap (sudo snap remove --purge)..."
        if ! sudo snap remove --purge chip-tool 2>/dev/null; then
            _chip_tool_snap_log "[warn] snap remove --purge failed; trying snap remove..."
            sudo snap remove chip-tool 2>/dev/null || true
        fi
    fi

    if [[ -L "${IOTSTACK_CHIP_TOOL_BASE}" || -e "${IOTSTACK_CHIP_TOOL_BASE}" ]]; then
        _chip_tool_snap_log "[info] Removing ${IOTSTACK_CHIP_TOOL_BASE}"
        rm -rf "${IOTSTACK_CHIP_TOOL_BASE}"
    fi

    if [[ -d "${SNAP_CHIP_TOOL_BASE}" ]]; then
        _chip_tool_snap_log "[info] Removing ${SNAP_CHIP_TOOL_BASE}"
        rm -rf "${SNAP_CHIP_TOOL_BASE}"
    fi

    if [[ -d /var/snap/chip-tool ]]; then
        _chip_tool_snap_log "[info] Removing /var/snap/chip-tool"
        sudo rm -rf /var/snap/chip-tool
    fi

    if [[ -d /root/snap/chip-tool ]]; then
        _chip_tool_snap_log "[info] Removing /root/snap/chip-tool"
        sudo rm -rf /root/snap/chip-tool
    fi

    shopt -s nullglob
    for name in /tmp/chip_kvs /tmp/chip_factory.ini /tmp/chip_config.ini /tmp/chip_counters.ini; do
        [[ -e "${name}" ]] && rm -f "${name}"
    done
    shopt -u nullglob

    for path in \
        "${LEGACY_IOTSTACK_CHIP_TOOL_TRUST}" \
        "${LEGACY_CHIP_TOOL_PAA_MIRROR}"; do
        if [[ -e "${path}" || -L "${path}" ]]; then
            _chip_tool_snap_log "[info] Removing legacy path ${path}"
            rm -rf "${path}"
        fi
    done
}

# Warn when snap interfaces needed for BLE/mDNS commissioning are disconnected.
ensure_chip_tool_snap_interfaces() {
    local plug="" missing=0

    chip_tool_is_snap || return 0
    command -v snap &>/dev/null || return 0

    for plug in "${CHIP_TOOL_SNAP_PLUGS[@]}"; do
        if chip_tool_snap_interface_connected "${plug}"; then
            continue
        fi
        missing=1
        _chip_tool_snap_log "[warn] chip-tool snap interface not connected: ${plug}"
        _chip_tool_snap_log "[warn]   sudo snap connect ${plug}"
    done

    if [[ "${missing}" -eq 1 ]]; then
        _chip_tool_snap_log "[warn] Disconnected chip-tool snap interfaces can cause BLE ack/PASE timeouts and missing Matter mDNS."
        _chip_tool_snap_log "[warn] Re-run setup.sh or: sudo snap connect chip-tool:process-control"
    fi
}

_chip_tool_symlink_points_at() {
    local link_path="$1"
    local expected_target="$2"
    [[ -L "${link_path}" ]] \
        && [[ "$(readlink -f "${link_path}")" == "$(readlink -f "${expected_target}")" ]]
}

_migrate_trust_cert_trees() {
    local legacy_base="$1"
    local dest_base="$2"
    local sub=""

    [[ -n "${legacy_base}" && -d "${legacy_base}" ]] || return 0

    for sub in paa-root-certs cd-certs; do
        [[ -d "${legacy_base}/${sub}" ]] || continue
        mkdir -p "${dest_base}/${sub}"
        cp -an "${legacy_base}/${sub}/." "${dest_base}/${sub}/" 2>/dev/null \
            || cp -a "${legacy_base}/${sub}/." "${dest_base}/${sub}/" 2>/dev/null \
            || true
    done

    if [[ -f "${legacy_base}/.bypass-attestation" ]]; then
        cp -a "${legacy_base}/.bypass-attestation" "${dest_base}/.bypass-attestation" 2>/dev/null || true
    fi

    return 0
}

_migrate_paa_mirror_tree() {
    local legacy_mirror="$1"
    local dest_mirror="$2"

    [[ -n "${legacy_mirror}" && -d "${legacy_mirror}" ]] || return 0
    [[ "${legacy_mirror}" == "${dest_mirror}" ]] && return 0

    if [[ -d "${dest_mirror}" && -n "$(ls -A "${dest_mirror}" 2>/dev/null)" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "${dest_mirror}")"
    if [[ -d "${dest_mirror}" ]]; then
        rm -rf "${dest_mirror}"
    fi
    mv "${legacy_mirror}" "${dest_mirror}" 2>/dev/null \
        || cp -a "${legacy_mirror}/." "${dest_mirror}/" 2>/dev/null \
        || true

    return 0
}

_abs_path_if_exists() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 1
    readlink -f "$path"
}

_CHIP_TOOL_JUNK_NAMES=(
    common-symlink-test
    common.bak-test
    snap-write-test
    paa-test
    iotstack-link
)

# Remove migration-test debris and the accidental common/common/... duplicate tree.
_prune_chip_tool_storage_junk() {
    local base="" storage_dir="" name=""

    if chip_tool_is_snap; then
        storage_dir="${SNAP_CHIP_TOOL_COMMON}"
    else
        storage_dir="${IOTSTACK_CHIP_TOOL_COMMON}"
    fi

    for base in "${SNAP_CHIP_TOOL_BASE}" "${IOTSTACK_CHIP_TOOL_BASE}" "${storage_dir}"; do
        [[ -n "${base}" && -d "${base}" ]] || continue
        for name in "${_CHIP_TOOL_JUNK_NAMES[@]}"; do
            if [[ -e "${base}/${name}" || -L "${base}/${name}" ]]; then
                rm -rf "${base:?}/${name:?}"
            fi
        done
    done

    if [[ -n "${storage_dir}" && -d "${storage_dir}/common" ]]; then
        rm -rf "${storage_dir}/common"
    fi

    if [[ -n "${storage_dir}" && -d "${storage_dir}/paa-mirror" \
        && -d "${IOTSTACK_CHIP_TOOL_BASE}/paa-mirror" \
        && "${storage_dir}/paa-mirror" != "${CHIP_TOOL_PAA_MIRROR_DIR}" \
        && -z "$(ls -A "${storage_dir}/paa-mirror" 2>/dev/null)" ]]; then
        rm -rf "${storage_dir}/paa-mirror"
    fi

    return 0
}

chip_tool_compressed_fabric_id_file() {
    printf '%s/.compressed-fabric-id' "$(resolve_chip_tool_storage_dir)"
}

chip_tool_read_compressed_fabric_id() {
    local file="" fabric_id=""
    file="$(chip_tool_compressed_fabric_id_file)"
    [[ -f "${file}" ]] || return 1
    fabric_id="$(tr -d '[:space:]' <"${file}")"
    [[ "${fabric_id}" =~ ^[0-9A-Fa-f]{16}$ ]] || return 1
    printf '%s' "${fabric_id^^}"
}

chip_tool_save_compressed_fabric_id() {
    local fabric_id="${1:-}"
    [[ "${fabric_id}" =~ ^[0-9A-Fa-f]{16}$ ]] || return 1
    mkdir -p "$(resolve_chip_tool_storage_dir)"
    printf '%s\n' "${fabric_id^^}" >"$(chip_tool_compressed_fabric_id_file)"
}

# Parse chip-tool stdout for the operational compressed fabric ID (16 hex chars).
chip_tool_parse_compressed_fabric_id_from_output() {
    local output="${1:-}"
    [[ -n "${output}" ]] || return 1
    local fabric_id
    fabric_id="$(
        sed -n \
            -e 's/.*Compressed FabricId 0x\([0-9A-Fa-f]\{16\}\).*/\1/p' \
            -e 's/.*Compressed Fabric ID: \([0-9A-Fa-f]\{16\}\).*/\1/p' \
            -e 's/.*Lookup started for \([0-9A-Fa-f]\{16\}\)-.*/\1/p' \
            <<<"${output}" | head -1
    )"
    [[ "${fabric_id}" =~ ^[0-9A-Fa-f]{16}$ ]] || return 1
    printf '%s' "${fabric_id^^}"
}

# Load fabric from chip_tool_config.ini only (no Thread/mDNS). Any chip-tool command
# that initializes the FabricTable logs Compressed FabricId before networking.
chip_tool_probe_compressed_fabric_id_from_storage() {
    local output="" fabric_id=""

    if ! command -v chip-tool &>/dev/null; then
        return 1
    fi

    set +e
    output="$(
        timeout 5 chip-tool basicinformation read vendor-name 0 0 \
            --storage-directory "$(resolve_chip_tool_storage_dir)" 2>&1
    )"
    set -e

    fabric_id="$(chip_tool_parse_compressed_fabric_id_from_output "${output}" || true)"
    [[ -n "${fabric_id}" ]] || return 1
    chip_tool_save_compressed_fabric_id "${fabric_id}" || true
    printf '%s' "${fabric_id}"
}

chip_tool_operational_mdns_visible() {
    local node_id="${1:-1}"
    local browse_secs="${2:-12}"
    local instance=""

    instance="$(chip_tool_operational_mdns_instance "${node_id}" 2>/dev/null || true)"
    [[ -n "${instance}" ]] || return 1
    command -v avahi-browse &>/dev/null || return 1
    # Listen briefly without -t; sleepy ICD devices register intermittently.
    timeout "${browse_secs}" avahi-browse -r _matter._tcp 2>/dev/null | grep -Fq -- "${instance}"
}

chip_tool_operational_mdns_instance() {
    local node_id="${1:-1}"
    local fabric_id="" node_hex=""

    fabric_id="$(chip_tool_read_compressed_fabric_id)" || return 1
    [[ "${node_id}" =~ ^[0-9]+$ ]] || return 1
    node_hex="$(printf '%016X' "${node_id}")"
    printf '%s-%s' "${fabric_id}" "${node_hex}"
}

_migrate_legacy_chip_tool_layout() {
    local chip_tool_entry="${HOME}/.iotstack/chip-tool"
    local snap_common_from_old_link=""
    local legacy_trust_path=""

    mkdir -p "${HOME}/.iotstack"

    if chip_tool_is_snap; then
        mkdir -p "${SNAP_CHIP_TOOL_COMMON}" \
            "${SNAP_CHIP_TOOL_TRUST}/paa-root-certs" \
            "${SNAP_CHIP_TOOL_TRUST}/cd-certs" \
            "${SNAP_CHIP_TOOL_PAA_MIRROR}"

        # Oldest layout: ~/.iotstack/chip-tool -> snap/common
        if [[ -L "${chip_tool_entry}" ]]; then
            snap_common_from_old_link="$(_abs_path_if_exists "${chip_tool_entry}" || true)"
            rm -f "${chip_tool_entry}"
        fi

        if [[ -n "${snap_common_from_old_link}" \
            && "${snap_common_from_old_link}" != "$(readlink -f "${SNAP_CHIP_TOOL_COMMON}")" ]]; then
            cp -an "${snap_common_from_old_link}/." "${SNAP_CHIP_TOOL_COMMON}/" 2>/dev/null \
                || cp -a "${snap_common_from_old_link}/." "${SNAP_CHIP_TOOL_COMMON}/" 2>/dev/null \
                || true
        fi

        # Previous layout: real ~/.iotstack/chip-tool/{common,trust,paa-mirror}
        if [[ -d "${chip_tool_entry}" && ! -L "${chip_tool_entry}" ]]; then
            if [[ -L "${chip_tool_entry}/common" ]]; then
                snap_common_from_old_link="$(_abs_path_if_exists "${chip_tool_entry}/common" || true)"
            elif [[ -d "${chip_tool_entry}/common" ]]; then
                cp -an "${chip_tool_entry}/common/." "${SNAP_CHIP_TOOL_COMMON}/" 2>/dev/null \
                    || cp -a "${chip_tool_entry}/common/." "${SNAP_CHIP_TOOL_COMMON}/" 2>/dev/null \
                    || true
            else
                shopt -s dotglob nullglob
                local entry
                for entry in "${chip_tool_entry}"/*; do
                    case "$(basename "$entry")" in
                        common|trust|paa-mirror) continue ;;
                    esac
                    [[ -e "$entry" ]] || continue
                    cp -an "$entry" "${SNAP_CHIP_TOOL_COMMON}/" 2>/dev/null \
                        || cp -a "$entry" "${SNAP_CHIP_TOOL_COMMON}/" 2>/dev/null \
                        || true
                done
                shopt -u dotglob nullglob
            fi

            if [[ -L "${chip_tool_entry}/trust" ]]; then
                legacy_trust_path="$(_abs_path_if_exists "${chip_tool_entry}/trust" || true)"
            elif [[ -d "${chip_tool_entry}/trust" ]]; then
                legacy_trust_path="${chip_tool_entry}/trust"
            fi

            _migrate_paa_mirror_tree "${chip_tool_entry}/paa-mirror" "${SNAP_CHIP_TOOL_PAA_MIRROR}"
            rm -rf "${chip_tool_entry}"
        fi

        _migrate_trust_cert_trees "${LEGACY_SNAP_CHIP_TOOL_TRUST}" "${SNAP_CHIP_TOOL_TRUST}"
        if [[ -L "${LEGACY_IOTSTACK_CHIP_TOOL_TRUST}" ]]; then
            _migrate_trust_cert_trees "$(_abs_path_if_exists "${LEGACY_IOTSTACK_CHIP_TOOL_TRUST}")" "${SNAP_CHIP_TOOL_TRUST}"
            rm -f "${LEGACY_IOTSTACK_CHIP_TOOL_TRUST}"
        else
            _migrate_trust_cert_trees "${LEGACY_IOTSTACK_CHIP_TOOL_TRUST}" "${SNAP_CHIP_TOOL_TRUST}"
        fi
        if [[ -n "${legacy_trust_path}" ]]; then
            _migrate_trust_cert_trees "${legacy_trust_path}" "${SNAP_CHIP_TOOL_TRUST}"
        fi
        if [[ -L "${LEGACY_TOPLEVEL_TRUST}" ]]; then
            _migrate_trust_cert_trees "$(_abs_path_if_exists "${LEGACY_TOPLEVEL_TRUST}")" "${SNAP_CHIP_TOOL_TRUST}"
        fi

        if [[ -d "${LEGACY_SNAP_CHIP_TOOL_TRUST}" ]]; then
            rm -rf "${LEGACY_SNAP_CHIP_TOOL_TRUST}"
        fi

        _migrate_paa_mirror_tree "${LEGACY_CHIP_TOOL_PAA_MIRROR}" "${SNAP_CHIP_TOOL_PAA_MIRROR}"
        if [[ -d "${SNAP_CHIP_TOOL_TRUST}/connectedhomeip-paa-mirror" ]]; then
            _migrate_paa_mirror_tree "${SNAP_CHIP_TOOL_TRUST}/connectedhomeip-paa-mirror" "${SNAP_CHIP_TOOL_PAA_MIRROR}"
            rm -rf "${SNAP_CHIP_TOOL_TRUST}/connectedhomeip-paa-mirror"
        fi
        if [[ -d "${LEGACY_CHIP_TOOL_PAA_MIRROR}" && "${LEGACY_CHIP_TOOL_PAA_MIRROR}" != "${SNAP_CHIP_TOOL_PAA_MIRROR}" ]]; then
            rm -rf "${LEGACY_CHIP_TOOL_PAA_MIRROR}"
        fi

        if ! _chip_tool_symlink_points_at "${IOTSTACK_CHIP_TOOL_BASE}" "${SNAP_CHIP_TOOL_BASE}"; then
            if [[ -e "${IOTSTACK_CHIP_TOOL_BASE}" && ! -L "${IOTSTACK_CHIP_TOOL_BASE}" ]]; then
                rm -rf "${IOTSTACK_CHIP_TOOL_BASE}"
            fi
            if [[ -L "${IOTSTACK_CHIP_TOOL_BASE}" ]]; then
                rm -f "${IOTSTACK_CHIP_TOOL_BASE}"
            fi
            ln -sfn "${SNAP_CHIP_TOOL_BASE}" "${IOTSTACK_CHIP_TOOL_BASE}"
        fi
    else
        mkdir -p "${IOTSTACK_CHIP_TOOL_COMMON}" \
            "${IOTSTACK_CHIP_TOOL_TRUST}/paa-root-certs" \
            "${IOTSTACK_CHIP_TOOL_TRUST}/cd-certs" \
            "${CHIP_TOOL_PAA_MIRROR_DIR}"

        if [[ -L "${IOTSTACK_CHIP_TOOL_BASE}" ]]; then
            rm -f "${IOTSTACK_CHIP_TOOL_BASE}"
        fi

        if [[ -L "${LEGACY_IOTSTACK_CHIP_TOOL_TRUST}" ]]; then
            _migrate_trust_cert_trees "$(_abs_path_if_exists "${LEGACY_IOTSTACK_CHIP_TOOL_TRUST}")" "${IOTSTACK_CHIP_TOOL_TRUST}"
            rm -f "${LEGACY_IOTSTACK_CHIP_TOOL_TRUST}"
        else
            _migrate_trust_cert_trees "${LEGACY_IOTSTACK_CHIP_TOOL_TRUST}" "${IOTSTACK_CHIP_TOOL_TRUST}"
        fi

        _migrate_paa_mirror_tree "${LEGACY_CHIP_TOOL_PAA_MIRROR}" "${CHIP_TOOL_PAA_MIRROR_DIR}"
        if [[ -d "${LEGACY_CHIP_TOOL_PAA_MIRROR}" && "${LEGACY_CHIP_TOOL_PAA_MIRROR}" != "${CHIP_TOOL_PAA_MIRROR_DIR}" ]]; then
            rm -rf "${LEGACY_CHIP_TOOL_PAA_MIRROR}"
        fi
    fi

    _prune_chip_tool_storage_junk
    return 0
}

setup_chip_tool_layout() {
    _migrate_legacy_chip_tool_layout
}

setup_chip_tool_storage() {
    setup_chip_tool_layout
}

resolve_chip_tool_storage_dir() {
    setup_chip_tool_layout
    if [[ -n "${CHIP_TOOL_STORAGE:-}" ]]; then
        printf '%s' "${CHIP_TOOL_STORAGE}"
        return 0
    fi
    if chip_tool_is_snap; then
        printf '%s' "${SNAP_CHIP_TOOL_COMMON}"
    else
        printf '%s' "${IOTSTACK_CHIP_TOOL_COMMON}"
    fi
}

canonical_chip_tool_storage_dir() {
    setup_chip_tool_layout
    printf '%s' "${IOTSTACK_CHIP_TOOL_COMMON}"
}

resolve_chip_tool_trust_base() {
    setup_chip_tool_layout
    if chip_tool_is_snap; then
        printf '%s' "${SNAP_CHIP_TOOL_TRUST}"
    else
        printf '%s' "$(readlink -f "${IOTSTACK_CHIP_TOOL_TRUST}")"
    fi
}

canonical_chip_tool_trust_base() {
    setup_chip_tool_layout
    printf '%s' "${IOTSTACK_CHIP_TOOL_TRUST}"
}

resolve_chip_tool_paa_trust_dir() {
    printf '%s/paa-root-certs' "$(resolve_chip_tool_trust_base)"
}

resolve_chip_tool_cd_trust_dir() {
    printf '%s/cd-certs' "$(resolve_chip_tool_trust_base)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    setup_chip_tool_layout
    echo "chip-tool base:   ${IOTSTACK_CHIP_TOOL_BASE}"
    echo "common (logical): ${IOTSTACK_CHIP_TOOL_COMMON}"
    echo "common (runtime): $(resolve_chip_tool_storage_dir)"
    echo "trust (logical):  ${IOTSTACK_CHIP_TOOL_TRUST}"
    echo "trust (runtime):  $(resolve_chip_tool_trust_base)"
    echo "paa-mirror:       ${CHIP_TOOL_PAA_MIRROR_DIR}"
    ls -la "${IOTSTACK_CHIP_TOOL_BASE}" 2>/dev/null || true
fi