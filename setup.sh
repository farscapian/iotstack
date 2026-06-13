#!/bin/bash
# setup.sh — Add iotstack command to PATH
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

# Early exit if sourced - just set environment variables
if [[ $_sourced -eq 1 ]]; then
  export GNUPGHOME="${HOME}/.iotstack/.gnupg"
  export PASSWORD_STORE_DIR="${HOME}/.iotstack/.pass"
  return 0
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# Create default environment file ~/.iotstack/.env if it doesn't exist
IOTSTACK_HOME="${HOME}/.iotstack"
mkdir -p "$IOTSTACK_HOME"

ENV_FILE="${IOTSTACK_HOME}/.env"
ENV_TEMPLATE="${SCRIPT_DIR}/resources/.env.example"

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$ENV_TEMPLATE" ]]; then
    cp "$ENV_TEMPLATE" "$ENV_FILE"
    ok "Created default environment file: $ENV_FILE"
  else
    # Fallback if template doesn't exist
    cat > "$ENV_FILE" << 'EOF'
# iotstack Environment Configuration
# Location: ~/.iotstack/.env (loaded by default on every invocation)

# Force recompilation of firmware on every build (disables compilation cache)
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

# ── GPG Key Setup (required before pass) ──────────────────────────────────
# ── Matter Commissioning Dependencies ──────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════"
echo "Checking Matter commissioning dependencies (optional)"
echo "════════════════════════════════════════════════════════"
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
      sudo apt update && sudo apt install -y zbar-tools || warn "Failed to install zbar-tools"
    fi

    # curl
    if [[ " ${MISSING_DEPS[*]} " =~ " curl " ]]; then
      sudo apt install -y curl || warn "Failed to install curl"
    fi

    # python3
    if [[ " ${MISSING_DEPS[*]} " =~ " python3 " ]]; then
      sudo apt install -y python3 python3-pip || warn "Failed to install python3"
      pip3 install websocket-client >/dev/null 2>&1 || warn "Failed to install websocket-client Python library"
    fi

    # chip-tool (needs separate install from source or snap)
    if [[ " ${MISSING_DEPS[*]} " =~ " chip-tool " ]]; then
      warn "chip-tool must be installed separately:"
      echo "  https://github.com/project-chip/connectedhomeip/tree/master/examples/chip-tool"
      echo "  Or via: sudo snap install chip-tool"
    fi
  else
    dim "Skipping dependency installation"
    echo "To use 'iotstack commission', install:"
    printf '  sudo apt install %s\n' "${MISSING_DEPS[@]}"
    echo "  And: sudo snap install chip-tool  (or build from source)"
  fi
else
  ok "All Matter commissioning dependencies installed"
fi

echo

# ── GPG Key Setup (required before pass) ──────────────────────────────────
echo
echo "════════════════════════════════════════════════════════"
echo "Setting up GPG key (required for pass)"
echo "════════════════════════════════════════════════════════"
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

# ── Pass Password Manager Setup ────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════"
echo "Initializing pass password manager"
echo "════════════════════════════════════════════════════════"
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

# ── Install gocryptfs (user-land encrypted FUSE filesystem) ──────────────────
echo
if ! command -v gocryptfs &>/dev/null; then
  echo "Installing gocryptfs (user-land encrypted filesystem)..."
  if command -v apt &>/dev/null; then
    # Try standard install
    if sudo apt update && sudo apt install -y gocryptfs 2>/dev/null; then
      ok "gocryptfs installed via apt"
    else
      # Try enabling universe repo (common for gocryptfs)
      echo "gocryptfs not in default repos. Trying universe repository..."
      sudo add-apt-repository -y universe 2>/dev/null || true
      if sudo apt update && sudo apt install -y gocryptfs 2>/dev/null; then
        ok "gocryptfs installed via apt (universe)"
      else
        warn "Could not install gocryptfs via apt. Please install manually:"
        echo "  https://github.com/rfjakob/gocryptfs/releases"
      fi
    fi
  elif command -v brew &>/dev/null; then
    if brew install gocryptfs 2>/dev/null; then
      ok "gocryptfs installed via brew"
    else
      warn "Could not install gocryptfs via brew. Please install manually:"
      echo "  https://github.com/rfjakob/gocryptfs/releases"
    fi
  else
    warn "Could not install gocryptfs automatically (no apt or brew found)."
    echo "Please install manually:"
    echo "  https://github.com/rfjakob/gocryptfs/releases"
  fi
fi

if command -v gocryptfs &>/dev/null; then
  ok "gocryptfs is installed"
else
  err "gocryptfs not found. iotstack requires gocryptfs for encrypted secrets.
Please install from: https://github.com/rfjakob/gocryptfs/releases"
fi

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

# ── Create Desktop Taskbar Application ────────────────────────────────────
echo
echo "Creating taskbar application..."
APPLICATIONS_DIR="${HOME}/.local/share/applications"
ICONS_DIR="${HOME}/.local/share/icons"
DESKTOP_FILE="${APPLICATIONS_DIR}/iotstack.desktop"
LOGO_SRC="${SCRIPT_DIR}/assets/iotstack-logo.svg"

mkdir -p "$APPLICATIONS_DIR" "$ICONS_DIR"

# Copy logo to icons directory
if [[ -f "$LOGO_SRC" ]]; then
  cp "$LOGO_SRC" "$ICONS_DIR/iotstack-logo.svg"
  ok "Installed logo to $ICONS_DIR/iotstack-logo.svg"
else
  warn "Logo not found at $LOGO_SRC"
fi

# Create .desktop file for taskbar (with pinning support)
# Use dynamic path so it works regardless of where repo is cloned
cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Name=iotstack
Comment=IoT device management and flashing
Exec=codium $SCRIPT_DIR
Icon=iotstack-logo
Type=Application
Categories=Development;Utility;
Terminal=false
StartupNotify=true
Keywords=iot;esp32;esphome;flashing;matter;
X-GNOME-UsesNotifications=false
EOF

chmod 644 "$DESKTOP_FILE"
ok "Created taskbar application: $DESKTOP_FILE"
echo "   Right-click 'iotstack' in Activities to pin to taskbar"

# Update desktop database
if command -v update-desktop-database &>/dev/null; then
  update-desktop-database "$APPLICATIONS_DIR" >/dev/null 2>&1 || true
  ok "Updated desktop database"
fi

echo
echo "════════════════════════════════════════════════════════"
echo "Setup Complete!"
echo "════════════════════════════════════════════════════════"
echo
echo "Next steps:"
echo
echo "1. Load environment:"
echo -e "  ${GRN}source $BASHRC${RST}"
echo
echo "2. Start using iotstack:"
echo -e "  ${GRN}iotstack update bleproxy${RST}"
echo -e "  ${GRN}iotstack flash bleproxy /dev/ttyACM0${RST}"
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
