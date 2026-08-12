#!/bin/bash
# setup.sh -- Add iotstack command to PATH
# This script sets up the iotstack CLI tool so you can run 'iotstack' from anywhere
#
# Can be executed or sourced:
#   ./setup.sh                  # Run setup
#   source setup.sh             # Just set environment variables

# Detect if being sourced or executed
_sourced=0
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  _sourced=1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source centralized configuration (resolves IOTSTACK_HOME, GNUPG_HOME,
# PASS_STORE_DIR, ENV_FILE and loads ~/.iotstack/.env)
# shellcheck source=scripts/config.sh
source "${SCRIPT_DIR}/scripts/config.sh"

# Early exit if sourced - config.sh (above) already exported GNUPGHOME/PASSWORD_STORE_DIR
if [[ $_sourced -eq 1 ]]; then
  return 0
fi

set -euo pipefail

IOTSTACK_SCRIPT="${SCRIPT_DIR}/iotstack.sh"
LOCAL_BIN="${HOME}/.local/bin"
IOTSTACK_LINK="${LOCAL_BIN}/iotstack"
BASHRC="${HOME}/.bashrc"

# Colors
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
RST='\033[0m'

err()  { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }
ok()   { echo -e "${GRN}[OK]${RST} $*"; }
warn() { echo -e "${YLW}[WARN]${RST} $*"; }
dim()  { echo -e "${YLW}$*${RST}"; }

# Verify iotstack.sh exists
if [[ ! -f "$IOTSTACK_SCRIPT" ]]; then
  err "iotstack.sh not found at $IOTSTACK_SCRIPT"
fi

if [[ ! -x "$IOTSTACK_SCRIPT" ]]; then
  err "iotstack.sh is not executable. Run: chmod +x $IOTSTACK_SCRIPT"
fi

# -- Dialout Group Membership (required for /dev/ttyACM* access) -----------
echo
echo "========================================================"
echo "Checking dialout group membership"
echo "========================================================"
echo

if id -nG "$USER" | tr ' ' '\n' | grep -qx dialout; then
  ok "User $USER is already a member of the dialout group"
else
  warn "User $USER is not a member of the dialout group (required for /dev/ttyACM* access)"
  read -p "Add $USER to the dialout group now? (y/N) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo usermod -aG dialout "$USER"
    ok "Added $USER to the dialout group"
    warn "Log out and back in (or run: newgrp dialout) for the group change to take effect"
  else
    dim "Skipping -- flashing over /dev/ttyACM* will fail with a permissions error until you run:"
    echo "  sudo usermod -aG dialout \$USER"
  fi
fi

# -- ESPHome Installation ---------------------------------------------------
echo
echo "========================================================"
echo "Installing ESPHome"
echo "========================================================"
echo

if ! command -v python3 &>/dev/null; then
  err "python3 is required to install esphome"
fi

ESPHOME_HOME="${HOME}/.local/esphome"
ESPHOME_VENV="${ESPHOME_HOME}/venv"
ESPHOME_BIN="${ESPHOME_VENV}/bin/esphome"

if [[ ! -x "${ESPHOME_VENV}/bin/python3" ]]; then
  # python3 -m venv exits non-zero (under set -e, kills the script) when
  # ensurepip fails, even though it still creates bin/python3. Don't let
  # that failure escape here -- the pip check below detects and recovers.
  python3 -m venv "$ESPHOME_VENV" || true
  ok "Created esphome virtualenv: $ESPHOME_VENV"
fi

# python3 -m venv can produce a venv with no pip if the distro's venv
# package (e.g. python3.14-venv) isn't installed. Detect and fix that.
if [[ ! -x "${ESPHOME_VENV}/bin/pip" ]]; then
  warn "esphome venv is missing pip -- ensurepip was unavailable"
  PY_VENV_PKG="python$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')-venv"
  if command -v apt &>/dev/null; then
    echo "Installing ${PY_VENV_PKG}..."
    sudo apt update && sudo apt install -y "$PY_VENV_PKG"
    rm -rf "$ESPHOME_VENV"
    python3 -m venv "$ESPHOME_VENV"
    ok "Recreated esphome virtualenv: $ESPHOME_VENV"
  fi
  if [[ ! -x "${ESPHOME_VENV}/bin/pip" ]]; then
    err "esphome venv has no pip. Install manually: sudo apt install ${PY_VENV_PKG}"
  fi
fi

"${ESPHOME_VENV}/bin/pip" install --upgrade pip >/dev/null
"${ESPHOME_VENV}/bin/pip" install --upgrade esphome

ESPHOME_VERSION=$("$ESPHOME_BIN" version 2>/dev/null | head -1 || echo "unknown")
ok "Installed esphome: ${ESPHOME_VERSION}"

# Git pre-commit hook: shellcheck on staged .sh files
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  chmod +x "${SCRIPT_DIR}/.githooks/pre-commit" "${SCRIPT_DIR}/scripts/shellcheck-staged.sh"
  git -C "$SCRIPT_DIR" config core.hooksPath .githooks
  ok "Git hooks installed (pre-commit: shellcheck staged .sh files)"
else
  dim "Not a git repository -- skipping git hooks"
fi

# Create default environment file if it doesn't exist
# (IOTSTACK_HOME and ENV_FILE come from config.sh, which also created the dir)
ENV_TEMPLATE="${SCRIPT_DIR}/docs/.env.example"

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ENV_TEMPLATE" ]]; then
    cp "$ENV_TEMPLATE" "$ENV_FILE"
    ok "Created default environment file: $ENV_FILE"
  else
    # Fallback if template doesn't exist
    cat > "$ENV_FILE" << 'EOF'
# iotstack Environment Configuration
# Location: ~/.iotstack/.env (loaded by default on every invocation)

# Force recompilation of firmware on every build (disables compile skip)
# Values: 0 (default, use cache) or 1 (always recompile)
DISABLE_COMPILATION_CACHE=0
EOF
    ok "Created default environment file: $ENV_FILE (from fallback)"
  fi
else
  dim "$ENV_FILE already exists"
fi

# Create symlink from yamls/.iotstack -> ~/.iotstack for centralized artifacts
IOTSTACK_LINK_IN_YAMLS="${SCRIPT_DIR}/yamls/.iotstack"

# Remove old symlink if it exists
if [[ -L "$IOTSTACK_LINK_IN_YAMLS" ]]; then
  rm -f "$IOTSTACK_LINK_IN_YAMLS"
fi

# Create symlink (only if it doesn't exist and isn't already a directory)
if [[ ! -e "$IOTSTACK_LINK_IN_YAMLS" ]]; then
  ln -s "$IOTSTACK_HOME" "$IOTSTACK_LINK_IN_YAMLS"
  ok "Created symlink: yamls/.iotstack -> $IOTSTACK_HOME"
else
  dim "yamls/.iotstack already exists"
fi

# Create ~/.local/bin if needed
mkdir -p "$LOCAL_BIN"

# Remove old symlink/file if it exists
if [[ -e "$IOTSTACK_LINK" ]] || [[ -L "$IOTSTACK_LINK" ]]; then
  rm -f "$IOTSTACK_LINK"
fi

# Create symlink
ln -s "$IOTSTACK_SCRIPT" "$IOTSTACK_LINK"
ok "Created symlink: $IOTSTACK_LINK"

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
  if ! grep -q "export PATH=.*\.local/bin" "$BASHRC" 2>/dev/null; then
    {
      echo ""
      echo "# Add ~/.local/bin to PATH for iotstack command"
      echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
    } >> "$BASHRC"
    ok "Added ~/.local/bin to PATH in $BASHRC"
  fi
fi

# Add iotstack environment variables to bashrc
if ! grep -q "GNUPGHOME=.*\.iotstack" "$BASHRC" 2>/dev/null; then
  {
    echo ""
    echo "# iotstack environment variables (for pass/GPG)"
    echo "export GNUPGHOME=\"\${HOME}/.iotstack/.gnupg\""
    echo "export PASSWORD_STORE_DIR=\"\${HOME}/.iotstack/.pass\""
  } >> "$BASHRC"
  ok "Added iotstack env vars to $BASHRC"
fi

# -- GPG Key Setup (required before pass) ----------------------------------
# -- Matter Commissioning Dependencies --------------------------------------
echo
echo "========================================================"
echo "Checking Matter commissioning dependencies (optional)"
echo "========================================================"
echo

MISSING_DEPS=()

# Check for zbar-tools (zbarimg for QR decoding)
if ! command -v zbarimg &>/dev/null; then
  MISSING_DEPS+=("zbar-tools")
fi

# Check for chip-tool
if ! command -v chip-tool &>/dev/null; then
  MISSING_DEPS+=("chip-tool")
fi

# Check for curl and python3 (usually present)
if ! command -v curl &>/dev/null; then
  MISSING_DEPS+=("curl")
fi

if ! command -v python3 &>/dev/null; then
  MISSING_DEPS+=("python3")
fi

if command -v python3 &>/dev/null && ! python3 -c "import websocket" 2>/dev/null; then
  MISSING_DEPS+=("python3-websocket-client")
fi

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
  echo "Missing dependencies for Matter commissioning:"
  printf '  %s\n' "${MISSING_DEPS[@]}"
  echo
  read -p "Install missing dependencies now? (y/N) " -n 1 -r
  echo

  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Installing dependencies..."

    # zbar-tools
    if [[ " ${MISSING_DEPS[*]} " =~ " zbar-tools " ]]; then
      if ! (sudo apt update && sudo apt install -y zbar-tools); then
        warn "Failed to install zbar-tools"
      fi
    fi

    # curl
    if [[ " ${MISSING_DEPS[*]} " =~ " curl " ]]; then
      sudo apt install -y curl || warn "Failed to install curl"
    fi

    # python3
    if [[ " ${MISSING_DEPS[*]} " =~ " python3 " ]]; then
      sudo apt install -y python3 python3-pip || warn "Failed to install python3"
    fi

    # websocket-client (required for Home Assistant WebSocket API)
    if [[ " ${MISSING_DEPS[*]} " =~ " python3-websocket-client " ]]; then
      pip3 install websocket-client >/dev/null 2>&1 || warn "Failed to install websocket-client Python library"
    fi

    # chip-tool (snap recommended on Ubuntu/Debian)
    if [[ " ${MISSING_DEPS[*]} " =~ " chip-tool " ]]; then
      if command -v snap &>/dev/null; then
        # shellcheck source=scripts/ensure-chip-tool-storage.sh
        source "${SCRIPT_DIR}/scripts/ensure-chip-tool-storage.sh"
        setup_chip_tool_snap || warn "chip-tool snap setup incomplete -- see messages above"
      else
        warn "snap not found; install chip-tool manually:"
        echo "  https://github.com/project-chip/connectedhomeip/tree/master/examples/chip-tool"
      fi
    fi
  else
    dim "Skipping dependency installation"
    echo "To use 'iotstack matter commission', install:"
    printf '  sudo apt install %s\n' "${MISSING_DEPS[@]}"
    echo "  And: sudo snap install chip-tool  (or build from source)"
  fi
else
  ok "All Matter commissioning dependencies installed"
fi

# -- chip-tool layout + snap interfaces -----------------------------------
# shellcheck source=scripts/ensure-chip-tool-storage.sh
source "${SCRIPT_DIR}/scripts/ensure-chip-tool-storage.sh"
if command -v snap &>/dev/null && chip_tool_snap_is_installed; then
  setup_chip_tool_snap_enabled || true
  setup_chip_tool_snap_interfaces || true
fi
if command -v chip-tool &>/dev/null; then
  setup_chip_tool_layout
  if chip_tool_is_snap; then
    ok "chip-tool layout: ~/.iotstack/chip-tool -> ~/snap/chip-tool"
  else
    ok "chip-tool layout: ~/.iotstack/chip-tool/{common,common/trust,paa-mirror}"
  fi
elif chip_tool_snap_is_installed && chip_tool_snap_is_disabled; then
  warn "chip-tool snap is still disabled -- run: sudo snap enable chip-tool"
elif chip_tool_snap_is_installed; then
  warn "chip-tool snap is installed but not on PATH -- try: hash -r && which chip-tool"
fi

echo

# -- GPG Key Setup (required before pass) ----------------------------------
echo
echo "========================================================"
echo "Setting up GPG key (required for pass)"
echo "========================================================"
echo

# Define GNUPGHOME early (needed for both import and generation paths)
GNUPGHOME="${IOTSTACK_HOME}/.gnupg"
export GNUPGHOME

# Check if user has existing GPG key in ~/.gnupg (use LONG format for pass compatibility)
parent_key=$(gpg --list-secret-keys --keyid-format LONG 2>/dev/null | grep -m1 "^sec" | awk '{print $2}' | cut -d'/' -f2 || echo "")

if [[ -n "$parent_key" ]]; then
  echo "Found existing GPG key in ~/.gnupg: $parent_key"
  echo "Importing parent key to iotstack GPG home..."

  # Export parent key from default GNUPGHOME and import to iotstack's GNUPGHOME
  mkdir -p "$GNUPGHOME"
  export_file=$(mktemp)
  gpg --export-secret-keys "$parent_key" > "$export_file"

  # Import to isolated GNUPGHOME
  gpg --import "$export_file" 2>&1 | grep -v "^gpg:" || true
  rm -f "$export_file"

  gpg_key="$parent_key"
  ok "Using parent GPG key: $gpg_key"
else
  echo "No existing GPG key found. Generating new key for iotstack..."

  # Create GNUPGHOME directory
  mkdir -p "$GNUPGHOME"

  gpg --batch --generate-key <<'EOF'
Key-Type: RSA
Key-Length: 2048
Name-Real: iotstack
Name-Email: iotstack@localhost
Expire-Date: 0
%no-protection
%commit
EOF
  sleep 3

  # Verify key was created (use LONG format for pass compatibility)
  gpg_key=$(GNUPGHOME="$GNUPGHOME" gpg --list-secret-keys --keyid-format LONG 2>/dev/null | grep -m1 "^sec" | awk '{print $2}' | cut -d'/' -f2 || echo "")
  if [[ -z "$gpg_key" ]]; then
    err "Failed to generate or locate GPG key"
  fi
  ok "Generated GPG key in ~/.iotstack/.gnupg: $gpg_key"
fi

# -- Pass Password Manager Setup --------------------------------------------
echo
echo "========================================================"
echo "Initializing pass password manager"
echo "========================================================"
echo

# Check if pass is installed
if ! command -v pass &>/dev/null; then
  echo "Installing pass..."
  if command -v apt &>/dev/null; then
    sudo apt update && sudo apt install -y pass
  elif command -v brew &>/dev/null; then
    brew install pass
  else
    err "Could not install pass automatically. Please install manually:\n  Ubuntu/Debian: sudo apt install pass\n  macOS: brew install pass"
  fi
fi

ok "pass is installed"

# Create pass repository in ~/.iotstack/.pass
PASS_DIR="${IOTSTACK_HOME}/.pass"

# Initialize pass repository
if [[ -f "${PASS_DIR}/.gpg-id" ]]; then
  dim "pass repository already initialized at $PASS_DIR"
else
  echo "Initializing pass repository at $PASS_DIR with GPG key $gpg_key..."
  rm -rf "$PASS_DIR"
  mkdir -p "$PASS_DIR"

  export GNUPGHOME="$GNUPGHOME"
  export PASSWORD_STORE_DIR="$PASS_DIR"
  pass init "$gpg_key" 2>&1 | grep -v "^mkdir:" || err "pass init failed"
  sleep 1

  if [[ -f "${PASS_DIR}/.gpg-id" ]]; then
    ok "Initialized pass repository with GPG key: $gpg_key"
  else
    err "pass init failed - no .gpg-id file created"
  fi
fi

# Seed pass repository with configuration
echo
echo "Seeding pass repository with configuration..."
export GNUPGHOME="${IOTSTACK_HOME}/.gnupg"
export PASSWORD_STORE_DIR="$PASS_DIR"

# Config items that should exist but can be empty (seeded with placeholder)
declare -a config_items=("wifi_ssid" "wifi_password" "thread_tlv" "ha_url" "ha_token")

# Seed config items under iotstack/common/ (user can update via: pass edit iotstack/common/wifi_ssid)
for config_key in "${config_items[@]}"; do
  pass_path="iotstack/common/${config_key}"
  if ! pass show "$pass_path" >/dev/null 2>&1; then
    {
      echo "CONFIGURE_ME"
      echo "CONFIGURE_ME"
    } | pass insert -f "$pass_path" 2>&1 | grep -v "^mkdir:" || true
  fi
done

# -- Create Desktop Taskbar Application ------------------------------------
echo
echo "Creating taskbar application..."
APPLICATIONS_DIR="${HOME}/.local/share/applications"
ICONS_DIR="${HOME}/.local/share/icons"
DESKTOP_FILE="${APPLICATIONS_DIR}/iotstack.desktop"
LOGO_SRC="${SCRIPT_DIR}/docs/iotstack-logo.svg"
TERMINAL_LAUNCHER="${SCRIPT_DIR}/scripts/iotstack-terminal"

mkdir -p "$APPLICATIONS_DIR" "$ICONS_DIR"

# Copy logo to icons directory
if [[ -f "$LOGO_SRC" ]]; then
  cp "$LOGO_SRC" "$ICONS_DIR/iotstack.svg"
  ok "Installed logo to $ICONS_DIR/iotstack.svg"
else
  warn "Logo not found at $LOGO_SRC"
fi

# Ensure terminal launcher is executable
if [[ -f "$TERMINAL_LAUNCHER" ]]; then
  chmod +x "$TERMINAL_LAUNCHER"
fi

# Create .desktop file for taskbar (with pinning support)
# Opens a new terminal with iotstack styling when clicked
cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Type=Application
Name=iotstack
Comment=ESP32 ESPHome Device Management
Icon=iotstack
Exec=$TERMINAL_LAUNCHER
Terminal=false
Categories=Development;System;Utility;
Keywords=esp32;esphome;iot;firmware;
StartupNotify=true
EOF

chmod 644 "$DESKTOP_FILE"
ok "Created taskbar application: $DESKTOP_FILE"
echo "   You can now search for 'iotstack' in Activities or pin to taskbar"

# Update desktop database
if command -v update-desktop-database &>/dev/null; then
  update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
  ok "Updated desktop database"
fi

# Update icon cache
if command -v gtk-update-icon-cache &>/dev/null; then
  gtk-update-icon-cache "$ICONS_DIR" >/dev/null 2>&1 || true
fi

echo
echo "========================================================"
echo "Setup Complete!"
echo "========================================================"
echo
echo "Next steps:"
echo
echo "1. Load environment:"
echo -e "  ${GRN}source $BASHRC${RST}"
echo
echo "2. Start using iotstack:"
echo -e "  ${GRN}iotstack update bleproxy${RST}"
echo -e "  ${GRN}iotstack flash bleproxy /dev/ttyACM0${RST}"
echo -e "  ${GRN}iotstack otbr setup${RST}   (optional -- OTBR / Raspberry Pi provisioning)"
echo
echo "Your role-based secrets are stored encrypted in:"
echo -e "  ${GRN}${PASS_DIR}${RST}"
echo
echo "For more information:"
echo -e "  ${GRN}iotstack help${RST}  (CLI commands)"

echo
echo "Environment variables (automatically set by ${BASHRC}):"
export GNUPGHOME="${IOTSTACK_HOME}/.gnupg"
export PASSWORD_STORE_DIR="${IOTSTACK_HOME}/.pass"
echo -e "  ${GRN}GNUPGHOME${RST}=${GNUPGHOME}"
echo -e "  ${GRN}PASSWORD_STORE_DIR${RST}=${PASSWORD_STORE_DIR}"
