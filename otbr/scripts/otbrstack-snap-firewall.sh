#!/usr/bin/env bash
# otbrstack-snap-firewall.sh
# Manages the UFW rules for the local OTBR snap's Thread interface.
# Run as normal user -- sudo is invoked only when needed for ufw commands.
#
# Usage: otbrstack-snap-firewall.sh [apply|list|add <name> <addr>...|remove <name> [addr...]]
#
# Policy: the Thread mesh (THREAD_IF) only talks to its named peers -- the other
# border routers, Home Assistant and the Matter server.
#   - routing THREAD_IF <-> INFRA_IF is allowed only to/from a peer address
#   - TREL (UDP) from a peer to this host on INFRA_IF is allowed
#   - mDNS multicast is allowed on INFRA_IF (no unicast 5353 from anywhere)
#   - everything else routed into THREAD_IF, and all traffic arriving on
#     THREAD_IF, is denied
#
# Peers are named groups in $THREAD_PEERS_FILE (one line per name: the name,
# then IPs, CIDRs or hostnames; hostnames are re-resolved on every apply). The
# name "home-assistant" also picks up the host from the pass ha_url
# ($THREAD_HA_HOST, exported by otbr.sh). The mesh is IPv6, so peers need IPv6
# addresses (or an IPv6 prefix) to be reachable from Thread devices.
#
# UFW has no named address sets, so every peer address becomes a few ufw rules
# tagged "iotstack otbr: <name> ..." in the ufw comment. Each apply deletes the
# tagged rules (and the untagged broad rules older versions added) and rebuilds
# them, so removed peers and changed interfaces do not linger.

set -euo pipefail

OTBR_HOME="${OTBR_HOME:-${HOME}/.iotstack/otbr}"
THREAD_PEERS_FILE="${THREAD_PEERS_FILE:-${OTBR_HOME}/thread-peers.conf}"
INFRA_IF="${INFRA_IF:-$(ip route show default | awk '/default/ {print $5; exit}')}"
THREAD_IF="${THREAD_IF:-wpan0}"
UFW_TAG="iotstack otbr"
HA_PEER_NAME="home-assistant"

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Peers file
# ---------------------------------------------------------------------------

# Peer group name: lowercase letters, digits, '-' and '_'.
_valid_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Invalid peer name '$1' (use lowercase letters, digits, - and _)."
}

_ensure_peers_file() {
    [[ -f "$THREAD_PEERS_FILE" ]] && return 0
    mkdir -p "$(dirname "$THREAD_PEERS_FILE")"
    cat > "$THREAD_PEERS_FILE" << 'EOF'
# iotstack otbr: hosts allowed to talk to the Thread mesh (UFW rules).
# One line per named group: <name> <address-or-hostname> [<address-or-hostname> ...]
# Addresses are IPs, CIDRs or hostnames (resolved on every apply). Use IPv6
# addresses or prefixes -- the mesh is IPv6. Full-line comments only.
# Manage with: iotstack otbr snap firewall [apply|list|add|remove]
#
# home-assistant  homeassistant.local 2001:db8:1::/64
# matter-server   192.168.4.40 fd00:4::40
# otbr            otbr-raspi4.local
EOF
}

# Rewrites the peers file through an awk program (with -v name/toks set).
_rewrite_peers_file() {
    local prog="$1" name="$2" toks="$3" tmp
    _ensure_peers_file
    tmp=$(mktemp)
    awk -v name="$name" -v toks="$toks" "$prog" "$THREAD_PEERS_FILE" > "$tmp"
    cat "$tmp" > "$THREAD_PEERS_FILE"
    rm -f "$tmp"
}

