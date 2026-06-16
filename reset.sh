#!/bin/bash
# reset.sh — Interactively reset iotstack and optional chip-tool Matter state.
#
# Each step is optional; you are prompted before anything is removed.
# Typical use: full reset of ~/.iotstack, then setup.sh to reinitialize.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/scripts/config.sh"
# shellcheck source=scripts/ensure-chip-tool-storage.sh
source "${SCRIPT_DIR}/scripts/ensure-chip-tool-storage.sh"

RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
RST='\033[0m'

info() { echo -e "${YLW}[INFO]${RST} $*"; }
ok()   { echo -e "${GRN}[OK]${RST} $*"; }
warn() { echo -e "${YLW}[WARN]${RST} $*"; }

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

interactive_prompt_available() {
    [[ -t 1 && -r /dev/tty ]]
}

ask_yes_no() {
    local prompt="$1"
    local reply=""

    if ! interactive_prompt_available; then
        warn "No interactive terminal; skipping: ${prompt}"
        return 1
    fi

    while true; do
        printf '%s [y/N] ' "${prompt}" >/dev/tty
        read -r reply </dev/tty 2>/dev/null || reply=""
        case "${reply}" in
            [Yy]|[Yy][Ee][Ss])
                return 0
                ;;
            [Nn]|[Nn][Oo]|"")
                return 1
                ;;
            *)
                echo "Please answer y or n." >/dev/tty
                ;;
        esac
    done
}

describe_chip_tool_state() {
    if command -v snap &>/dev/null && chip_tool_snap_is_installed; then
        snap list chip-tool 2>/dev/null | awk 'NR <= 2'
        if chip_tool_snap_is_disabled; then
            warn "chip-tool snap is disabled (often after a failed snap remove)"
        fi
    elif command -v chip-tool &>/dev/null; then
        info "chip-tool found on PATH (non-snap or enabled snap)"
    else
        info "chip-tool snap/binary not currently available"
    fi
    [[ -d "${SNAP_CHIP_TOOL_BASE}" ]] && info "User snap data: ${SNAP_CHIP_TOOL_BASE}"
    [[ -e "${IOTSTACK_CHIP_TOOL_BASE}" || -L "${IOTSTACK_CHIP_TOOL_BASE}" ]] \
        && info "iotstack chip-tool link/tree: ${IOTSTACK_CHIP_TOOL_BASE}"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

backup_dir=""
did_anything=0

echo "════════════════════════════════════════════════════════"
echo "iotstack Reset (interactive)"
echo "════════════════════════════════════════════════════════"
echo
echo "Each item below is optional. Nothing is removed unless you answer y."
echo

# 1. iotstack home (~/.iotstack)
echo "[1/5] iotstack home"
if [[ -d "${IOTSTACK_HOME}" ]]; then
    info "iotstack home: ${IOTSTACK_HOME}"
    if ask_yes_no "Back up ${IOTSTACK_HOME} to a timestamped .bak-* directory and remove the original?"; then
        backup_dir="${IOTSTACK_HOME}.bak-$(date +%Y%m%d-%H%M%S)"
        info "Backing up ${IOTSTACK_HOME} -> ${backup_dir}"
        mv "${IOTSTACK_HOME}" "${backup_dir}"
        ok "iotstack home backed up and cleared"
        did_anything=1
    else
        info "Skipping iotstack home backup/removal"
    fi
else
    info "No iotstack home at ${IOTSTACK_HOME}"
fi

echo

# 2. yamls/.iotstack symlink (ESPHome build artifacts -> ~/.iotstack)
echo "[2/5] ESPHome symlink"
yamls_link="${SCRIPT_DIR}/yamls/.iotstack"
if [[ -e "${yamls_link}" || -L "${yamls_link}" ]]; then
    if [[ -L "${yamls_link}" ]]; then
        link_target="$(readlink "${yamls_link}" 2>/dev/null || true)"
        info "ESPHome symlink: ${yamls_link} -> ${link_target:-?}"
    else
        info "yamls/.iotstack exists but is not a symlink: ${yamls_link}"
    fi
    if ask_yes_no "Remove the ESPHome symlink (yamls/.iotstack)?"; then
        rm -f "${yamls_link}"
        ok "Removed ESPHome symlink (yamls/.iotstack)"
        did_anything=1
    else
        info "Skipping ESPHome symlink removal"
    fi
else
    info "No ESPHome symlink at yamls/.iotstack"
fi

echo

# 3. chip-tool snap + Matter persistence
echo "[3/5] chip-tool / Matter state"
describe_chip_tool_state
echo
if ask_yes_no "Purge chip-tool snap and all persisted Matter data (fabric, trust, ~/snap/chip-tool)?"; then
    purge_chip_tool_snap_and_data
    ok "chip-tool snap and data purge finished"
    did_anything=1
else
    info "Skipping chip-tool purge"
fi

echo

# 4. chip-tool temp files in /tmp
echo "[4/5] chip-tool temp files"
tmp_chip_present=0
shopt -s nullglob
for _f in /tmp/chip_kvs /tmp/chip_factory.ini /tmp/chip_config.ini /tmp/chip_counters.ini; do
    [[ -e "${_f}" ]] && tmp_chip_present=1
done
shopt -u nullglob

if [[ "${tmp_chip_present}" -eq 1 ]]; then
    if ask_yes_no "Remove chip-tool temp files in /tmp (chip_kvs, chip_*.ini)?"; then
        shopt -s nullglob
        for _f in /tmp/chip_kvs /tmp/chip_factory.ini /tmp/chip_config.ini /tmp/chip_counters.ini; do
            [[ -e "${_f}" ]] && rm -f "${_f}"
        done
        shopt -u nullglob
        ok "Removed chip-tool temp files"
        did_anything=1
    else
        info "Skipping /tmp chip-tool temp files"
    fi
else
    info "No chip-tool temp files in /tmp"
fi

echo

# 5. Re-run setup
echo "[5/5] setup.sh"
if ask_yes_no "Run setup.sh to reinitialize iotstack (pass, chip-tool snap, CLI link)?"; then
    echo
    info "Running setup.sh..."
    echo
    "${SCRIPT_DIR}/setup.sh"
    did_anything=1
else
    info "Skipping setup.sh"
fi

echo
echo "════════════════════════════════════════════════════════"
if [[ "${did_anything}" -eq 1 ]]; then
    echo "Reset steps completed."
else
    echo "Nothing was changed."
fi
echo "════════════════════════════════════════════════════════"
echo
if [[ -n "${backup_dir}" ]]; then
    echo "Previous iotstack home preserved at: ${backup_dir}"
fi
echo "Next (if secrets were reset): iotstack matter configure-trust-store"
echo "                               iotstack rotate-secrets <role>"