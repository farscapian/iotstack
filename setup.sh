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

# ── GPG Key Setup (required before pass) ──────────────────────────────────
echo
echo "════════════════════════════════════════════════════════"
echo "Setting up GPG key (required for pass)"
echo "════════════════════════════════════════════════════════"
echo

# Check if user has existing GPG key in ~/.gnupg
parent_key=$(gpg --list-secret-keys --keyid-format SHORT 2>/dev/null | grep -m1 "^sec" | awk '{print $2}' | cut -d'/' -f2 || echo "")

if [[ -n "$parent_key" ]]; then
  echo "Found existing GPG key in ~/.gnupg: $parent_key"
  echo "Importing parent key to iotstack GPG home..."

  # Export parent key from default GNUPGHOME and import to iotstack's GNUPGHOME
  mkdir -p "$GNUPGHOME"
  export_file=$(mktemp)
  gpg --export-secret-keys "$parent_key" > "$export_file"

  # Import to isolated GNUPGHOME
  GNUPGHOME="$GNUPGHOME" gpg --import "$export_file" 2>&1 | grep -v "^gpg:" || true
  rm -f "$export_file"

  gpg_key="$parent_key"
  ok "Using parent GPG key: $gpg_key"
else
  echo "No existing GPG key found. Generating new key for iotstack..."

  # Set GNUPGHOME for new key generation
  export GNUPGHOME="$GNUPGHOME"
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

  # Verify key was created
  gpg_key=$(GNUPGHOME="$GNUPGHOME" gpg --list-secret-keys --keyid-format SHORT 2>/dev/null | grep -m1 "^sec" | awk '{print $2}' | cut -d'/' -f2 || echo "")
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

# Seed pass repository with secrets and config from secrets.yaml
echo
echo "Seeding pass repository with secrets and configuration..."
SECRETS_YAML="${SCRIPT_DIR}/yamls/secrets.yaml"

if [[ -f "$SECRETS_YAML" ]]; then
  export GNUPGHOME="${IOTSTACK_HOME}/.gnupg"
  export PASSWORD_STORE_DIR="$PASS_DIR"

  # Config items that should exist but can be empty (seeded with placeholder)
  declare -a config_items=("wifi_ssid" "wifi_password" "thread_tlv" "ha_url" "ha_token")

  # Seed config items with placeholder (user can update via: pass edit iotstack/wifi_ssid)
  for config_key in "${config_items[@]}"; do
    pass_path="iotstack/${config_key}"
    if ! pass show "$pass_path" >/dev/null 2>&1; then
      echo "CONFIGURE_ME" | pass insert -f "$pass_path" 2>&1 | grep -v "^mkdir:" || true
    fi
  done

  # Extract secrets and add them to pass
  # Format: key: "value" or key: value
  while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ ]] && continue  # Skip comments
    [[ -z "$line" ]] && continue         # Skip empty lines

    if [[ "$line" =~ ^([a-z_]+):[[:space:]]+\"?([^\"]+)\"?$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"

      # Handle device secrets: bleproxy_api_encryption_key -> iotstack/bleproxy/api_encryption_key
      if [[ "$key" =~ ^([a-z_]+)_(api_encryption_key|ota_password)$ ]]; then
        role="${BASH_REMATCH[1]}"
        secret_type="${BASH_REMATCH[2]}"

        # Only seed if corresponding YAML file exists
        if [[ ! -f "${SCRIPT_DIR}/yamls/${role}.yaml" ]]; then
          continue
        fi

        pass_path="iotstack/${role}/${secret_type}"

        # Add to pass if not already present
        if ! pass show "$pass_path" >/dev/null 2>&1; then
          insert_output=$(echo "$value" | pass insert -f "$pass_path" 2>&1 | grep -v "^mkdir:")
          if [[ $? -eq 0 ]]; then
            ok "Added: $pass_path"
          else
            warn "Failed to add: $pass_path"
            [[ -n "$insert_output" ]] && echo "    Error: $insert_output" >&2
          fi
        fi
      fi
    fi
  done < "$SECRETS_YAML"
else
  warn "secrets.yaml not found, skipping seeding"
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