# Fills PEER_NAMES (ordered) and PEER_TOKENS[name] (space-separated addresses
# and hostnames) from the peers file plus the pass ha_url.
declare -a PEER_NAMES=()
declare -A PEER_TOKENS=()
_add_peer_tokens() {
    local name="$1"
    shift
    if [[ -z "${PEER_TOKENS[$name]+x}" ]]; then
        PEER_NAMES+=("$name")
        PEER_TOKENS[$name]=""
    fi
    [[ $# -gt 0 ]] && PEER_TOKENS[$name]+="${PEER_TOKENS[$name]:+ }$*"
    return 0
}

# Bare host from a "host[:port]" or URL-ish string (the pass ha_url).
_host_of() {
    local h="$1"
    h="${h#*://}"
    h="${h%%/*}"
    if [[ "$h" == \[*\]* ]]; then
        h="${h#\[}"
        h="${h%%\]*}"
    elif [[ "$h" != *:*:* ]]; then
        h="${h%%:*}"
    fi
    echo "$h"
}

_load_peers() {
    PEER_NAMES=()
    PEER_TOKENS=()
    local name rest
    local -a words
    if [[ -f "$THREAD_PEERS_FILE" ]]; then
        while read -r name rest; do
            [[ -z "$name" || "$name" == \#* ]] && continue
            _valid_name "$name"
            read -ra words <<< "$rest"
            _add_peer_tokens "$name" "${words[@]}"
        done < "$THREAD_PEERS_FILE"
    fi
    if [[ -n "${THREAD_HA_HOST:-}" ]]; then
        _add_peer_tokens "$HA_PEER_NAME" "$(_host_of "$THREAD_HA_HOST")"
    fi
}

# Prints one address or CIDR per line for a peer token: IP literals and CIDRs
# pass through, hostnames are resolved (A and AAAA; link-local is skipped).
_token_addrs() {
    local tok="$1"
    if [[ "$tok" == *:* || "$tok" =~ ^[0-9.]+(/[0-9]+)?$ ]]; then
        echo "$tok"
        return 0
    fi
    getent ahosts "$tok" | awk '{ sub(/^::ffff:/, "", $1); if ($1 !~ /^fe80:/) print $1 }' | sort -u
}

# ---------------------------------------------------------------------------
# UFW
# ---------------------------------------------------------------------------

# Runs 'ufw <args>' under sudo; dies with ufw's own message on failure.
_ufw() {
    local out
    out=$(sudo ufw "$@" 2>&1) || die "ufw $* failed: $out"
}

# Deletes every rule an earlier run added (tagged with a ufw comment) plus the
# untagged broad rules older versions added.
_ufw_purge_otbr_rules() {
    local line
    local -a args
    while IFS= read -r line; do
        line=$(sed -E "s/ comment '[^']*'//" <<< "$line")
        read -ra args <<< "$line"
        if [[ "${args[1]:-}" == "route" ]]; then
            sudo ufw route delete "${args[@]:2}" &>/dev/null || warn "Could not delete old rule: $line"
        else
            sudo ufw delete "${args[@]:1}" &>/dev/null || warn "Could not delete old rule: $line"
        fi
    done < <(sudo ufw show added | grep -F "comment '${UFW_TAG}" || true)

    # Untagged rules from earlier versions (ufw ignores deleting a missing rule).
    sudo ufw route delete allow in on "$THREAD_IF" &>/dev/null || true
    sudo ufw route delete allow out on "$THREAD_IF" &>/dev/null || true
    sudo ufw delete allow in on "$THREAD_IF" &>/dev/null || true
    sudo ufw delete allow 5353/udp &>/dev/null || true
}

# ICMPv6 (NDP, MLD, ping) is accepted on INFRA_IF only, via a marked block in
# before6.rules that is rewritten on every run. It also replaces the blanket
# ICMPv6 accept older versions injected (input and forward, all interfaces).
# Returns 0 if the file changed (caller reloads ufw), 1 if it was up to date.
_ufw_sync_icmpv6() {
    local before6=/etc/ufw/before6.rules tmp
    tmp=$(mktemp)
    sudo cat "$before6" | awk -v infra="$INFRA_IF" '
        /^# OTBR ICMPv6/ { skip = 1; next }
        skip && /^-A ufw6-before-(input|forward) .*-p icmpv6/ { next }
        { skip = 0 }
        /^\*/ { table = $0 }
        /^COMMIT$/ && table == "*filter" && !done {
            print "# OTBR ICMPv6 (iotstack otbr: infra interface only)"
            print "-A ufw6-before-input -i " infra " -p icmpv6 -j ACCEPT"
            done = 1
        }
        { print }
    ' > "$tmp"

    if ! grep -q '^COMMIT$' "$tmp" || ! grep -q '^# OTBR ICMPv6' "$tmp"; then
        rm -f "$tmp"
        die "Refusing to rewrite $before6: no *filter COMMIT found."
    fi
    if sudo cmp -s "$tmp" "$before6"; then
        rm -f "$tmp"
        return 1
    fi
    sudo cp "$tmp" "$before6"
    rm -f "$tmp"
    return 0
}

cmd_apply() {
    command -v ufw &>/dev/null || { log "ufw not found -- skipping firewall configuration."; return 0; }
    [[ -n "$INFRA_IF" ]] || die "No default-route interface found for the firewall rules -- set INFRA_IF."

    log "Configuring UFW rules for OTBR (infra: $INFRA_IF, thread: $THREAD_IF)..."
    _load_peers

    # Resolve each named group to addresses.
    local name tok resolved addr key
    local -a toks
    local -a rules=()    # "<name> <addr>" pairs, deduplicated
    declare -A seen=()
    for name in "${PEER_NAMES[@]}"; do
        read -ra toks <<< "${PEER_TOKENS[$name]}"
        for tok in "${toks[@]}"; do
            resolved=$(_token_addrs "$tok" || true)
            if [[ -z "$resolved" ]]; then
                warn "Could not resolve '$tok' (peer '$name') -- no firewall rules for it."
                continue
            fi
            while IFS= read -r addr; do
                key="$name $addr"
                [[ -z "${seen[$key]+x}" ]] || continue
                seen[$key]=1
                rules+=("$key")
            done <<< "$resolved"
        done
    done

    if [[ "${#rules[@]}" -eq 0 ]]; then
        warn "No Thread peers known (no ha_url in pass, $THREAD_PEERS_FILE empty): the mesh will be"
        warn "unreachable. Add peers with: iotstack otbr snap firewall add <name> <address>..."
    elif [[ "${rules[*]}" != *:* ]]; then
        warn "No IPv6 address among the Thread peers: the mesh is IPv6, so add the peers' IPv6"
        warn "addresses or prefix (iotstack otbr snap firewall add <name> <address>...)."
    fi

    _ufw_purge_otbr_rules

    local rule
    for rule in "${rules[@]}"; do
        read -r name addr <<< "$rule"
        log "Allowing Thread mesh traffic to/from $name ($addr)..."
        _ufw route allow in on "$THREAD_IF" out on "$INFRA_IF" to "$addr" comment "${UFW_TAG}: $name mesh to $addr"
        _ufw route allow in on "$INFRA_IF" out on "$THREAD_IF" from "$addr" comment "${UFW_TAG}: $name $addr to mesh"
        _ufw allow in on "$INFRA_IF" proto udp from "$addr" comment "${UFW_TAG}: $name TREL from $addr"
    done

    # Multicast mDNS on the infra interface only (Thread service discovery).
    _ufw allow in on "$INFRA_IF" proto udp to 224.0.0.251 port 5353 comment "${UFW_TAG}: mDNS multicast"
    _ufw allow in on "$INFRA_IF" proto udp to ff02::fb port 5353 comment "${UFW_TAG}: mDNS multicast"

    # Deny the rest. The route deny goes after the peer allows (rules match in
    # order; the purge above re-adds them together on every run). The input
    # deny is inserted first so no broader allow (e.g. SSH) covers THREAD_IF.
    _ufw route deny out on "$THREAD_IF" comment "${UFW_TAG}: deny other traffic into mesh"
    _ufw insert 1 deny in on "$THREAD_IF" comment "${UFW_TAG}: deny traffic arriving from mesh"

    if _ufw_sync_icmpv6; then
        log "Reloading UFW to apply the ICMPv6 rules..."
        _ufw reload
    else
        log "ICMPv6 rules already up to date in /etc/ufw/before6.rules."
    fi

    local status
    status=$(sudo ufw status verbose 2>&1 || true)
    if grep -q '^Status: inactive' <<< "$status"; then
        warn "ufw is inactive -- the rules are stored but not enforced. Enable with: sudo ufw enable"
    elif grep -qE 'allow \((incoming|routed)\)' <<< "$status"; then
        warn "ufw default policy allows incoming/routed traffic -- the mesh deny rules still apply,"
        warn "but everything else is open. Check: sudo ufw status verbose"
    fi

    log "UFW configuration done."
}

# ---------------------------------------------------------------------------
# Peer management
# ---------------------------------------------------------------------------

cmd_list() {
    _load_peers
    echo "Thread peers ($THREAD_PEERS_FILE${THREAD_HA_HOST:+ + pass ha_url}):"
    if [[ "${#PEER_NAMES[@]}" -eq 0 ]]; then
        echo "  (none)"
    fi
    local name tok resolved
    local -a toks
    for name in "${PEER_NAMES[@]}"; do
        echo "  $name"
        read -ra toks <<< "${PEER_TOKENS[$name]}"
        for tok in "${toks[@]}"; do
            resolved=$(_token_addrs "$tok" 2>/dev/null | tr '\n' ' ' || true)
            if [[ "$resolved" == "$tok " ]]; then
                echo "    $tok"
            else
                echo "    $tok -> ${resolved:-(does not resolve)}"
            fi
        done
    done
    if command -v ufw &>/dev/null; then
        echo
        echo "Active OTBR ufw rules:"
        sudo ufw show added | grep -F "comment '${UFW_TAG}" | sed 's/^/  /' || echo "  (none)"
    fi
}

cmd_add() {
    [[ $# -ge 2 ]] || die "Usage: add <name> <address-or-hostname>..."
    local name="$1"
    shift
    _valid_name "$name"
    # shellcheck disable=SC2016  # awk program, not shell
    _rewrite_peers_file '
        BEGIN { n = split(toks, t, " ") }
        /^[[:space:]]*#/ || NF == 0 { print; next }
        $1 == name && !found {
            found = 1; line = $0
            for (i = 1; i <= n; i++) {
                has = 0
                for (j = 2; j <= NF; j++) if ($j == t[i]) has = 1
                if (!has) line = line " " t[i]
            }
            print line; next
        }
        { print }
        END {
            if (!found) {
                line = name
                for (i = 1; i <= n; i++) line = line " " t[i]
                print line
            }
        }' "$name" "$*"
    log "Added to peer '$name': $*"
    cmd_apply
}

cmd_remove() {
    [[ $# -ge 1 ]] || die "Usage: remove <name> [address-or-hostname...]"
    local name="$1"
    shift
    _valid_name "$name"
    [[ -f "$THREAD_PEERS_FILE" ]] || die "No peers file at $THREAD_PEERS_FILE."
    if ! awk -v name="$name" '$1 == name { f = 1 } END { exit !f }' "$THREAD_PEERS_FILE"; then
        die "No peer '$name' in $THREAD_PEERS_FILE."
    fi
    # shellcheck disable=SC2016  # awk program, not shell
    _rewrite_peers_file '
        BEGIN { n = split(toks, t, " ") }
        /^[[:space:]]*#/ || NF == 0 { print; next }
        $1 == name {
            if (n == 0) next
            line = name; kept = 0
            for (j = 2; j <= NF; j++) {
                drop = 0
                for (i = 1; i <= n; i++) if ($j == t[i]) drop = 1
                if (!drop) { line = line " " $j; kept++ }
            }
            if (kept > 0) print line
            next
        }
        { print }' "$name" "$*"
    if [[ $# -eq 0 ]]; then
        log "Removed peer '$name'."
    else
        log "Removed from peer '$name': $*"
    fi
    if [[ "$name" == "$HA_PEER_NAME" && -n "${THREAD_HA_HOST:-}" ]]; then
        warn "'$HA_PEER_NAME' also comes from the pass ha_url ($(_host_of "$THREAD_HA_HOST")) and stays allowed."
    fi
    cmd_apply
}

usage() {
    cat << EOF
Usage: iotstack otbr snap firewall [apply|list|add <name> <addr>...|remove <name> [addr...]]

  apply                       Rebuild the ufw rules from the peers (default)
  list                        Show peers, resolved addresses and the active rules
  add <name> <addr>...        Add IPs, CIDRs or hostnames to a named peer, then apply
  remove <name> [addr...]     Remove addresses from a peer (or the whole peer), then apply

Peers live in $THREAD_PEERS_FILE
EOF
}

main() {
    [[ "$EUID" -eq 0 ]] && die "Do not run as root. Run as your normal user -- sudo will be invoked as needed."
    local cmd="${1:-apply}"
    [[ $# -gt 0 ]] && shift
    case "$cmd" in
        apply)  cmd_apply ;;
        list)   cmd_list ;;
        add)    cmd_add "$@" ;;
        remove) cmd_remove "$@" ;;
        -h|--help|help) usage ;;
        *) usage >&2; die "Unknown firewall command: $cmd" ;;
    esac
}

main "$@"
