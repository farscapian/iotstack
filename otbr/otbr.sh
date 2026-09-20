#!/usr/bin/env bash
# OpenThread Border Router commands for iotstack.
# Sourced by iotstack.sh -- do not execute directly.

if [[ -n "${_IOTSTACK_OTBR_LOADED:-}" ]]; then
    # shellcheck disable=SC2317  # exit 0 is the fallback when not sourced
    return 0 2>/dev/null || exit 0
fi
_IOTSTACK_OTBR_LOADED=1

_OTBR_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
_OTBR_REPO_ROOT="$(cd "${_OTBR_DIR}/.." && pwd)"
_OTBR_HOME="${IOTSTACK_HOME:-${HOME}/.iotstack}/otbr"

# Append a minimal Host block to ~/.ssh/config for $1 if none exists.
_otbr_ensure_ssh_config() {
    local _host="$1"
    local _ssh_cfg="${HOME}/.ssh/config"
    mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
    [[ -f "$_ssh_cfg" ]] || { touch "$_ssh_cfg"; chmod 600 "$_ssh_cfg"; }
    if grep -qE "^Host[[:space:]]+${_host}([[:space:]]|$)" "$_ssh_cfg" 2>/dev/null; then
        return 0
    fi
    echo "[otbr] No SSH config entry for '${_host}' -- appending stub to ${_ssh_cfg}"
    printf '\nHost %s\n    HostName %s.local\n    User ubuntu\n' "$_host" "$_host" >> "$_ssh_cfg"
    chmod 600 "$_ssh_cfg"
}

# Monitor a log stream and alert when the OTBR agent stops or crashes.
_otbr_alert_on_otbr_down() {
    grep --line-buffered -E \
        '\[otbr-snap\].*(Stopped snap\.openthread-border-router\.otbr-agent|Main process exited|spinel_driver\.cpp.*Failure|HandleRcpTimeout)' \
    | while IFS= read -r _line; do
        printf '\a\a\a\n\033[1;31m*** OTBR AGENT DOWN ***\033[0m %s\n' "$_line" > /dev/tty
        if command -v notify-send &>/dev/null; then
            notify-send -u critical -t 0 "OTBR Agent Down" "$_line" 2>/dev/null || true
        fi
    done
}

# Remove $1 (and its resolved HostName) from ~/.ssh/known_hosts.
_otbr_remove_known_host() {
    local _host="$1"
    local _known="${HOME}/.ssh/known_hosts"
    [[ -f "$_known" ]] || return 0
    echo "[otbr] Removing stale host keys for '${_host}' from known_hosts ..."
    ssh-keygen -f "$_known" -R "$_host" 2>/dev/null || true
    local _resolved
    _resolved=$(ssh -G "$_host" 2>/dev/null | awk '/^hostname / {print $2; exit}')
    if [[ -n "$_resolved" && "$_resolved" != "$_host" ]]; then
        ssh-keygen -f "$_known" -R "$_resolved" 2>/dev/null || true
    fi
}

# Ensure ~/.iotstack/otbr exists and create convenience symlink in otbr/.
_otbr_ensure_home_symlink() {
    mkdir -p "$_OTBR_HOME"

    local _symlink="${_OTBR_DIR}/.iotstack"
    if [[ -L "$_symlink" && "$(readlink -f "$_symlink")" == "$_OTBR_HOME" ]]; then
        return 0
    elif [[ -e "$_symlink" && ! -L "$_symlink" ]]; then
        echo "[otbr] Warning: ${_symlink} exists but is not a symlink; skipping" >&2
        return 0
    fi

    [[ -L "$_symlink" ]] && rm "$_symlink"
    ln -s "$_OTBR_HOME" "$_symlink"
}

_otbr_git_head() {
    git -C "$_OTBR_REPO_ROOT" log -1 --oneline 2>/dev/null || echo 'no git'
}

