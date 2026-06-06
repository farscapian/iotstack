#!/bin/bash
# setup.sh — Add iotstack command to PATH
# This script sets up the iotstack CLI tool so you can run 'iotstack' from anywhere

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

# Create stub secrets.yaml in yamls/ directory if it doesn't exist
SECRETS_FILE="${SCRIPT_DIR}/yamls/secrets.yaml"
if [[ ! -f "$SECRETS_FILE" ]]; then
  mkdir -p "${SCRIPT_DIR}/yamls"

  # Generate random base64-encoded API keys (32 bytes → 44 chars base64)
  bleproxy_key=$(openssl rand -base64 32 | tr -d '\n')
  mmwave_key=$(openssl rand -base64 32 | tr -d '\n')
  threadrouter_key=$(openssl rand -base64 32 | tr -d '\n')
  ledstrip_key=$(openssl rand -base64 32 | tr -d '\n')
  sendspin_key=$(openssl rand -base64 32 | tr -d '\n')

  cat > "$SECRETS_FILE" << EOF
# secrets.yaml
# All sensitive information (WiFi passwords, API keys, etc.) goes here.
# This file is NOT checked into git, so your secrets stay private.
#
# Uncomment and fill in the values needed by your devices:

# WiFi credentials (for WiFi devices)
# wifi_ssid: "YourWiFiName"
# wifi_password: "YourWiFiPassword"

# ESPHome device encryption keys (generated during setup)
# bleproxy_api_encryption_key: "$bleproxy_key"
# mmwave_api_encryption_key: "$mmwave_key"
# threadrouter_api_encryption_key: "$threadrouter_key"
# ledstrip_api_encryption_key: "$ledstrip_key"
# sendspin_api_encryption_key: "$sendspin_key"

# Home Assistant integration (optional)
# ha_url: "http://homeassistant.local:8123"
# ha_token: "eyJ0eXAiOiJKV1QiLCJhbGc..."
EOF
  ok "Created stub secrets.yaml in yamls/ with generated API encryption keys"
else
  dim "yamls/secrets.yaml already exists"
fi

# Create symlink from yamls/.iotstack -> ~/.iotstack for centralized artifacts
IOTSTACK_HOME="${HOME}/.iotstack"
IOTSTACK_LINK_IN_YAMLS="${SCRIPT_DIR}/yamls/.iotstack"

mkdir -p "$IOTSTACK_HOME"

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
    echo "" >> "$BASHRC"
    echo "# Add ~/.local/bin to PATH for iotstack command" >> "$BASHRC"
    echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$BASHRC"
    ok "Added ~/.local/bin to PATH in $BASHRC"
  fi
fi

