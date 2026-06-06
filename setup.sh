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

echo
echo "To use it now, run:"
echo -e "  ${GRN}source $BASHRC${RST}"
echo
echo "Then test it with:"
echo -e "  ${GRN}which iotstack${RST}"
echo -e "  ${GRN}iotstack help${RST}"