# Resolve and export OTBR configuration for operational commands (vm, flash,
# docker, snap). Non-secret settings come from the iotstack environment file
# (~/.iotstack/environments/*.env, see the global -env= flag) and can be
# overridden by exporting the same variable before invoking iotstack --
# iotstack_env_name/iotstack_pass_common_read come from scripts/config.sh,
# already sourced by iotstack.sh before cmd_otbr runs. Network secrets (WiFi,
# Thread dataset) come from the iotstack pass store, seeded under
# iotstack/<env>/common/* by setup.sh; an explicit export overrides those too.
_otbr_load_config() {
    export OTBR_HOSTNAME="${OTBR_HOSTNAME:-otbr-raspi4}"
    export DEPLOY_MATTER_SERVER="${DEPLOY_MATTER_SERVER:-1}"
    export SSH_PUBKEY="${SSH_PUBKEY:-}"
    export SSH_MGMT_CIDRS="${SSH_MGMT_CIDRS:-}"
    export OTBR_SNAP_CHANNEL="${OTBR_SNAP_CHANNEL:-latest/edge}"
    export CHIP_TOOL_SNAP_CHANNEL="${CHIP_TOOL_SNAP_CHANNEL:-latest/stable}"
    export SKIP_IMAGE_VERIFICATION="${SKIP_IMAGE_VERIFICATION:-0}"
    export PULL_LATEST_REPOS="${PULL_LATEST_REPOS:-1}"
    export SKIP_RCP_VERIFY="${SKIP_RCP_VERIFY:-0}"
    export SKIP_CHROOT="${SKIP_CHROOT:-0}"
    export MQTT_BROKER="${MQTT_BROKER:-}"
    export MQTT_PORT="${MQTT_PORT:-1883}"
    export MQTT_USER="${MQTT_USER:-}"
    export MQTT_PASSWORD="${MQTT_PASSWORD:-}"

    export WIFI_SSID="${WIFI_SSID:-$(iotstack_pass_common_read wifi_ssid 2>/dev/null || echo "")}"
    export WIFI_PASSWORD="${WIFI_PASSWORD:-$(iotstack_pass_common_read wifi_password 2>/dev/null || echo "")}"
    _OTBR_THREAD_TLV_SOURCE="pass entry $(iotstack_pass_common_path thread_tlv)"
    [[ -n "${THREAD_DATASET_TLV:-}" ]] && _OTBR_THREAD_TLV_SOURCE="THREAD_DATASET_TLV from the environment"
    export THREAD_DATASET_TLV="${THREAD_DATASET_TLV:-$(iotstack_pass_common_read thread_tlv 2>/dev/null || echo "")}"
    [[ "$WIFI_SSID" == "CONFIGURE_ME" ]] && WIFI_SSID=""
    [[ "$WIFI_PASSWORD" == "CONFIGURE_ME" ]] && WIFI_PASSWORD=""
    [[ "$THREAD_DATASET_TLV" == "CONFIGURE_ME" ]] && THREAD_DATASET_TLV=""

    if [[ -n "${HTTP_PROXY:-}" ]]; then
        export http_proxy="$HTTP_PROXY" https_proxy="$HTTP_PROXY"
        local _proxy_hostport="${HTTP_PROXY#*://}"
        _proxy_hostport="${_proxy_hostport%/}"
        if command -v wait-for-it &>/dev/null; then
            if ! wait-for-it --timeout=5 "$_proxy_hostport" -- true 2>/dev/null; then
                echo "[otbr] WARNING: HTTP proxy ${_proxy_hostport} is not reachable; network operations may fail" >&2
            fi
        fi
    fi
}

