#!/usr/bin/env bash
# otbrstack-list.sh
# Lists the OTBR instances on this host: the local snap, the Docker container,
# and Incus VMs/containers (x86_64 or arm64).
# Run as normal user. Nothing here prompts for a password: docker falls back to
# 'sudo -n', and an unreachable incus daemon is reported instead of skipped.
#
# Usage: otbrstack-list.sh [-a|--all]
#   -a, --all   Also list instances that are installed but not running
#
# Incus instances are recognised by the user.iotstack-otbr=true config key that
# provision_incus.sh sets, or by a name starting with "otbr" (older instances
# and the default names otbrvm64 / otbrarm64 / otbr-ct).

set -euo pipefail

SNAP_NAME="openthread-border-router"
DOCKER_CONTAINER="otbr"
DOCKER_IMAGE_PREFIX="openthread/otbr"
INCUS_MARKER="user.iotstack-otbr"
SHOW_ALL=0

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# Tab-separated rows: kind, name, state, details. Empty fields are never used
# (column(1) would collapse them), so missing values are "-".
declare -a ROWS=()

# add_row <kind> <name> <state> <details>: keeps running instances, and the
# rest only with --all.
add_row() {
    [[ "$3" == "running" || "$SHOW_ALL" -eq 1 ]] || return 0
    ROWS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"${4:--}")
}

# ---------------------------------------------------------------------------
# snap
# ---------------------------------------------------------------------------

collect_snap() {
    command -v snap &>/dev/null || return 0
    local line ver rev track state
    line=$(snap list "$SNAP_NAME" 2>/dev/null | awk 'NR==2 {print $2, $3, $4}') || true
    [[ -n "$line" ]] || return 0
    read -r ver rev track <<< "$line"

    # The snap counts as running when otbr-agent is active.
    state=$(snap services "$SNAP_NAME" 2>/dev/null | awk '$1 ~ /\.otbr-agent$/ {print $3}') || true
    if [[ "$state" == "active" ]]; then
        state="running"
    else
        state="stopped"
    fi
    add_row "snap" "$SNAP_NAME" "$state" "rev $rev ($track), $ver"
}

# ---------------------------------------------------------------------------
# docker
# ---------------------------------------------------------------------------

# 'docker <args>' as the user, else 'sudo -n docker <args>' (never prompts).
_docker() {
    docker "$@" 2>/dev/null || sudo -n docker "$@" 2>/dev/null
}

collect_docker() {
    command -v docker &>/dev/null || return 0
    local name image state status
    while IFS=$'\t' read -r name image state status; do
        [[ "$image" == "${DOCKER_IMAGE_PREFIX}"* || "$name" == "$DOCKER_CONTAINER" ]] || continue
        [[ "$state" == "running" ]] || state="stopped"
        add_row "docker" "$name" "$state" "$image, $status"
    done < <(_docker ps -a --format '{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}' || true)
}

# ---------------------------------------------------------------------------
# incus
# ---------------------------------------------------------------------------

# Prints 'incus list' as JSON. If this shell does not have the incus-admin
# group yet (added since login), retries under 'sg incus-admin'.
_incus_json() {
    incus list local: --format json 2>/dev/null && return 0
    if getent group incus-admin 2>/dev/null | grep -qw "${USER:-$(id -un)}"; then
        sg incus-admin -c "incus list local: --format json" 2>/dev/null && return 0
    fi
    return 1
}

# Reads 'incus list' JSON on stdin and prints one TSV line per OTBR instance:
# type, name, status, architecture, global IPv4 addresses.
_incus_otbr_rows() {
    jq -r --arg marker "$INCUS_MARKER" '
        .[]
        | select((.name | test("^otbr")) or (.config[$marker] == "true"))
        | [ .type, .name, .status, .architecture,
            ( [ (.state.network // {}) | to_entries[] | select(.key != "lo")
                | .value.addresses[]? | select(.family == "inet" and .scope == "global")
                | .address ]
              | join(",") | if . == "" then "-" else . end ) ]
        | @tsv'
}

collect_incus() {
    command -v incus &>/dev/null || return 0
    command -v jq &>/dev/null || { warn "jq not found -- cannot list incus instances."; return 0; }

    local json type name status arch addr kind
    if ! json=$(_incus_json); then
        warn "Cannot reach the incus daemon -- Incus VMs are not listed (run ./setup.sh if you are not in incus-admin)."
        return 0
    fi

    while IFS=$'\t' read -r type name status arch addr; do
        case "$type" in
            virtual-machine) kind="incus-vm" ;;
            *)               kind="incus-container" ;;
        esac
        case "$arch" in
            x86_64)  kind+="-x64" ;;
            aarch64) kind+="-arm64" ;;
            *)       kind+="-${arch}" ;;
        esac
        add_row "$kind" "$name" "$(tr '[:upper:]' '[:lower:]' <<< "$status")" "$addr"
    done < <(_incus_otbr_rows <<< "$json")
}

# ---------------------------------------------------------------------------

main() {
    [[ "$EUID" -eq 0 ]] && die "Do not run as root. Run as your normal user -- sudo is only used when needed."

    local arg
    for arg in "$@"; do
        case "$arg" in
            -a|--all) SHOW_ALL=1 ;;
            -h|--help)
                echo "Usage: iotstack otbr list [-a|--all]"
                echo "  Lists OTBR instances on this host (snap, docker, incus vm/container)."
                echo "  -a, --all   Also list instances that are installed but not running"
                return 0
                ;;
            *) die "Unknown option: $arg (usage: iotstack otbr list [-a|--all])" ;;
        esac
    done

    collect_snap
    collect_docker
    collect_incus

    if [[ "${#ROWS[@]}" -eq 0 ]]; then
        if [[ "$SHOW_ALL" -eq 1 ]]; then
            log "No OTBR instances found on this host ($(hostname))."
        else
            log "No OTBR instances running on this host ($(hostname)). Use --all to include stopped ones."
        fi
        return 0
    fi

    {
        printf 'KIND\tNAME\tSTATE\tDETAILS\n'
        printf '%s\n' "${ROWS[@]}"
    } | column -t -s $'\t'
}

main "$@"
