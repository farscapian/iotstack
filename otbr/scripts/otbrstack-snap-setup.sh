#!/usr/bin/env bash
# otbr-setup.sh
# Detects ESP32 RCP device, verifies spinel firmware, configures and restarts OTBR snap.
# Run as normal user -- sudo is invoked only when needed for snap commands.

set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OTBR_HOME="${OTBR_HOME:-${HOME}/.iotstack/otbr}"
BAUD=460800
IDF_PATH="${IDF_PATH:-}"
INFRA_IF="${INFRA_IF:-$(ip route show default | awk '/default/ {print $5; exit}')}"
THREAD_IF="${THREAD_IF:-wpan0}"
PYSPINEL_VENV="${PYSPINEL_VENV:-${OTBR_HOME}/artifacts/pyspinel-venv}"
ESPRESSIF_VENDOR_ID="303a"
SONOFF_VENDOR_ID="10c4"
SONOFF_PRODUCT_ID="ea60"
# Env is loaded by otbr before invoking this script.
[[ -n "${THREAD_DATASET_TLV:-}" ]] || { echo "[ERROR] THREAD_DATASET_TLV not set -- run via 'otbr snap'" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2. Helpers
# ---------------------------------------------------------------------------
log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

require() {
    command -v "$1" &>/dev/null || die "Required command not found: $1"
}


# ---------------------------------------------------------------------------
# 4a. Suppress ModemManager for ESP32-C6 (vendor 303a)
# ModemManager probes unknown USB-serial devices and can claim /dev/ttyACM0
# before the OTBR snap or our Spinel probe opens it.
# ---------------------------------------------------------------------------
suppress_modemmanager() {
    local rule=/etc/udev/rules.d/99-esp32-no-modemmanager.rules
    if [[ ! -f "$rule" ]]; then
        log "Writing udev rule to prevent ModemManager from claiming ESP32-C6..."
        sudo tee "$rule" > /dev/null << 'EOF'
SUBSYSTEM=="usb", ATTRS{idVendor}=="303a", ENV{ID_MM_DEVICE_IGNORE}="1"
SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", ENV{ID_MM_DEVICE_IGNORE}="1"
EOF
        sudo udevadm control --reload-rules
        sudo udevadm trigger --subsystem-match=usb
    fi
    if systemctl is-active --quiet ModemManager 2>/dev/null; then
        log "Stopping ModemManager so it releases /dev/ttyACM0..."
        sudo systemctl stop ModemManager || true
    fi
}

# ---------------------------------------------------------------------------
# 4. Find Thread radio device (ESP32-C6 preferred, Sonoff fallback)
# ---------------------------------------------------------------------------

# Usage: _find_usb_tty <vendor_id> [product_id]
# Searches all tty devices (ttyACM* and ttyUSB*) for a matching USB vendor/product.
_find_usb_tty() {
    local wanted_vendor="$1"
    local wanted_product="${2:-}"

    for dev in /dev/ttyACM* /dev/ttyUSB*; do
        [[ -e "$dev" ]] || continue
        local devname
        devname=$(basename "$dev")

        local check_path
        check_path=$(readlink -f /sys/class/tty/"$devname"/device 2>/dev/null || true)
        while [[ -n "$check_path" && "$check_path" != "/" ]]; do
            if [[ -f "$check_path/idVendor" ]]; then
                local vendor product
                vendor=$(cat "$check_path/idVendor")
                product=$(cat "$check_path/idProduct" 2>/dev/null || true)
                if [[ "$vendor" == "$wanted_vendor" ]]; then
                    if [[ -z "$wanted_product" || "$product" == "$wanted_product" ]]; then
                        echo "$dev"
                        return 0
                    fi
                fi
                break
            fi
            check_path=$(dirname "$check_path")
        done
    done
}

find_thread_device() {
    # NOTE: This function must be called directly (not in a subshell) so that
    # THREAD_DEVICE_TYPE and THREAD_DEVICE_PORT globals are set in the parent shell.
    local port

    # Prefer ESP32-C6
    port=$(_find_usb_tty "$ESPRESSIF_VENDOR_ID")
    if [[ -n "$port" ]]; then
        THREAD_DEVICE_TYPE="esp32c6"
        THREAD_DEVICE_PORT="$port"
        return 0
    fi

    # Fall back to Sonoff dongle
    port=$(_find_usb_tty "$SONOFF_VENDOR_ID" "$SONOFF_PRODUCT_ID")
    if [[ -n "$port" ]]; then
        THREAD_DEVICE_TYPE="sonoff"
        THREAD_DEVICE_PORT="$port"
        return 0
    fi

    THREAD_DEVICE_TYPE=""
    THREAD_DEVICE_PORT=""
    return 1
}

# ---------------------------------------------------------------------------
# 5. Check serial port group membership
# ---------------------------------------------------------------------------
check_serial_group() {
    # Determine the owning group of ttyACM devices (typically 'dialout' on Ubuntu)
    local group="dialout"
    local dev
    for dev in /dev/ttyACM*; do
        [[ -e "$dev" ]] || continue
        group=$(stat -c "%G" "$dev")
        break
    done

    if ! getent group "$group" &>/dev/null; then
        warn "Group '$group' not found on this system -- skipping group check."
        return
    fi

    # Group membership is managed only by setup.sh -- check, never change.
    if ! id -nG "$USER" | grep -qw "$group"; then
        die "$USER is not in the '$group' group (needed for serial port access). Run ./setup.sh to add it, then log out and back in."
    fi

    # Permanent membership exists -- check if active session reflects it
    if ! groups | grep -qw "$group"; then
        echo ""
        echo "  +========================================================+"
        echo "  |  You are in the '$group' group but your current      "
        echo "  |  session does not reflect it yet.                    "
        echo "  |  Please log out and log back in, then re-run.        "
        echo "  +========================================================+"
        echo ""
        exit 0
    fi

    log "Group membership OK: $USER is in '$group'."
}


# ---------------------------------------------------------------------------
# 6. Ensure required kernel modules are loaded
# ---------------------------------------------------------------------------
ensure_kernel_modules() {
    local modules=(ip_set ip_set_hash_net ip_set_hash_ip ip_set_bitmap_port)
    local loaded=0

    for mod in "${modules[@]}"; do
        if ! lsmod | grep -q "^${mod}"; then
            # Try loading; if modprobe reports the module is not found, the
            # module files are missing -- install linux-modules-extra and retry.
            if ! sudo modprobe "$mod" 2>/dev/null; then
                if ! modinfo "$mod" &>/dev/null; then
                    local extras
                    extras="linux-modules-extra-$(uname -r)"
                    log "Module $mod not found -- installing $extras..."
                    if [[ -n "${HTTP_PROXY:-}" ]]; then
                        echo "Acquire::http::Proxy \"${HTTP_PROXY}\";" \
                            | sudo tee /etc/apt/apt.conf.d/90apt-cache >/dev/null
                    fi
                    sudo apt-get install -y "$extras" \
                        || die "Failed to install $extras. Check your apt sources."
                fi
                sudo modprobe "$mod" \
                    || die "Failed to load kernel module $mod even after installing extras."
            fi
            log "Loaded kernel module: $mod"
            loaded=1
        fi
    done

    # Persist across reboots
    local conf=/etc/modules-load.d/otbr.conf
    if [[ ! -f "$conf" ]]; then
        log "Persisting kernel modules to $conf..."
        printf '%s\n' "${modules[@]}" | sudo tee "$conf" > /dev/null
    fi

    [[ "$loaded" -eq 1 ]] && sleep 1
}

# ---------------------------------------------------------------------------
# 7. Stop OTBR snap if running (to free the serial port)
# ---------------------------------------------------------------------------

# OTBR_SNAP_STOPPED -- set by ensure_otbr_stopped:
#   false  : snap was not running (or not installed)
#   true   : snap was running and has been stopped
OTBR_SNAP_STOPPED=false

ensure_otbr_stopped() {
    if ! snap list openthread-border-router &>/dev/null; then
        log "OTBR snap not installed."
        return 0
    fi

    local running
    running=$(sudo snap services openthread-border-router \
        | awk 'NR>1 && $3=="active" {print $1}' | head -1)

    if [[ -z "$running" ]]; then
        log "OTBR snap is installed but not running."
        return 0
    fi

    log "Stopping OTBR snap to free the serial port for RCP verification..."
    sudo snap stop openthread-border-router
    sleep 2
    OTBR_SNAP_STOPPED=true
}

# reload_rcp_device <tty_dev>
# After the snap releases the port, the RCP's USB-serial state may be stale.
# Toggle the USB device's sysfs 'authorized' flag to force a clean re-enumeration,
# then wait for the device node to come back before returning.
reload_rcp_device() {
    local tty_dev="$1"
    local devname
    devname=$(basename "$tty_dev")

    # Walk sysfs from the tty device up to the USB device node (has idVendor).
    local check_path usb_dev=""
    check_path=$(readlink -f /sys/class/tty/"$devname"/device 2>/dev/null || true)
    while [[ -n "$check_path" && "$check_path" != "/" ]]; do
        if [[ -f "$check_path/idVendor" ]]; then
            usb_dev="$check_path"
            break
        fi
        check_path=$(dirname "$check_path")
    done

    if [[ -z "$usb_dev" || ! -f "${usb_dev}/authorized" ]]; then
        warn "Cannot locate USB device in sysfs for $tty_dev -- waiting 3s for port to settle."
        sleep 3
        return 0
    fi

    log "Resetting USB device $(basename "$usb_dev") to flush stale serial state..."
    echo 0 | sudo tee "${usb_dev}/authorized" > /dev/null
    sleep 1
    echo 1 | sudo tee "${usb_dev}/authorized" > /dev/null

    log "Waiting for $tty_dev to re-enumerate (up to 10s)..."
    local i=0
    while [[ $i -lt 10 ]]; do
        [[ -e "$tty_dev" ]] && { log "Device $tty_dev is back."; return 0; }
        sleep 1
        (( i++ ))
    done
    warn "$tty_dev did not reappear -- it may have re-enumerated under a different node."
}


# ---------------------------------------------------------------------------
# 7. Pyspinel venv -- created on first run, reused thereafter.
# ---------------------------------------------------------------------------
ensure_pyspinel_venv() {
    if "${PYSPINEL_VENV}/bin/python3" -c "import serial" 2>/dev/null; then
        return 0
    fi
    log "Setting up pyspinel venv at ${PYSPINEL_VENV} ..."
    rm -rf "$PYSPINEL_VENV"
    mkdir -p "$(dirname "$PYSPINEL_VENV")"
    python3 -m venv "$PYSPINEL_VENV"
    "$PYSPINEL_VENV/bin/pip" install --quiet pyspinel
}

# ---------------------------------------------------------------------------
# 7b. Verify RCP firmware via Spinel PROP_VALUE_GET(NCP_VERSION).
#     Delegates to scripts/verify_rcp.py -- the single canonical probe.
# ---------------------------------------------------------------------------
verify_rcp() {
    local port="$1"
    ensure_pyspinel_venv
    log "Verifying RCP firmware on $port via spinel..."
    if "${PYSPINEL_VENV}/bin/python3" "${SCRIPT_DIR}/verify_rcp.py" "$port"; then
        log "RCP firmware verified."
        return 0
    else
        warn "No spinel response from $port."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 8a. Stable serial path for the snap radio URL
# /dev/ttyACM* numbering is not stable across unplug/replug; the udev-provided
# /dev/serial/by-id/ symlink follows the device. Echoes the by-id path that
# resolves to <tty_dev>, or <tty_dev> itself (with a warning) if there is none.
# ---------------------------------------------------------------------------
stable_port_path() {
    local tty_dev="$1"
    local real link
    real=$(readlink -f "$tty_dev")
    for link in /dev/serial/by-id/*; do
        [[ -L "$link" ]] || continue
        if [[ "$(readlink -f "$link")" == "$real" ]]; then
            echo "$link"
            return 0
        fi
    done
    warn "No /dev/serial/by-id link for $tty_dev -- using it directly; replugging may renumber it."
    echo "$tty_dev"
}

# ---------------------------------------------------------------------------
# 8b. Keep retrying otbr-agent while the radio is unplugged
# With the RCP pulled, otbr-agent exits on open() of the serial port; systemd
# hits its start limit ("Start request repeated too quickly") and leaves the
# unit failed, so replugging the radio never brings OTBR back. Disable the
# start limit and retry slowly instead (same drop-in the Pi image ships).
# Returns 0 if the drop-in was written/changed, 1 if already current.
# ---------------------------------------------------------------------------
ensure_agent_retry_dropin() {
    local dir=/etc/systemd/system/snap.openthread-border-router.otbr-agent.service.d
    local file="${dir}/20-retry-forever.conf"
    local want
    want=$'[Unit]\nStartLimitIntervalSec=0\nStartLimitAction=none\n\n[Service]\nRestartSec=5\n'

    if [[ -f "$file" && "$(cat "$file")" == "${want%$'\n'}" ]]; then
        return 1
    fi

    log "Installing systemd drop-in so otbr-agent retries until the radio returns..."
    sudo mkdir -p "$dir"
    printf '%s' "$want" | sudo tee "$file" > /dev/null
    sudo systemctl daemon-reload
    sudo systemctl reset-failed snap.openthread-border-router.otbr-agent.service 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# 9. Configure and restart OTBR snap
# ---------------------------------------------------------------------------
configure_otbr() {
    local port
    port=$(stable_port_path "$1")
    local radio_url="spinel+hdlc+uart://${port}?uart-baudrate=${BAUD}"
    local changed=0

    log "Configuring OTBR snap..."

    # Install snap if not present
    if ! snap list openthread-border-router &>/dev/null; then
        log "openthread-border-router snap not installed -- installing..."
        sudo snap install openthread-border-router --channel=latest/edge --devmode
        changed=1
    fi

    # Both radio-url (used by agent startup script) and otbr-radio-url must be set
    local current_url
    current_url=$(sudo snap get openthread-border-router radio-url 2>/dev/null || true)
    if [[ "$current_url" != "$radio_url" ]]; then
        log "Setting radio-url to: $radio_url"
        sudo snap set openthread-border-router radio-url="$radio_url"
        changed=1
    else
        log "radio-url already correct: $radio_url"
    fi

    local current_otbr_url
    current_otbr_url=$(sudo snap get openthread-border-router otbr-radio-url 2>/dev/null || true)
    if [[ "$current_otbr_url" != "$radio_url" ]]; then
        log "Setting otbr-radio-url to: $radio_url"
        sudo snap set openthread-border-router otbr-radio-url="$radio_url"
        changed=1
    else
        log "otbr-radio-url already correct: $radio_url"
    fi

    local current_infra
    current_infra=$(sudo snap get openthread-border-router infra-if 2>/dev/null || true)
    if [[ "$current_infra" != "$INFRA_IF" ]]; then
        log "Setting infra-if to: $INFRA_IF"
        sudo snap set openthread-border-router infra-if="$INFRA_IF"
        changed=1
    fi

    local current_thread
    current_thread=$(sudo snap get openthread-border-router thread-if 2>/dev/null || true)
    if [[ "$current_thread" != "$THREAD_IF" ]]; then
        log "Setting thread-if to: $THREAD_IF"
        sudo snap set openthread-border-router thread-if="$THREAD_IF"
        changed=1
    fi

    # Ensure autostart is enabled
    local current_autostart
    current_autostart=$(sudo snap get openthread-border-router autostart 2>/dev/null || true)
    if [[ "$current_autostart" != "true" ]]; then
        log "Enabling autostart..."
        sudo snap set openthread-border-router autostart=true
        changed=1
    fi

    ensure_agent_retry_dropin && changed=1

    if [[ "$changed" -eq 1 ]]; then
        log "Configuration changed -- restarting OTBR snap..."
        sudo snap restart openthread-border-router
        sleep 2
        sudo snap services openthread-border-router
    else
        # Even if config unchanged, ensure services are actually running
        local inactive
        inactive=$(sudo snap services openthread-border-router | awk 'NR>1 && $3=="inactive" {print $1}')
        if [[ -n "$inactive" ]]; then
            log "Starting inactive services..."
            sudo snap start openthread-border-router
            sleep 2
            sudo snap services openthread-border-router
        else
            log "No configuration changes needed -- services already running."
        fi
    fi
}



# ---------------------------------------------------------------------------
# 9. Ensure required snap interface connections
# ---------------------------------------------------------------------------
ensure_snap_connections() {
    log "Checking snap interface connections..."

    local interfaces=(
        "firewall-control::firewall-control"
        "network-control::network-control"
        "raw-usb::raw-usb"
    )

    local reconnected=0
    for entry in "${interfaces[@]}"; do
        local plug slot
        plug="${entry%%:*}"
        slot="${entry##*:}"
        local declared connected
        declared=$(snap connections openthread-border-router | awk -v plug="openthread-border-router:$plug" '$2==plug {print "y"; exit}')
        if [[ -z "$declared" ]]; then
            log "Snap declares no plug named $plug -- skipping."
            continue
        fi
        connected=$(snap connections openthread-border-router | awk -v plug="openthread-border-router:$plug" '$2==plug {print $3}')
        if [[ -z "$connected" || "$connected" == "-" ]]; then
            log "Connecting interface: $plug -> :$slot"
            sudo snap connect "openthread-border-router:$plug" ":$slot"
            reconnected=1
        else
            log "Interface already connected: $plug"
        fi
    done

    if [[ "$reconnected" -eq 1 ]]; then
        log "Interfaces changed -- restarting snap..."
        sudo snap restart openthread-border-router
        sleep 2
    fi
}

# ---------------------------------------------------------------------------
# 10. Configure UFW rules for OTBR
# ---------------------------------------------------------------------------
configure_ufw() {
    if ! command -v ufw &>/dev/null; then
        log "ufw not found -- skipping firewall configuration."
        return 0
    fi

    log "Configuring UFW rules for OTBR..."

    # IPv6 forwarding: Thread (wpan0) <-> upstream interface
    # UFW persists route rules in its own config -- no extra step needed.
    if ! sudo ufw status verbose | grep -q "Anywhere on wpan0"; then
        log "Adding UFW route rules for wpan0..."
        sudo ufw route allow in on wpan0
        sudo ufw route allow out on wpan0
    else
        log "UFW route rules for wpan0 already present."
    fi

    # ICMPv6: required for NDP / router advertisements.
    # Injected into /etc/ufw/before6.rules (UFW re-applies on reload/boot),
    # avoiding any dependency on iptables-persistent.
    local before6=/etc/ufw/before6.rules
    local ufw_changed=0
    if ! sudo grep -q "# OTBR ICMPv6" "$before6" 2>/dev/null; then
        log "Injecting ICMPv6 rules into $before6..."
        sudo sed -i '/^COMMIT$/i # OTBR ICMPv6\n-A ufw6-before-forward -p icmpv6 -j ACCEPT\n-A ufw6-before-input  -p icmpv6 -j ACCEPT' "$before6"
        ufw_changed=1
    else
        log "ICMPv6 rules already present in $before6."
    fi

    if [[ "$ufw_changed" -eq 1 ]]; then
        log "Reloading UFW to apply ICMPv6 rules..."
        sudo ufw reload
    fi

    # mDNS: needed for Thread SRP / service discovery
    # UFW persists allow rules in its own config -- no extra step needed.
    if ! sudo ufw status | grep -q "5353/udp"; then
        log "Allowing mDNS (UDP 5353)..."
        sudo ufw allow 5353/udp
    else
        log "mDNS rule already present."
    fi

    log "UFW configuration done."
}

# ---------------------------------------------------------------------------
# 11. Ensure avahi advertises this host as $(hostname).local
# avahi takes its mDNS name from the system hostname unless host-name= is set
# in avahi-daemon.conf, and appends -2, -3, ... when it sees a name conflict.
# ---------------------------------------------------------------------------
_avahi_dbus() {
    busctl --system call org.freedesktop.Avahi / org.freedesktop.Avahi.Server "$1" 2>/dev/null \
        | awk -F'"' '/^s / {print $2} /^i / {print $2}'
}

ensure_mdns_hostname() {
    local conf=/etc/avahi/avahi-daemon.conf
    local want
    want="$(hostname)"
    want="${want%%.*}.local"

    if ! systemctl cat avahi-daemon.service &>/dev/null; then
        log "avahi-daemon not installed -- installing..."
        sudo apt-get install -y avahi-daemon \
            || die "Failed to install avahi-daemon."
    fi

    # An explicit host-name= overrides the system hostname -- drop it.
    if grep -qE '^[[:space:]]*host-name[[:space:]]*=' "$conf" 2>/dev/null; then
        log "Removing host-name override from $conf so avahi follows the hostname..."
        sudo sed -i -E 's/^([[:space:]]*host-name[[:space:]]*=)/#\1/' "$conf"
        sudo systemctl restart avahi-daemon
    elif ! systemctl is-active --quiet avahi-daemon; then
        log "Starting avahi-daemon..."
        sudo systemctl enable --now avahi-daemon
    fi

    local have="" i
    for (( i = 0; i < 10; i++ )); do
        have="$(_avahi_dbus GetHostNameFqdn || true)"
        [[ "${have,,}" == "${want,,}" ]] && { log "mDNS name OK: $have"; return 0; }
        (( i == 0 )) && [[ -n "$have" ]] && {
            log "avahi advertises '$have', expected '$want' -- restarting avahi-daemon..."
            sudo systemctl restart avahi-daemon
        }
        sleep 1
    done

    warn "avahi is advertising '${have:-<unknown>}', expected '$want'."
    warn "A '-2' style suffix means another device on the LAN already answers to '$want'."
    warn "Check: avahi-resolve-host-name -4 $want   /   journalctl -u avahi-daemon -n 30"
}

# ---------------------------------------------------------------------------
# 12. Join Thread network using Active Dataset from .env
# ---------------------------------------------------------------------------
join_thread_network() {
    local dataset="$1"
    local ot="sudo openthread-border-router.ot-ctl"

    log "Configuring Thread network dataset..."
    $ot dataset set active "$dataset"
    $ot dataset commit active

    log "Bringing Thread interface up..."
    $ot ifconfig up
    $ot thread start

    log "Waiting for Thread to attach (up to 30s)..."
    local i=0
    while [[ $i -lt 30 ]]; do
        local state
        state=$($ot state 2>/dev/null | head -1 || true)
        if [[ "$state" == "router" || "$state" == "child" || "$state" == "leader" ]]; then
            log "Thread attached -- state: $state"
            return 0
        fi
        sleep 1
        (( i++ ))
    done

    local final_state
    final_state=$($ot state 2>/dev/null | head -1 || true)
    warn "Thread did not attach within 30s -- current state: $final_state"
    warn "Check: sudo snap logs openthread-border-router.otbr-agent -f"
}

# ---------------------------------------------------------------------------
# 13. Install chip-tool snap (Matter commissioning -- BLE+Thread and Thread-only)
# ---------------------------------------------------------------------------
install_chiptool() {
    if snap list chip-tool &>/dev/null; then
        log "chip-tool snap already installed."
        return 0
    fi
    log "Installing chip-tool snap..."
    sudo snap install chip-tool
    log "chip-tool installed."
}

# ---------------------------------------------------------------------------
# 14. Main
# ---------------------------------------------------------------------------
main() {
    [[ "$EUID" -eq 0 ]] && die "Do not run as root. Run as your normal user -- sudo will be invoked as needed."
    require snap

    log "THREAD_DATASET_TLV loaded (${#THREAD_DATASET_TLV} hex chars)."
    check_serial_group
    ensure_kernel_modules
    suppress_modemmanager

    log "Searching for Thread radio device (ESP32-C6 preferred, Sonoff fallback)..."
    THREAD_DEVICE_TYPE=""
    THREAD_DEVICE_PORT=""
    find_thread_device || true

    if [[ -z "$THREAD_DEVICE_PORT" ]]; then
        die "No Thread radio device found. Connect an ESP32-C6 or Sonoff Thread dongle."
    fi

    log "Found $THREAD_DEVICE_TYPE device at: $THREAD_DEVICE_PORT"

    ensure_otbr_stopped

    if [[ "$THREAD_DEVICE_TYPE" == "esp32c6" ]]; then
        if [[ "$OTBR_SNAP_STOPPED" == "true" ]]; then
            reload_rcp_device "$THREAD_DEVICE_PORT"
            log "Re-detecting Thread device after USB reset..."
            find_thread_device || true
            [[ -n "$THREAD_DEVICE_PORT" ]] \
                || die "Thread device not found after USB reset."
            log "Found $THREAD_DEVICE_TYPE at: $THREAD_DEVICE_PORT"
        fi
        if ! verify_rcp "$THREAD_DEVICE_PORT"; then
            local ans
            read -rp "  Flash RCP firmware onto $THREAD_DEVICE_PORT now? [y/N] " ans
            if [[ "${ans,,}" == "y" ]]; then
                IDF_DIR="${OTBR_HOME}/cache/esp-idf" \
                RCP_BIN_CACHE="${OTBR_HOME}/cache/esp32/rcp/esp_ot_rcp.bin" \
                    "${SCRIPT_DIR}/flash_rcp.sh" --port "$THREAD_DEVICE_PORT" --force \
                    || die "Flashing failed."
                log "Re-detecting Thread device after flash..."
                find_thread_device || true
                [[ -n "$THREAD_DEVICE_PORT" ]] \
                    || die "Thread device not found after flashing."
                log "Found $THREAD_DEVICE_TYPE at: $THREAD_DEVICE_PORT"
                local _flash_ok=0
                for _attempt in 1 2 3; do
                    if verify_rcp "$THREAD_DEVICE_PORT"; then
                        _flash_ok=1; break
                    fi
                    warn "Spinel probe attempt $_attempt/3 failed -- retrying in 5s ..."
                    sleep 5
                done
                if [[ "$_flash_ok" -eq 0 ]]; then
                    warn "Still no spinel response after flashing."
                    warn "Try: unplug the ESP32-C6 USB cable, plug it back in, then re-run."
                    warn "If the problem persists, verify the USB JTAG interface is functional:"
                    warn "  idf.py -p $THREAD_DEVICE_PORT monitor"
                    die "Flashing failed -- RCP firmware not responding to Spinel."
                fi
            else
                die "No spinel response from $THREAD_DEVICE_PORT. Flash RCP firmware and re-run."
            fi
        fi
    else
        if ! verify_rcp "$THREAD_DEVICE_PORT"; then
            die "No Spinel response from $THREAD_DEVICE_TYPE on $THREAD_DEVICE_PORT." \
                "Flash Thread RCP firmware onto the dongle and re-run."
        fi
    fi
    configure_otbr "$THREAD_DEVICE_PORT"
    ensure_snap_connections
    configure_ufw
    ensure_mdns_hostname
    join_thread_network "$THREAD_DATASET_TLV"
    install_chiptool

    log "Done."
}

main "$@"