# Check that the Thread dataset about to be provisioned matches the one Home
# Assistant uses, so this border router does not end up on a different Thread
# network than the rest of the home. Must run after _otbr_load_config.
#
# Runs only when pass holds a real ha_url AND ha_token (independent of
# PERFORM_HA_DEVICE_REGISTRATION); otherwise it is skipped. A mismatch aborts.
# Home Assistant being unreachable, or having no Thread dataset, only warns --
# there is nothing to compare against. SKIP_HA_THREAD_VERIFY=1 bypasses it.
_otbr_verify_thread_dataset_with_ha() {
    if [[ "${SKIP_HA_THREAD_VERIFY:-0}" == "1" ]]; then
        echo "[otbr] SKIP_HA_THREAD_VERIFY=1 -- not checking the Thread dataset against Home Assistant"
        return 0
    fi

    # Empty or CONFIGURE_ME: nothing to compare (the provisioners report it).
    [[ -n "${THREAD_DATASET_TLV:-}" ]] || return 0

    # shellcheck source=scripts/ensure-integration-secrets.sh
    source "${_OTBR_REPO_ROOT}/scripts/ensure-integration-secrets.sh"
    if ! load_ha_credentials_from_pass; then
        echo "[otbr] No usable ha_url/ha_token in pass -- skipping Home Assistant Thread dataset check"
        return 0
    fi

    echo "[otbr] Verifying Thread dataset against Home Assistant (${HA_URL}) ..."
    local _out _rc=0
    _out="$(python3 "${_OTBR_REPO_ROOT}/scripts/ha_websocket.py" \
        --ha-url "$HA_URL" --ha-token "$HA_TOKEN" \
        verify-thread-dataset 2>&1)" || _rc=$?
    _out="${_out#\[error\] }"

    case "$_rc" in
        0)
            echo "[otbr] OK: ${_out}"
            ;;
        3)
            echo "[otbr] ERROR: ${_OTBR_THREAD_TLV_SOURCE:-Thread dataset} failed the Home Assistant Thread dataset check:" >&2
            echo "[otbr]        ${_out}" >&2
            echo "[otbr]        Provisioning with a dataset that does not match Home Assistant's would put this border router on a different Thread network." >&2
            echo "[otbr]        Fix: pass edit $(iotstack_pass_common_path thread_tlv)  (hex from HA Settings -> Thread)" >&2
            echo "[otbr]        Or, to provision anyway: SKIP_HA_THREAD_VERIFY=1 iotstack otbr <command>" >&2
            return 1
            ;;
        *)
            echo "[otbr] WARNING: could not verify the Thread dataset against Home Assistant -- continuing unverified: ${_out}" >&2
            ;;
    esac
}

_otbr_show_help() {
    cat <<'EOF'
iotstack otbr -- OpenThread Border Router provisioning

Usage:
  iotstack otbr <command> [args]

Commands:
  vm x64            Incus VM test (native x86_64)
  vm arm64          Incus VM (arm64)
  flash             Flash Ubuntu Server 26.04 to SD card (needs /dev/sdX)
  docker            Docker bare-metal provisioner
  snap              Snap bare-metal provisioner
  snap stop         Gracefully leave the Thread network and stop the local OTBR snap
  logs [-f] <host>  Tail cloud-init + firstboot + OTBR snap logs over SSH
  shutdown <host>   Graceful shutdown of a remote OTBR device
  restart <host>    Reboot a remote OTBR device
  help              Show this help


EOF
}

