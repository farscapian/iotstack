#!/usr/bin/env bash
# ensure-otbr-deps.sh -- OTBR (OpenThread Border Router) host dependencies.
#
# Used by setup.sh (interactive, one-time onboarding) and by otbr/otbr.sh
# (non-interactive re-checks: `iotstack otbr setup`, and auto-heal when a
# command needs a tool that isn't installed yet).
#
# Runtime data (esptool venv, etc.) lives under ~/.iotstack/otbr/ --
# see scripts/config.sh for IOTSTACK_HOME.

set -euo pipefail

IOTSTACK_HOME="${IOTSTACK_HOME:-${HOME}/.iotstack}"
OTBR_HOME="${OTBR_HOME:-${IOTSTACK_HOME}/otbr}"

# apt packages needed across the otbr scripts:
#   flash-piotbr.sh        : curl sha256sum xzcat(xz-utils) dd lsblk partprobe(parted) python3
#   provision_incus.sh     : curl python3 lsof envsubst(gettext-base)
#   otbrstack-docker-setup.sh : curl ca-certificates gnupg (installs Docker CE itself)
#   otbrstack-snap-setup.sh   : python3 lsof (ufw optional; checked at runtime)
OTBR_APT_PKGS=(
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
    parted         # partprobe
    util-linux     # lsblk, dd
)

install_otbr_apt_packages() {
    local missing=()
    local pkg
    for pkg in "${OTBR_APT_PKGS[@]}"; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" \
            || missing+=("$pkg")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "[OK] OTBR apt packages already installed."
        return 0
    fi

    echo "[INFO] Installing OTBR apt packages: ${missing[*]}"
    if [[ -n "${HTTP_PROXY:-}" ]]; then
        echo "Acquire::http::Proxy \"${HTTP_PROXY}\";" \
            | sudo tee /etc/apt/apt.conf.d/90apt-cache >/dev/null
    fi
    sudo apt-get update -q
    sudo apt-get install -y "${missing[@]}"
    echo "[OK] OTBR apt packages installed."
}

# esptool, used for ESP32-C6 RCP firmware flashing, isolated in its own venv
# (separate from the ESPHome venv setup.sh already manages).
install_otbr_esptool() {
    local esptool_venv="${OTBR_HOME}/artifacts/esptool-venv"

    if command -v esptool &>/dev/null || command -v esptool.py &>/dev/null; then
        echo "[OK] esptool already available: $(esptool.py version 2>/dev/null || esptool version 2>/dev/null | head -1)"
        return 0
    fi

    if [[ -x "${esptool_venv}/bin/esptool.py" ]]; then
        echo "[OK] esptool available in venv: $("${esptool_venv}/bin/esptool.py" version 2>/dev/null | head -1)"
        return 0
    fi

    echo "[INFO] Installing esptool into venv at ${esptool_venv} ..."
    python3 -m venv "${esptool_venv}"
    "${esptool_venv}/bin/pip" install --quiet esptool
    echo "[OK] esptool installed into ${esptool_venv}."
}

otbr_incus_is_installed() { command -v incus &>/dev/null; }

install_otbr_incus() {
    if ! otbr_incus_is_installed; then
        echo "[INFO] incus not found -- installing via apt ..."
        sudo apt-get update -q
        sudo apt-get install -y incus
        echo "[OK] incus installed: $(incus --version)"
    else
        echo "[OK] incus already installed: $(incus --version)"
    fi

    # Group membership is managed only by setup.sh -- check, never change.
    if ! id -nG "$USER" | tr ' ' '\n' | grep -qx incus-admin; then
        echo "[WARN] ${USER} is not in the incus-admin group -- run ./setup.sh to add it."
    fi

    if ! incus info &>/dev/null 2>&1; then
        echo "[INFO] Initializing incus with auto preset ..."
        sudo incus admin init --auto
        echo "[OK] incus initialized."
    else
        echo "[OK] incus already initialized."
    fi
}

otbr_docker_is_installed() { command -v docker &>/dev/null; }

# Minimal Docker Engine install (Docker CE + compose plugin). The full
# OTBR container/nginx/reverse-proxy configuration happens later, on demand,
# in otbr/scripts/otbrstack-docker-setup.sh (invoked by `iotstack otbr docker`).
install_otbr_docker() {
    if otbr_docker_is_installed; then
        echo "[OK] Docker already installed: $(docker --version)"
        return 0
    fi

    echo "[INFO] Installing Docker CE ..."
    if [[ -n "${HTTP_PROXY:-}" ]]; then
        echo "Acquire::http::Proxy \"${HTTP_PROXY}\";" \
            | sudo tee /etc/apt/apt.conf.d/90apt-cache >/dev/null
    fi
    sudo apt-get update -q
    sudo apt-get install -y ca-certificates curl gnupg

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -q
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    sudo systemctl enable --now docker
    echo "[OK] Docker CE installed: $(docker --version)"
}

ensure_otbr_snapd() {
    if command -v snap &>/dev/null; then
        echo "[OK] snapd already installed."
        return 0
    fi
    echo "[INFO] Installing snapd ..."
    sudo apt-get update -q
    sudo apt-get install -y snapd
    echo "[OK] snapd installed."
}
