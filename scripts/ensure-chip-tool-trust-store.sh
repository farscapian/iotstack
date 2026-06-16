#!/usr/bin/env bash
# ensure-chip-tool-trust-store.sh
# Interactive Matter attestation trust store for chip-tool commissioning.
#
# Trust anchors (PAA roots, CSA CD signing keys) — not per-device DAC certs.
# Source from matter-commission.sh / matter-configure-trust-store.sh
# or run: ./matter-configure-trust-store.sh

set -euo pipefail

_CHIP_TOOL_TRUST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${_CHIP_TOOL_TRUST_SCRIPT_DIR}/config.sh"
# shellcheck source=scripts/ensure-chip-tool-storage.sh
source "${_CHIP_TOOL_TRUST_SCRIPT_DIR}/ensure-chip-tool-storage.sh"

CHIP_TOOL_TRUST_BASE=""
CHIP_TOOL_PAA_TRUST_DIR=""
CHIP_TOOL_CD_TRUST_DIR=""

CSA_CD_BASE_URL="https://raw.githubusercontent.com/project-chip/connectedhomeip/master/credentials/development/cd-certs"
PAA_MIRROR_API="https://api.github.com/repos/project-chip/connectedhomeip/contents/credentials/development/paa-root-certs"

if [[ -z "${_IOTSTACK_CHIP_TOOL_TRUST_LOADED:-}" ]]; then
    _IOTSTACK_CHIP_TOOL_TRUST_LOADED=1

    _trust_info() { echo "[info] $*" >&2; }
    _trust_warn() { echo "[warn] $*" >&2; }

    # bash [[ -t /dev/tty ]] is invalid (-t wants a fd number). Use stdout + /dev/tty readability.
    interactive_prompt_available() {
        [[ -t 1 && -r /dev/tty ]]
    }

    resolve_chip_tool_trust_paths() {
        setup_chip_tool_layout
        CHIP_TOOL_TRUST_BASE="$(canonical_chip_tool_trust_base)"
        CHIP_TOOL_PAA_TRUST_DIR="$(resolve_chip_tool_paa_trust_dir)"
        CHIP_TOOL_CD_TRUST_DIR="$(resolve_chip_tool_cd_trust_dir)"
    }

    _ensure_der_from_cert() {
        local cert_path="$1"
        local der_path="${cert_path%.*}.der"

        [[ -f "$cert_path" ]] || return 1

        if [[ "$cert_path" == *.der ]]; then
            return 0
        fi

        command -v openssl &>/dev/null || return 1
        openssl x509 -in "$cert_path" -outform DER -out "$der_path" 2>/dev/null
    }

    _normalize_trust_store_ders() {
        local f
        for f in "${CHIP_TOOL_PAA_TRUST_DIR}"/*.pem "${CHIP_TOOL_CD_TRUST_DIR}"/*.pem; do
            [[ -f "$f" ]] || continue
            _ensure_der_from_cert "$f" || true
        done
    }

    ensure_chip_tool_trust_dirs() {
        resolve_chip_tool_trust_paths
        mkdir -p "${CHIP_TOOL_PAA_TRUST_DIR}" "${CHIP_TOOL_CD_TRUST_DIR}"
    }

    # chip-tool FileAttestationTrustStore only loads *.der files.
    chip_tool_trust_paa_count() {
        find "$(resolve_chip_tool_paa_trust_dir)" -maxdepth 1 -type f -name '*.der' 2>/dev/null | wc -l
    }

    chip_tool_trust_cd_count() {
        find "$(resolve_chip_tool_cd_trust_dir)" -maxdepth 1 -type f -name '*.der' 2>/dev/null | wc -l
    }

    chip_tool_trust_store_ready() {
        [[ "$(chip_tool_trust_paa_count)" -gt 0 || "$(chip_tool_trust_cd_count)" -gt 0 ]]
    }

    parse_vendor_id_from_payload() {
        local payload="$1"
        local parsed vid_dec vid_hex

        parsed="$(chip-tool payload parse-setup-payload "$payload" 2>/dev/null || true)"
        vid_dec="$(sed -n 's/.*VendorID:[[:space:]]*\([0-9]*\).*/\1/p' <<<"$parsed" | head -1)"
        vid_hex="$(sed -n 's/.*VendorID:[[:space:]]*0x\([0-9A-Fa-f]*\).*/\1/p' <<<"$parsed" | head -1)"

        if [[ -n "$vid_dec" && "$vid_dec" != "0" ]]; then
            printf '0x%04X' "$vid_dec"
            return 0
        fi
        if [[ -n "$vid_hex" && "$vid_hex" != "0" ]]; then
            printf '0x%04X' "0x${vid_hex}"
            return 0
        fi
        return 1
    }

    prompt_vendor_id_optional() {
        local entry vid_num
        echo -ne "[prompt] Vendor ID in hex (e.g. 117C for IKEA), or Enter to skip: " >&2
        read -r entry </dev/tty 2>/dev/null || entry=""
        entry="${entry#0x}"
        entry="${entry#0X}"
        entry="$(printf '%s' "$entry" | tr '[:lower:]' '[:upper:]' | tr -cd '0-9A-F')"
        [[ -n "$entry" ]] || return 1
        vid_num=$((16#$entry))
        printf '0x%04X' "$vid_num"
    }

    _sanitize_cert_basename() {
        local name="$1"
        name="$(basename "$name")"
        name="${name// /_}"
        name="$(printf '%s' "$name" | tr -cd '[:alnum:]._-')"
        [[ -n "$name" ]] || name="cert"
        printf '%s' "$name"
    }

    _cert_dest_for_kind() {
        local kind="$1"
        local basename="$2"
        case "$kind" in
            paa) printf '%s/%s' "${CHIP_TOOL_PAA_TRUST_DIR}" "$basename" ;;
            cd) printf '%s/%s' "${CHIP_TOOL_CD_TRUST_DIR}" "$basename" ;;
            *) return 1 ;;
        esac
    }

    _prompt_cert_kind() {
        local choice=""
        echo "" >&2
        echo "Certificate type:" >&2
        echo "  1) PAA root (Product Attestation Authority)" >&2
        echo "  2) CD signing key (CSA Certification Declaration)" >&2
        echo -ne "[prompt] Choice [1]: " >&2
        read -r choice </dev/tty 2>/dev/null || choice=""
        case "${choice:-1}" in
            1 | paa | PAA) echo "paa" ;;
            2 | cd | CD) echo "cd" ;;
            *) echo "paa" ;;
        esac
    }

    add_chip_tool_trust_cert_file() {
        local src_path="$1"
        local kind="${2:-}"

        [[ -f "$src_path" ]] || {
            _trust_warn "Certificate file not found: ${src_path}"
            return 1
        }

        ensure_chip_tool_trust_dirs
        [[ -n "$kind" ]] || kind="$(_prompt_cert_kind)"

        local base ext dest
        base="$(_sanitize_cert_basename "$src_path")"
        ext="${src_path##*.}"
        [[ "$ext" == "$src_path" ]] && ext="pem"
        dest="$(_cert_dest_for_kind "$kind" "${base}.${ext}")"

        if [[ -e "$dest" ]]; then
            echo -ne "[prompt] Replace existing ${dest}? [y/N]: " >&2
            local replace=""
            read -r replace </dev/tty 2>/dev/null || replace=""
            [[ "${replace,,}" == "y" || "${replace,,}" == "yes" ]] || {
                _trust_info "Kept existing certificate: ${dest}"
                return 0
            }
        fi

        cp -f "$src_path" "$dest"
        _ensure_der_from_cert "$dest" || true
        _trust_info "Installed ${kind^^} certificate: ${dest}"
    }

    add_chip_tool_trust_cert_pem() {
        local kind="${1:-}"
        local pem=""
        local line=""

        ensure_chip_tool_trust_dirs
        [[ -n "$kind" ]] || kind="$(_prompt_cert_kind)"

        echo "" >&2
        echo "Paste PEM certificate (blank line to finish):" >&2
        while IFS= read -r line </dev/tty 2>/dev/null; do
            [[ -z "$line" && -n "$pem" ]] && break
            pem+="${line}"$'\n'
        done

        [[ -n "$pem" ]] || {
            _trust_warn "No certificate pasted"
            return 1
        }

        local dest
        dest="$(_cert_dest_for_kind "$kind" "pasted-$(date +%s).pem")"
        printf '%s' "$pem" >"$dest"
        _ensure_der_from_cert "$dest" || true
        _trust_info "Installed ${kind^^} certificate: ${dest}"
    }

    install_csa_cd_signing_keys() {
        local i url dest
        ensure_chip_tool_trust_dirs
        command -v curl &>/dev/null || {
            _trust_warn "curl required to download CSA CD signing keys"
            return 1
        }

        _trust_info "Downloading CSA Matter CD signing keys..."
        for i in 001 002 003 004 005; do
            url="${CSA_CD_BASE_URL}/CSA_Matter_CD_Signing_Key_${i}.cert.pem"
            dest="${CHIP_TOOL_CD_TRUST_DIR}/CSA_Matter_CD_Signing_Key_${i}.pem"
            if curl -fsSL -o "$dest" "$url"; then
                _ensure_der_from_cert "$dest" || true
                _trust_info "  ${dest}"
            else
                _trust_warn "  failed: ${url}"
                rm -f "$dest" "${dest%.*}.der"
            fi
        done
        [[ "$(chip_tool_trust_cd_count)" -gt 0 ]]
    }

    _sync_connectedhomeip_paa_mirror() {
        local mirror_dir="${CHIP_TOOL_PAA_MIRROR_DIR}"
        local sparse_path="credentials/development/paa-root-certs"

        command -v git &>/dev/null || return 1

        if [[ ! -d "${mirror_dir}/.git" ]]; then
            _trust_info "Cloning connectedhomeip PAA index (one-time, shallow; may take a minute)..."
            git clone --depth 1 --filter=blob:none --sparse \
                https://github.com/project-chip/connectedhomeip.git "${mirror_dir}" \
                || return 1
            git -C "${mirror_dir}" sparse-checkout set "${sparse_path}" || return 1
        else
            if ! git -C "${mirror_dir}" fetch --depth 1 origin 2>/dev/null \
                || ! git -C "${mirror_dir}" reset --hard FETCH_HEAD 2>/dev/null; then
                _trust_warn "Could not refresh PAA mirror; using cached index"
            fi
        fi
        [[ -d "${mirror_dir}/${sparse_path}" ]]
    }

    install_vendor_paa_for_vid() {
        local vid="$1"
        local vid_token vid_upper name src dest installed=0
        local base_url="https://raw.githubusercontent.com/project-chip/connectedhomeip/master/credentials/development/paa-root-certs"

        ensure_chip_tool_trust_dirs
        command -v curl &>/dev/null || {
            _trust_warn "curl required to download vendor PAA certificates"
            return 1
        }

        vid_upper="${vid#0x}"
        vid_upper="${vid_upper^^}"
        vid_token="vid_0x${vid_upper}"

        _trust_info "Searching connectedhomeip mirror for PAA certs matching ${vid_token}..."

        if _sync_connectedhomeip_paa_mirror; then
            while IFS= read -r -d '' src; do
                name="$(basename "$src")"
                dest="${CHIP_TOOL_PAA_TRUST_DIR}/${name}"
                cp -f "$src" "$dest"
                if [[ "$dest" == *.pem ]]; then
                    _ensure_der_from_cert "$dest" || true
                fi
                _trust_info "  ${dest}"
                installed=1
            done < <(find "${CHIP_TOOL_PAA_MIRROR_DIR}/credentials/development/paa-root-certs" \
                -maxdepth 1 -type f -iname "*${vid_token}*" \( -name '*.der' -o -name '*.pem' \) -print0 2>/dev/null)
        fi

        if [[ "$installed" -eq 0 ]]; then
            while IFS= read -r name; do
                [[ -n "$name" ]] || continue
                dest="${CHIP_TOOL_PAA_TRUST_DIR}/${name}"
                if curl -fsSL -o "$dest" "${base_url}/${name}"; then
                    if [[ "$dest" == *.pem ]]; then
                        _ensure_der_from_cert "$dest" || true
                    fi
                    _trust_info "  ${dest}"
                    installed=1
                else
                    rm -f "$dest" "${dest%.*}.der"
                fi
            done < <(curl -fsSL "${PAA_MIRROR_API}?per_page=100" 2>/dev/null \
                | python3 -c "import json,sys; token=sys.argv[1].lower(); data=json.load(sys.stdin); print('\n'.join(i['name'] for i in data if token in i.get('name','').lower() and i['name'].endswith(('.pem','.der'))))" \
                    "$vid_token" 2>/dev/null || true)
        fi

        if [[ "$installed" -eq 0 ]]; then
            _trust_warn "No mirrored PAA certificate found for vendor ${vid}; add a .pem/.der file manually"
            return 1
        fi
        return 0
    }

    bootstrap_chip_tool_trust_for_payload() {
        local payload="$1"
        local vid=""

        vid="$(parse_vendor_id_from_payload "$payload" 2>/dev/null || true)"
        install_csa_cd_signing_keys || true
        if [[ -z "$vid" ]] && interactive_prompt_available; then
            _trust_warn "Pairing code does not encode vendor ID (common for manual codes)"
            vid="$(prompt_vendor_id_optional 2>/dev/null || true)"
        fi
        if [[ -n "$vid" ]]; then
            install_vendor_paa_for_vid "$vid" || true
        else
            _trust_warn "No vendor PAA installed; DCL may still supply roots during commissioning"
        fi
        chip_tool_trust_store_ready
    }

    _print_trust_store_status() {
        local vid="${1:-}"
        echo "" >&2
        _normalize_trust_store_ders
        _trust_info "Attestation trust store: ${CHIP_TOOL_TRUST_BASE}"
        _trust_info "  PAA roots: $(chip_tool_trust_paa_count) der  CD keys: $(chip_tool_trust_cd_count) der"
        if chip_tool_is_snap; then
            _trust_info "  Runtime path: $(resolve_chip_tool_trust_base)"
        fi
        if [[ -n "$vid" ]]; then
            _trust_info "  Device vendor ID: ${vid}"
        fi
        return 0
    }

    _prompt_attestation_menu() {
        local vid="${1:-}"
        local choice=""

        echo "" >&2
        echo "Matter device attestation (chip-tool trust store)" >&2
        echo "  Trust anchors verify the device's DAC/PAI chain during commissioning." >&2
        echo "  You do not add the device's unique DAC — only PAA/CD roots." >&2
        echo "" >&2
        echo "  1) Install CSA CD keys + vendor PAA (recommended; prompts for VID if needed)" >&2
        echo "  2) Add certificate from file path" >&2
        echo "  3) Paste PEM certificate" >&2
        echo "  4) Use DCL online lookup only (skip local cert install)" >&2
        echo "  5) Skip attestation verification (bypass)" >&2
        echo "  6) Continue with current trust store" >&2
        if ! interactive_prompt_available; then
            printf '%s' "1"
            return 0
        fi
        echo -ne "[prompt] Choice [1]: " >&2
        read -r choice </dev/tty || choice=""
        printf '%s' "${choice:-1}"
    }

    _attestation_bypass_marker() {
        printf '%s/.bypass-attestation' "$(resolve_chip_tool_trust_base)"
    }

    _set_attestation_bypass_persisted() {
        local enabled="$1"
        ensure_chip_tool_trust_dirs
        if [[ "$enabled" == "true" ]]; then
            : >"$(_attestation_bypass_marker)"
        else
            rm -f "$(_attestation_bypass_marker)"
        fi
    }

    _attestation_bypass_persisted() {
        [[ -f "$(_attestation_bypass_marker)" ]]
    }

    _export_attestation_verify_defaults() {
        export CHIP_TOOL_ATTESTATION_BYPASS="false"
        export CHIP_TOOL_USE_DCL="true"
    }

    _export_attestation_bypass() {
        export CHIP_TOOL_ATTESTATION_BYPASS="true"
        export CHIP_TOOL_USE_DCL="false"
    }

    # Interactive trust-store setup (iotstack matter configure-trust-store).
    configure_chip_tool_attestation_trust() {
        local payload="${1:-}"
        local vid=""
        local choice=""
        local file_path=""
        local add_more=""

        ensure_chip_tool_trust_dirs

        if ! interactive_prompt_available; then
            _trust_warn "configure-trust-store requires an interactive terminal"
            return 1
        fi

        if [[ -n "$payload" ]]; then
            vid="$(parse_vendor_id_from_payload "$payload" 2>/dev/null || true)"
        fi

        _print_trust_store_status "$vid" || true

        if chip_tool_trust_store_ready; then
            echo -ne "[prompt] Trust store already has certificates. Reconfigure? [y/N]: " >&2
            read -r choice </dev/tty 2>/dev/null || choice=""
            if [[ "${choice,,}" != "y" && "${choice,,}" != "yes" ]]; then
                if _attestation_bypass_persisted; then
                    _export_attestation_bypass
                else
                    _export_attestation_verify_defaults
                fi
                return 0
            fi
        fi

        while true; do
            choice="$(_prompt_attestation_menu "$vid")"
            case "$choice" in
                1)
                    bootstrap_chip_tool_trust_for_payload "$payload" \
                        || _trust_warn "Bootstrap incomplete; add certs manually or choose bypass"
                    _print_trust_store_status "$vid" || true
                    ;;
                2)
                    echo -ne "[prompt] Certificate file path: " >&2
                    read -r file_path </dev/tty 2>/dev/null || file_path=""
                    file_path="$(printf '%s' "$file_path" | sed -e 's/^["'\'']//' -e 's/["'\'']$//' -e "s/^~/${HOME}/")"
                    [[ -n "$file_path" ]] && add_chip_tool_trust_cert_file "$file_path" || true
                    _print_trust_store_status "$vid" || true
                    ;;
                3)
                    add_chip_tool_trust_cert_pem || true
                    _print_trust_store_status "$vid" || true
                    ;;
                4)
                    _set_attestation_bypass_persisted false
                    _export_attestation_verify_defaults
                    _trust_info "Will use DCL (on.dcl.csa-iot.org) during commissioning"
                    return 0
                    ;;
                5)
                    _set_attestation_bypass_persisted true
                    _export_attestation_bypass
                    _trust_warn "Attestation verification will be bypassed on future commissions"
                    return 0
                    ;;
                6)
                    if chip_tool_trust_store_ready; then
                        _set_attestation_bypass_persisted false
                        _export_attestation_verify_defaults
                        return 0
                    fi
                    _trust_warn "Trust store is empty; choose option 1-4 or 5 (bypass)"
                    ;;
                *)
                    _trust_warn "Invalid choice"
                    ;;
            esac

            echo -ne "[prompt] Add another certificate? [y/N]: " >&2
            read -r add_more </dev/tty 2>/dev/null || add_more=""
            if [[ "${add_more,,}" == "y" || "${add_more,,}" == "yes" ]]; then
                continue
            fi

            if [[ "${CHIP_TOOL_ATTESTATION_BYPASS:-}" == "true" ]]; then
                _set_attestation_bypass_persisted true
                return 0
            fi

            if chip_tool_trust_store_ready; then
                _set_attestation_bypass_persisted false
                _export_attestation_verify_defaults
                return 0
            fi

            echo -ne "[prompt] Trust store still empty. Bypass attestation? [y/N]: " >&2
            read -r add_more </dev/tty 2>/dev/null || add_more=""
            if [[ "${add_more,,}" == "y" || "${add_more,,}" == "yes" ]]; then
                _set_attestation_bypass_persisted true
                _export_attestation_bypass
                return 0
            fi
        done

        return 0
    }

    # Apply persisted trust settings during commissioning (non-interactive).
    apply_chip_tool_attestation_trust() {
        local payload="${1:-}"
        local vid=""

        ensure_chip_tool_trust_dirs

        if [[ "${IOTSTACK_BYPASS_ATTESTATION:-}" == "1" || "${IOTSTACK_BYPASS_ATTESTATION:-}" == "true" ]]; then
            _export_attestation_bypass
            _trust_warn "Attestation verification bypassed (IOTSTACK_BYPASS_ATTESTATION)"
            return 0
        fi

        if _attestation_bypass_persisted; then
            _export_attestation_bypass
            _trust_warn "Attestation verification bypassed (configured via matter configure-trust-store)"
            return 0
        fi

        if [[ -n "$payload" ]]; then
            vid="$(parse_vendor_id_from_payload "$payload" 2>/dev/null || true)"
        fi

        if [[ "${IOTSTACK_ATTESTATION_AUTO_BOOTSTRAP:-}" == "1" && -n "$payload" ]]; then
            bootstrap_chip_tool_trust_for_payload "$payload" || true
            _export_attestation_verify_defaults
            _print_trust_store_status "$vid" || true
            return 0
        fi

        _normalize_trust_store_ders

        if chip_tool_trust_store_ready; then
            _export_attestation_verify_defaults
            _print_trust_store_status "$vid" || true
            return 0
        fi

        if ! interactive_prompt_available; then
            if [[ -n "$payload" ]]; then
                bootstrap_chip_tool_trust_for_payload "$payload" || true
            fi
            _normalize_trust_store_ders
            if chip_tool_trust_store_ready; then
                _export_attestation_verify_defaults
                _print_trust_store_status "$vid" || true
                return 0
            fi
            _export_attestation_bypass
            _trust_warn "Non-interactive session with empty trust store; bypassing attestation"
            return 0
        fi

        _print_trust_store_status "$vid" || true
        _trust_warn "Matter attestation trust store is not configured"
        _trust_warn "Run: iotstack matter configure-trust-store"
        return 1
    }

    # Backward compatibility for scripts that still call the old name.
    ensure_chip_tool_attestation_trust() {
        apply_chip_tool_attestation_trust "$@"
    }

    chip_tool_attestation_args() {
        if [[ "${CHIP_TOOL_ATTESTATION_BYPASS:-false}" == "true" ]]; then
            echo --bypass-attestation-verifier true
            return 0
        fi

        ensure_chip_tool_trust_dirs
        _normalize_trust_store_ders

        # Passing --paa-trust-store-path with zero loadable .der certs is a hard error in chip-tool.
        if [[ "$(chip_tool_trust_paa_count)" -gt 0 ]]; then
            echo --paa-trust-store-path "$(resolve_chip_tool_paa_trust_dir)"
        fi
        if [[ "$(chip_tool_trust_cd_count)" -gt 0 ]]; then
            echo --cd-trust-store-path "$(resolve_chip_tool_cd_trust_dir)"
        fi
        if [[ "${CHIP_TOOL_USE_DCL:-true}" == "true" ]]; then
            echo --use-dcl true
        fi
    }
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    configure_chip_tool_attestation_trust "${1:-}"
fi