cmd_otbr_dispatch() {
    _otbr_ensure_home_symlink

    local _pass_args=()
    local _arg _cmd=""

    for _arg in "$@"; do
        case "$_arg" in
            help) [[ -z "$_cmd" ]] && _cmd="help" ;;
            setup|vm|flash|docker|snap|shutdown|restart|logs)
                [[ -z "$_cmd" ]] && _cmd="$_arg"
                ;;
            *)
                if [[ -n "$_cmd" ]]; then
                    _pass_args+=("$_arg")
                else
                    _cmd="$_arg"
                fi
                ;;
        esac
    done

    local cmd="${_cmd:-}"

    # Export OTBR_HOME so child scripts can locate cache/artifacts/logs.
    export OTBR_HOME="$_OTBR_HOME"

    case "$cmd" in
        help|"")
            _otbr_show_help
            [[ -n "$_cmd" && "$_cmd" != "help" ]] && return 1
            return 0
            ;;
        setup)
            # shellcheck source=scripts/ensure-otbr-deps.sh
            source "${_OTBR_REPO_ROOT}/scripts/ensure-otbr-deps.sh"
            install_otbr_apt_packages
            install_otbr_esptool
            install_otbr_incus
            echo ""
            echo "============================================================"
            echo "  OTBR setup complete."
            echo "  Run:  iotstack otbr help"
            echo ""
            echo "  Configure network settings in:"
            echo "    ~/.iotstack/environments/default.env (see docs/.env.example)"
            echo "  Configure WiFi/Thread secrets with:"
            echo "    pass edit iotstack/default/common/wifi_ssid"
            echo "    pass edit iotstack/default/common/wifi_password"
            echo "    pass edit iotstack/default/common/thread_tlv"
            echo "============================================================"
            return 0
            ;;
    esac

    # Resolve config and secrets for operational commands (not logs/shutdown/restart
    # or 'snap stop', which needs no Thread dataset).
    if [[ "$cmd" != "logs" && "$cmd" != "shutdown" && "$cmd" != "restart" \
          && ! ( "$cmd" == "snap" && "${_pass_args[0]:-}" == "stop" ) ]]; then
        _otbr_load_config
        case "$cmd" in
            vm|flash|docker|snap) _otbr_verify_thread_dataset_with_ha || return 1 ;;
        esac
    fi

    case "$cmd" in
        vm)
            if ! command -v incus &>/dev/null; then
                echo "[otbr] incus not found -- installing and initializing it ..."
                # shellcheck source=scripts/ensure-otbr-deps.sh
                source "${_OTBR_REPO_ROOT}/scripts/ensure-otbr-deps.sh"
                install_otbr_incus
                if ! command -v incus &>/dev/null; then
                    echo "[otbr] ERROR: incus still not available after setup. Aborting." >&2
                    return 1
                fi
            fi

            local _use_sg=0
            if ! incus info &>/dev/null 2>&1; then
                if getent group incus-admin 2>/dev/null | grep -qw "$USER"; then
                    echo "[otbr] NOTE: ${USER} is in the incus-admin group but it is not active" \
                         "in this shell session (it was added since your last login)." >&2
                    echo "[otbr] Using 'sg incus-admin' to activate the group for this command." \
                         "Open a new terminal after this to avoid the message in future runs." >&2
                    _use_sg=1
                else
                    echo "[otbr] ERROR: cannot reach incus daemon and ${USER} is not in incus-admin." \
                         "Run: ./setup.sh" >&2
                    return 1
                fi
            fi

            local _arch="${_pass_args[0]:-}"
            local _vm_args=("${_pass_args[@]:1}")

            local _vm_log_name="otbrvm64"
            if [[ "$_arch" == "arm64" || "$_arch" == "aarch64" ]]; then
                _vm_log_name="otbrarm64"
            fi
            for _a in "${_vm_args[@]+"${_vm_args[@]}"}"; do
                case "$_a" in
                    --container) _vm_log_name="otbr-ct" ;;
                    --name=*)    _vm_log_name="${_a#--name=}" ;;
                esac
            done
            local _otbr_log="${_OTBR_HOME}/logs/${_vm_log_name}/vm.log"
            mkdir -p "$(dirname "$_otbr_log")"
            echo "[otbr] Logging to: ${_otbr_log}"
            printf '\n=== iotstack otbr vm %s %s -- %s ===\n' \
                "$_arch" "$(date '+%Y-%m-%d %H:%M:%S')" \
                "$(_otbr_git_head)" \
                | tee -a "$_otbr_log"

            case "$_arch" in
                x64|x86_64)
                    echo "[otbr] Incus VM (native x86_64)  (scripts: ${_OTBR_DIR})"
                    {
                        if [[ "$_use_sg" -eq 1 ]]; then
                            sg incus-admin -c "\"$_OTBR_DIR/scripts/provision_incus.sh\" ${_vm_args[*]+"${_vm_args[*]}"}"
                        else
                            "$_OTBR_DIR/scripts/provision_incus.sh" "${_vm_args[@]+"${_vm_args[@]}"}"
                        fi
                    } 2>&1 | tee -a "$_otbr_log"
                    ;;
                arm64|aarch64)
                    echo "[otbr] Incus VM (arm64)  (scripts: ${_OTBR_DIR})"
                    {
                        if [[ "$_use_sg" -eq 1 ]]; then
                            sg incus-admin -c "\"$_OTBR_DIR/scripts/provision_incus.sh\" --arch=arm64 ${_vm_args[*]+"${_vm_args[*]}"}"
                        else
                            "$_OTBR_DIR/scripts/provision_incus.sh" --arch=arm64 "${_vm_args[@]+"${_vm_args[@]}"}"
                        fi
                    } 2>&1 | tee -a "$_otbr_log"
                    ;;
                *)
                    echo "Usage: iotstack otbr vm <x64|arm64> [extra args]"
                    return 1
                    ;;
            esac
            ;;
        flash)
            echo "[otbr] Flash Ubuntu Server 26.04 to SD card  (scripts: ${_OTBR_DIR})"

            local _flash_log_host="otbr"
            for _a in "${_pass_args[@]+"${_pass_args[@]}"}"; do
                case "$_a" in --hostname=*) _flash_log_host="${_a#--hostname=}" ;; esac
            done
            local _flash_ts
            _flash_ts="$(date '+%Y%m%d-%H%M%S')"
            local _flash_log_slug="flash-${_flash_ts}"
            local _flash_log_dir="${_OTBR_HOME}/logs/${_flash_log_host}/${_flash_log_slug}"
            local _otbr_log="${_flash_log_dir}/flash.log"
            mkdir -p "$_flash_log_dir"
            echo "[otbr] Log directory: ${_flash_log_dir}"

            (
                cd "$_OTBR_REPO_ROOT" || exit 1
                git add -A
                if ! git diff --cached --quiet; then
                    git commit -m "TEMP: pre-flash snapshot $(date '+%Y-%m-%d %H:%M:%S')"
                fi
            )
            local _flash_branch="flash/${_flash_ts}"
            local _flash_wt
            _flash_wt=$(mktemp -d --suffix="-otbr-flash")
            git -C "$_OTBR_REPO_ROOT" worktree add "$_flash_wt" -b "$_flash_branch"
            for _d in cache artifacts; do
                local _src="${_OTBR_HOME}/${_d}"
                mkdir -p "$_src"
                ln -sfn "$_src" "$_flash_wt/otbr/$_d"
            done
            if [[ "$_flash_log_host" != "otbr" ]]; then
                _otbr_ensure_ssh_config "$_flash_log_host"
            fi
            ln -sfn "$_flash_log_slug" "${_OTBR_HOME}/logs/${_flash_log_host}/current"
            echo "[otbr] Running flash from worktree: ${_flash_wt}"
            echo "[otbr] Main working tree remains editable on its current branch."
            printf '\n=== iotstack otbr flash %s -- %s [branch: %s] [logs: %s] ===\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" \
                "$(_otbr_git_head)" \
                "$_flash_branch" \
                "$_flash_log_dir" \
                | tee -a "$_otbr_log"
            { "$_flash_wt/otbr/scripts/flash-piotbr.sh" "${_pass_args[@]+"${_pass_args[@]}"}"; } 2>&1 \
                | tee -a "$_otbr_log"
            local _flash_rc="${PIPESTATUS[0]}"
            git -C "$_OTBR_REPO_ROOT" worktree remove --force "$_flash_wt" \
                || sudo rm -rf "$_flash_wt"
            git -C "$_OTBR_REPO_ROOT" worktree prune 2>/dev/null || true
            echo ""
            echo "[otbr] Flash complete. Flash branch preserved at: ${_flash_branch}"
            echo "[otbr] Git HEAD at time of flash:"
            git -C "$_OTBR_REPO_ROOT" log -1 --oneline "$_flash_branch"
            if [[ "$_flash_log_host" != "otbr" ]]; then
                _otbr_remove_known_host "$_flash_log_host"
            fi
            return "$_flash_rc"
            ;;
        docker)
            echo "[otbr] Docker bare-metal provisioner"
            local _otbr_log
            _otbr_log="${_OTBR_HOME}/logs/$(hostname)/docker.log"
            mkdir -p "$(dirname "$_otbr_log")"
            echo "[otbr] Logging to: ${_otbr_log}"
            printf '\n=== iotstack otbr docker %s -- %s ===\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" \
                "$(_otbr_git_head)" \
                | tee -a "$_otbr_log"
            { "$_OTBR_DIR/scripts/otbrstack-docker-setup.sh" "${_pass_args[@]+"${_pass_args[@]}"}"; } 2>&1 \
                | tee -a "$_otbr_log"
            ;;
        snap)
            local _snap_script="otbrstack-snap-setup.sh" _snap_label=""
            case "${_pass_args[0]:-}" in
                stop)
                    _snap_script="otbrstack-snap-stop.sh"
                    _snap_label=" stop"
                    _pass_args=("${_pass_args[@]:1}")
                    echo "[otbr] Snap graceful stop (leave Thread network)"
                    ;;
                *)
                    echo "[otbr] Snap bare-metal provisioner"
                    ;;
            esac
            local _otbr_log
            _otbr_log="${_OTBR_HOME}/logs/$(hostname)/snap.log"
            mkdir -p "$(dirname "$_otbr_log")"
            echo "[otbr] Logging to: ${_otbr_log}"
            printf '\n=== iotstack otbr snap%s %s -- %s ===\n' \
                "$_snap_label" \
                "$(date '+%Y-%m-%d %H:%M:%S')" \
                "$(_otbr_git_head)" \
                | tee -a "$_otbr_log"
            { "$_OTBR_DIR/scripts/${_snap_script}" "${_pass_args[@]+"${_pass_args[@]}"}"; } 2>&1 \
                | tee -a "$_otbr_log"
            return "${PIPESTATUS[0]}"
            ;;
        shutdown)
            local _host="${_pass_args[0]:-}"
            if [[ -z "$_host" ]]; then
                echo "Usage: iotstack otbr shutdown <ssh_host>"
                return 1
            fi
            _otbr_ensure_ssh_config "$_host"
            echo "[otbr] Shutting down ${_host} ..."
            ssh -o StrictHostKeyChecking=accept-new "$_host" -- sudo shutdown -h now
            ;;
        restart)
            local _host="${_pass_args[0]:-}"
            if [[ -z "$_host" ]]; then
                echo "Usage: iotstack otbr restart <ssh_host>"
                return 1
            fi
            _otbr_ensure_ssh_config "$_host"
            echo "[otbr] Restarting ${_host} ..."
            ssh -o StrictHostKeyChecking=accept-new "$_host" -- sudo reboot
            ;;
        logs)
            local _follow=0 _host=""
            for _arg in "${_pass_args[@]+"${_pass_args[@]}"}"; do
                case "$_arg" in
                    -f) _follow=1 ;;
                    *)  _host="$_arg" ;;
                esac
            done
            if [[ -z "$_host" ]]; then
                echo "Usage: iotstack otbr logs [-f] <ssh_host>"
                return 1
            fi
            _otbr_ensure_ssh_config "$_host"
            local _log_base="${_OTBR_HOME}/logs/${_host}"
            local _log_session_dir
            if [[ -L "${_log_base}/current" ]]; then
                _log_session_dir="${_log_base}/$(readlink "${_log_base}/current")"
            else
                _log_session_dir="${_log_base}"
            fi
            local _otbr_log="${_log_session_dir}/firstboot.log"
            local _snap_log="${_log_session_dir}/otbr-snap.log"
            mkdir -p "$_log_session_dir"
            echo "[otbr] Logs from ${_host} -> ${_log_session_dir}/"
            local _hdr
            _hdr=$(printf '\n=== iotstack otbr logs %s %s -- %s [session: %s] ===' \
                "$_host" "$(date '+%Y-%m-%d %H:%M:%S')" \
                "$(_otbr_git_head)" \
                "$(basename "$_log_session_dir")")
            printf '%s\n' "$_hdr" | tee -a "$_otbr_log" >> "$_snap_log"
            if [[ "$_follow" -eq 1 ]]; then
                local _ssh_target
                _ssh_target=$(ssh -G "$_host" 2>/dev/null | awk '/^hostname / {print $2; exit}')
                _ssh_target="${_ssh_target:-$_host}"
                echo "[otbr] Waiting for SSH on ${_ssh_target}:22 (timeout 300s) ..."
                if command -v wait-for-it &>/dev/null; then
                    if ! wait-for-it --timeout=300 "${_ssh_target}:22"; then
                        echo "[otbr] ERROR: ${_ssh_target}:22 did not become available." >&2
                        return 1
                    fi
                else
                    local _deadline=$(( $(date +%s) + 300 ))
                    while [[ $(date +%s) -lt $_deadline ]]; do
                        nc -z -w3 "$_ssh_target" 22 2>/dev/null && break
                        printf '.'
                        sleep 5
                    done
                    echo ""
                    if ! nc -z -w3 "$_ssh_target" 22 2>/dev/null; then
                        echo "[otbr] ERROR: ${_ssh_target}:22 did not become available." >&2
                        return 1
                    fi
                fi
                ssh -t -o StrictHostKeyChecking=accept-new "$_host" '
                    _cleanup() { kill $(jobs -p) 2>/dev/null; }
                    trap _cleanup EXIT INT TERM
                    sudo journalctl -f -k --no-pager -o short-iso \
                        | sed "s/^/[dmesg] /" &
                    sudo journalctl -f -u "cloud-init*" --no-pager -o short-iso \
                        | sed "s/^/[cloud-init] /" &
                    (until snap list openthread-border-router >/dev/null 2>&1; do
                        sleep 10
                    done; sudo snap logs -f openthread-border-router 2>/dev/null) \
                        | sed "s/^/[otbr-snap] /" &
                    sudo journalctl -f -u "snap.chiptool.*" --no-pager -o short-iso 2>/dev/null \
                        | sed "s/^/[chiptool] /" &
                    sudo tail -f /var/log/otbr-firstboot.log 2>/dev/null \
                        | sed "s/^/[firstboot] /" &
                    wait
                ' | tee -a "$_otbr_log" \
                    >(grep '^\[otbr-snap\]' >> "$_snap_log") \
                    >(_otbr_alert_on_otbr_down)
            else
                ssh -o StrictHostKeyChecking=accept-new "$_host" '
                    _section() { echo; echo "=== [$1] ==="; }
                    _section "dmesg"
                    sudo journalctl -b -k --no-pager -o short-iso \
                        | sed "s/^/[dmesg] /"
                    _section "cloud-init"
                    sudo journalctl -b -u "cloud-init*" --no-pager -o short-iso \
                        | sed "s/^/[cloud-init] /"
                    _section "otbr-snap"
                    sudo snap logs -n=all openthread-border-router \
                        | sed "s/^/[otbr-snap] /"
                    _section "chiptool"
                    sudo journalctl -b -u "snap.chiptool.*" --no-pager -o short-iso \
                        | sed "s/^/[chiptool] /"
                    _section "firstboot"
                    if [[ -f /var/log/otbr-firstboot.log ]]; then
                        sed "s/^/[firstboot] /" /var/log/otbr-firstboot.log
                    else
                        echo "[firstboot] /var/log/otbr-firstboot.log not found"
                    fi
                ' | tee -a "$_otbr_log" >(grep '^\[otbr-snap\]' >> "$_snap_log")
            fi
            ;;
        *)
            echo "[otbr] Unknown command: $cmd"
            _otbr_show_help
            return 1
            ;;
    esac
}