# ── Password Manager Setup ──────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════"
echo "Password Manager Setup (for secure credential management)"
echo "════════════════════════════════════════════════════════"
echo
echo "iotstack can integrate with a password manager to:"
echo "  • Keep OTA passwords out of git (more secure)"
echo "  • Maintain audit trail of password changes"
echo "  • Enable easy password rotation across devices"
echo
read -p "Would you like to set up a password manager? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  echo
  echo "Available password managers:"
  echo "  1. pass (default) — Simple, local, no external account"
  echo "  2. Bitwarden — Cloud-based, team-friendly"
  echo "  3. 1Password — Enterprise option"
  echo "  4. Skip password manager setup"
  echo
  read -p "Choose password manager [1-4, default 1]: " -r pm_choice
  pm_choice="${pm_choice:-1}"

  case "$pm_choice" in
    1|"pass")
      echo
      echo "Installing pass..."
      if command -v apt &>/dev/null; then
        sudo apt update && sudo apt install -y pass
      elif command -v brew &>/dev/null; then
        brew install pass
      else
        warn "Could not find apt or brew. Please install pass manually."
        echo "  Ubuntu/Debian: sudo apt install pass"
        echo "  macOS: brew install pass"
      fi

      if command -v pass &>/dev/null; then
        ok "pass installed successfully"
        echo
        echo "Next steps for pass:"
        echo "  1. Initialize pass with your GPG key:"
        echo "    pass init <your-gpg-key-id>"
        echo "  2. Add OTA passwords:"
        echo "    pass insert iotstack/bleproxy/ota_password"
      fi
      PM_PROVIDER="pass"
      ;;

    2|"Bitwarden"|"bitwarden")
      echo
      echo "Installing Bitwarden CLI..."
      if command -v npm &>/dev/null; then
        npm install -g @bitwarden/cli
      else
        warn "npm not found. Please install Bitwarden CLI manually:"
        echo "  npm install -g @bitwarden/cli"
      fi

      if command -v bw &>/dev/null; then
        ok "Bitwarden CLI installed successfully"
        echo
        echo "Next steps for Bitwarden:"
        echo "  1. Login to Bitwarden:"
        echo "    bw login"
        echo "  2. Create vault and add secrets as described in docs/"
      fi
      PM_PROVIDER="bitwarden"
      ;;

    3|"1Password"|"1password")
      echo
      warn "1Password setup requires manual installation."
      echo "Please install the 1Password CLI from:"
      echo "  https://developer.1password.com/docs/cli/"
      echo
      echo "After installation, login with:"
      echo "  op account add --shorthand myaccount"
      PM_PROVIDER="1password"
      ;;

    *)
      echo
      warn "Skipping password manager setup"
      PM_PROVIDER=""
      ;;
  esac
else
  echo "Skipping password manager setup"
  PM_PROVIDER=""
fi

# Create ~/.iotstack/config
echo
echo "Creating password manager configuration..."
mkdir -p "$IOTSTACK_HOME"

if [[ -f "${IOTSTACK_HOME}/config" ]]; then
  dim "${IOTSTACK_HOME}/config already exists"
else
  # Determine which provider to set as default
  if [[ -n "$PM_PROVIDER" ]]; then
    DEFAULT_PROVIDER="$PM_PROVIDER"
  else
    DEFAULT_PROVIDER="pass"
  fi

  cat > "${IOTSTACK_HOME}/config" << EOF
# iotstack password manager configuration
# See docs/PASSWORD-MANAGER-SETUP.md for complete setup instructions

[password-manager]
# Which password manager to use: bitwarden, pass, 1password, keepassxc
provider = $DEFAULT_PROVIDER

# ── Bitwarden Configuration ─────────────────────────────────────────────────
# Requirements: bw CLI installed
# Secrets stored as: iotstack/<role>/<secret-type>
#
# [bitwarden]
# vault = iotstack  # Optional: specific vault name

# ── pass Configuration ──────────────────────────────────────────────────────
# Requirements: pass installed
# Secrets stored in: ~/.password-store/iotstack/<role>/<secret-type>
#
# [pass]
# # No additional config needed

# ── 1Password Configuration ─────────────────────────────────────────────────
# Requirements: op CLI installed
# Secrets stored as: iotstack_<role>_<secret-type>
#
# [1password]
# vault = iotstack  # Optional: specific vault name
# account = myaccount.1password.com  # Optional: specific account

# ── KeePassXC Configuration ─────────────────────────────────────────────────
# Requirements: keepassxc-cli installed
#
# [keepassxc]
# database = /path/to/database.kdbx
# password = your-master-password  # Or use KEEPASSXC_PASSWORD env var
EOF

  ok "Created configuration at ${IOTSTACK_HOME}/config"
fi

echo
echo "════════════════════════════════════════════════════════"
echo "Setup Complete!"
echo "════════════════════════════════════════════════════════"
echo
echo "To use iotstack, run:"
echo -e "  ${GRN}source $BASHRC${RST}"
echo
echo "Then test it with:"
echo -e "  ${GRN}which iotstack${RST}"
echo -e "  ${GRN}iotstack help${RST}"
echo
if [[ -n "$PM_PROVIDER" ]]; then
  echo "For password manager setup, see:"
  echo -e "  ${GRN}docs/QUICK-START-SECRETS.md${RST}"
fi
