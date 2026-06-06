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

# Create pass repository in ~/.iotstack/.pass
PASS_DIR="${IOTSTACK_HOME}/.pass"
mkdir -p "$PASS_DIR"

# Initialize pass repository
if [[ -d "${PASS_DIR}/.git" ]]; then
  dim "pass repository already initialized at $PASS_DIR"
else
  echo "Initializing pass repository at $PASS_DIR..."
  # Create a GPG key if none exists, or use default key
  if command -v gpg &>/dev/null && ! gpg --list-secret-keys &>/dev/null; then
    echo "No GPG keys found. Creating a GPG key for pass..."
    echo "You will be prompted to create a GPG key. Enter your details:"
    gpg --gen-key || warn "GPG key generation may have been skipped"
  fi

  # Initialize pass with the default (or first available) GPG key
  export PASSWORD_STORE_DIR="$PASS_DIR"
  gpg_key=$(gpg --list-secret-keys --keyid-format SHORT 2>/dev/null | grep "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)

  if [[ -n "$gpg_key" ]]; then
    pass init "$gpg_key" >/dev/null 2>&1 || warn "pass init may have failed, but continuing..."
    ok "Initialized pass repository with GPG key: $gpg_key"
  else
    warn "Could not find GPG key. Please run: pass init <your-gpg-key-id>"
  fi
fi

# Seed pass repository with secrets from secrets.yaml
echo
echo "Seeding pass repository with API keys and OTA passwords..."
SECRETS_YAML="${SCRIPT_DIR}/yamls/secrets.yaml"

if [[ -f "$SECRETS_YAML" ]]; then
  export PASSWORD_STORE_DIR="$PASS_DIR"

  # Extract all secrets and add them to pass
  # Format: key: "value" or key: value
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ ]] && continue  # Skip comments
    [[ -z "$line" ]] && continue         # Skip empty lines

    if [[ "$line" =~ ^([a-z_]+):[[:space:]]+\"?([^\"]+)\"?$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"

      # Convert key format: bleproxy_api_encryption_key → iotstack/bleproxy/api_encryption_key
      if [[ "$key" =~ ^([a-z_]+)_(api_encryption_key|ota_password)$ ]]; then
        role="${BASH_REMATCH[1]}"
        secret_type="${BASH_REMATCH[2]}"
        pass_path="iotstack/${role}/${secret_type}"

        # Add to pass if not already present
        if ! pass show "$pass_path" >/dev/null 2>&1; then
          echo "$value" | pass insert -f "$pass_path" >/dev/null 2>&1
          ok "Added: $pass_path"
        fi
      fi
    fi
  done < "$SECRETS_YAML"
else
  warn "secrets.yaml not found, skipping seeding"
fi

# Create config file pointing to pass repository
echo
echo "Creating configuration..."
cat > "${IOTSTACK_HOME}/config" << 'EOF'
# iotstack password manager configuration
# Uses pass repository at ~/.iotstack/.pass

[password-manager]
provider = pass

[pass]
store_dir = ~/.iotstack/.pass
EOF

ok "Created configuration at ${IOTSTACK_HOME}/config"

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
echo "2. Mount secrets into RAM (no unencrypted disk writes):"
echo -e "  ${GRN}./scripts/mount-secrets${RST}"
echo
echo "3. Use iotstack:"
echo -e "  ${GRN}iotstack update bleproxy${RST}"
echo -e "  ${GRN}iotstack rotate-password mmwave${RST}"
echo
echo "4. When done (optional, auto-erased on reboot):"
echo -e "  ${GRN}./scripts/unmount-secrets${RST}"
echo
echo "Your encrypted secrets are stored in:"
echo -e "  ${GRN}${PASS_DIR}${RST}"
echo
echo "To manage passwords:"
echo -e "  ${GRN}pass ls iotstack${RST}"
echo -e "  ${GRN}pass insert iotstack/<role>/<secret-type>${RST}"
echo
echo "For more information:"
echo -e "  ${GRN}docs/RAMDISK-SECRETS.md${RST}  (RAM-only secrets)"
echo -e "  ${GRN}docs/QUICK-START-SECRETS.md${RST}  (Password manager setup)"
echo -e "  ${GRN}iotstack help${RST}  (CLI commands)"
