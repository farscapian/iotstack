#!/usr/bin/env bash
# setup.sh -- one-time OTBR developer environment setup
#
# - Installs apt packages needed by the provisioning scripts
# - Installs esptool via pip3 (used when flashing ESP32-C6 RCP firmware)
# - Creates ~/.otbrstack/env/ for env files (cache/, logs/, artifacts/ created on demand)
#
# Invoked via: iotstack otbr setup
# Safe to re-run: all steps are idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()    { echo -e "\n\033[1;34m[INFO]\033[0m $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m $*"; }

# ---------------------------------------------------------------------------
# 1. apt packages
# ---------------------------------------------------------------------------
# Covers every script in the repo:
#   flash-piotbr.sh      : curl sha256sum xzcat(xz-utils) dd lsblk partprobe(parted) python3
#   provision_incus.sh   : incus (not in apt -- skipped; see note below), curl python3 lsof
#                          envsubst(gettext-base)
#   otbr-docker-setup.sh : installs Docker CE itself; needs curl ca-certificates gnupg
#   otbr-snap-setup.sh   : python3 lsof (ufw optional; checked at runtime)

APT_PKGS=(
    # core utilities
    curl
    ca-certificates
    gnupg
    xz-utils
    python3
    python3-pip
    python3-venv
    lsof
    socat
    gettext-base   # envsubst

    # disk / flashing
    parted         # partprobe
    util-linux     # lsblk, dd
)

install_apt_packages() {
    info "1. Installing apt packages ..."

    local missing=()
    for pkg in "${APT_PKGS[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" \
            || missing+=("$pkg")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        success "All apt packages already installed."
        return
    fi

    echo "   Missing: ${missing[*]}"
    if [[ -n "${HTTP_PROXY:-}" ]]; then
        local _proxy_hostport="${HTTP_PROXY#*://}"
        _proxy_hostport="${_proxy_hostport%/}"
        if command -v wait-for-it &>/dev/null; then
            if ! wait-for-it --timeout=5 "$_proxy_hostport" -- true 2>/dev/null; then
                warn "HTTP proxy ${_proxy_hostport} is not reachable; apt may fail"
            fi
        fi
        echo "Acquire::http::Proxy \"${HTTP_PROXY}\";" \
            | sudo tee /etc/apt/apt.conf.d/90apt-cache >/dev/null
    fi
    sudo apt-get update -q
    sudo apt-get install -y "${missing[@]}"
    success "apt packages installed."
}

# ---------------------------------------------------------------------------
# 2. esptool (for ESP32-C6 RCP firmware flashing)
# ---------------------------------------------------------------------------

install_esptool() {
    info "2. Checking esptool ..."

    local esptool_venv="${HOME}/.otbrstack/artifacts/esptool-venv"

    if command -v esptool &>/dev/null || command -v esptool.py &>/dev/null; then
        success "esptool already available: $(esptool.py version 2>/dev/null || esptool version 2>/dev/null | head -1)"
        return
    fi

    if [[ -x "${esptool_venv}/bin/esptool.py" ]]; then
        success "esptool available in venv: $("${esptool_venv}/bin/esptool.py" version 2>/dev/null | head -1)"
        return
    fi

    info "Installing esptool into venv at ${esptool_venv} ..."
    python3 -m venv "${esptool_venv}"
    "${esptool_venv}/bin/pip" install --quiet esptool
    success "esptool installed into ${esptool_venv}."
}

# ---------------------------------------------------------------------------
# 3. Incus (VM/container path) -- install and initialize if absent
# ---------------------------------------------------------------------------

install_incus() {
    info "3. Checking incus ..."

    if ! command -v incus &>/dev/null; then
        info "incus not found -- installing via apt ..."
        sudo apt-get update -q
        sudo apt-get install -y incus
        success "incus installed: $(incus --version)"
    else
        success "incus available: $(incus --version)"
    fi

    # Add current user to the incus-admin group if not already a member.
    if ! groups | grep -qw incus-admin; then
        info "Adding ${USER} to the incus-admin group ..."
        sudo usermod -aG incus-admin "$USER"
        warn "Group membership change takes effect in a new login session."
        warn "For this session, commands will run via 'sudo -g incus-admin incus ...' if needed."
    fi

    # Initialize incus if it has not been configured yet.
    if ! incus info &>/dev/null 2>&1; then
        info "Initializing incus with auto preset ..."
        sudo incus admin init --auto
        success "incus initialized."
    else
        success "incus already initialized."
    fi
}

# ---------------------------------------------------------------------------
# 4. Create ~/.otbrstack/env/ home directory
# ---------------------------------------------------------------------------

setup_otbr_home() {
    info "4. Creating ~/.otbrstack/env/ ..."
    mkdir -p "${HOME}/.otbrstack/env"
    success "${HOME}/.otbrstack/env/ ready."
}

# ---------------------------------------------------------------------------
# 5. Create .desktop entry for application launcher
# ---------------------------------------------------------------------------

setup_desktop_entry() {
    info "5. Creating desktop entry for iotstack otbr ..."

    local desktop_dir="${HOME}/.local/share/applications"
    local desktop_file="${desktop_dir}/iotstack-otbr.desktop"
    local icon_path="${SCRIPT_DIR}/resources/otbrstack.svg"
    local repo_root
    repo_root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    mkdir -p "$desktop_dir"

    cat > "$desktop_file" <<DESKTOP_EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=iotstack otbr
Comment=OpenThread Border Router Stack
Exec=codium ${repo_root}
Icon=iotstack-otbr
Terminal=false
Categories=Development;
DESKTOP_EOF

    mkdir -p "${HOME}/.local/share/icons/hicolor/scalable/apps"
    if [[ -f "$icon_path" ]]; then
        cp "$icon_path" "${HOME}/.local/share/icons/hicolor/scalable/apps/iotstack-otbr.svg"
        success "Desktop entry created: ${desktop_file}"
    else
        warn "Icon not found at ${icon_path}; desktop entry created but icon missing"
    fi
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

install_apt_packages
install_esptool
install_incus
setup_otbr_home
setup_desktop_entry

echo ""
echo "============================================================"
echo "  OTBR setup complete."
echo "  Run:  iotstack otbr help"
echo ""
echo "  Place your env files in ~/.otbrstack/env/"
echo "    e.g. cp otbr/.env.example ~/.otbrstack/env/.env"
echo "         cp otbr/.env.example ~/.otbrstack/env/\$(hostname).env"
echo "============================================================"
