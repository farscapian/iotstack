#!/usr/bin/env bash
# otbrstack-snap-stop.sh
# Gracefully takes the local OTBR snap out of the Thread network: detaches
# (notifying neighbours), brings the Thread interface down, then stops the snap.
# Run as normal user -- sudo is invoked only when needed for snap commands.
# Does not need the Thread dataset; nothing is reconfigured or unprovisioned.

set -euo pipefail

SNAP_NAME="openthread-border-router"
OT_CTL="${SNAP_NAME}.ot-ctl"
DETACH_TIMEOUT=15

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# Prints the number of active services in the snap (0 if none).
_active_service_count() {
    sudo snap services "$SNAP_NAME" | awk 'NR>1 && $3=="active" {n++} END {print n+0}'
}

# Prints the Thread device role (leader/router/child/detached/disabled), or
# nothing if otbr-agent is not answering.
_thread_state() {
    sudo timeout 5 "$OT_CTL" state 2>/dev/null | head -1 || true
}

leave_thread_network() {
    local state
    state=$(_thread_state)

    if [[ -z "$state" ]]; then
        warn "otbr-agent is not answering ot-ctl -- skipping graceful detach."
        return 0
    fi

    log "Thread role: $state"
    case "$state" in
        disabled|detached)
            log "Not attached to a Thread network -- nothing to detach."
            ;;
        *)
            # detach: a router releases its router ID and tells its neighbours;
            # a child tells its parent to drop it immediately instead of waiting
            # out the child timeout.
            log "Detaching gracefully from the Thread network (up to ${DETACH_TIMEOUT}s)..."
            if ! sudo timeout "$DETACH_TIMEOUT" "$OT_CTL" detach >/dev/null 2>&1; then
                warn "Graceful detach did not complete -- stopping Thread anyway."
            fi
            ;;
    esac

    sudo timeout 5 "$OT_CTL" thread stop >/dev/null 2>&1 || true
    sudo timeout 5 "$OT_CTL" ifconfig down >/dev/null 2>&1 || true
}

main() {
    [[ "$EUID" -eq 0 ]] && die "Do not run as root. Run as your normal user -- sudo will be invoked as needed."
    command -v snap &>/dev/null || die "Required command not found: snap"

    if ! snap list "$SNAP_NAME" &>/dev/null; then
        log "OTBR snap not installed -- nothing to stop."
        return 0
    fi

    if [[ "$(_active_service_count)" -eq 0 ]]; then
        log "OTBR snap is already stopped."
        return 0
    fi

    leave_thread_network

    log "Stopping OTBR snap..."
    sudo snap stop "$SNAP_NAME"

    if [[ "$(_active_service_count)" -ne 0 ]]; then
        sudo snap services "$SNAP_NAME" >&2
        die "OTBR snap still has active services after 'snap stop'."
    fi

    log "OTBR stopped and no longer participating in the Thread network."
    log "Bring it back with: iotstack otbr snap"
}

main "$@"
