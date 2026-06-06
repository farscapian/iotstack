# Password Manager Integration

This guide explains how to set up iotstack with your password manager for secure credential management.

## Why Password Manager Integration?

- **Never commit secrets** to git (secrets.yaml stays gitignored)
- **Audit trail** of password rotations
- **Historical passwords** kept for recovery
- **Team-friendly** — works with any password manager
- **Secure rotation** without bricking devices

## Supported Password Managers

- ✅ **Bitwarden** — cloud-based, team-friendly
- ✅ **pass** — simple Unix tool, local storage
- ✅ **1Password** — enterprise option
- ✅ **KeePassXC** — open-source offline
- ⏳ **Pears Pass** — under investigation

## Setup Instructions

### 1. Create Configuration File

Copy the template and configure your password manager:

```bash
mkdir -p ~/.iotstack
cp /path/to/iotstack/.iotstack-config-template ~/.iotstack/config
# Edit the config to uncomment your password manager section
nano ~/.iotstack/config
```

### 2. Configure Your Password Manager

#### Bitwarden

```bash
# Install CLI
npm install -g @bitwarden/cli

# Login (creates ~/.config/Bitwarden\ CLI/data.json)
bw login your-email@example.com

# Create vault structure
bw folder add iotstack  # Create folder

# Add secrets (format: iotstack/role/secret-type)
bw item create --folder iotstack-folder --type login \
  --name "iotstack/bleproxy/ota_password" \
  --password "your-password-here"
```

**Config:**
```ini
[password-manager]
provider = bitwarden

[bitwarden]
vault = iotstack  # Optional
```

#### pass

```bash
# Install
apt install pass  # Ubuntu/Debian
brew install pass  # macOS

# Initialize
pass init your-gpg-key-id

# Add secrets (stored in ~/.password-store/)
pass insert iotstack/bleproxy/ota_password
# You'll be prompted to enter the password
```

**Config:**
```ini
[password-manager]
provider = pass
```

#### 1Password

```bash
# Install CLI
brew install 1password-cli  # macOS
# Or download from https://developer.1password.com/docs/cli/

# Login (creates ~/.config/op/config)
op account add --shorthand myaccount

# Create vault
op vault create iotstack

# Add secrets (format: iotstack_role_secret_type)
op item create --vault iotstack \
  --category login \
  --title "iotstack_bleproxy_ota_password" \
  --generate-password=32
```

**Config:**
```ini
[password-manager]
provider = 1password

[1password]
vault = iotstack
account = myaccount.1password.com  # Optional
```

#### KeePassXC

```bash
# Install
apt install keepassxc  # Ubuntu/Debian
brew install keepassxc  # macOS

# Create database
keepassxc --help  # See options

# Manual: Use KeePassXC GUI to create entries in path:
# iotstack/bleproxy/ota_password
```

**Config:**
```ini
[password-manager]
provider = keepassxc

[keepassxc]
database = /path/to/iotstack.kdbx
# password stored in KEEPASSXC_PASSWORD env var or interactive prompt
```

### 3. Test Configuration

```bash
# Test retrieving a secret
./iotstack-secrets get bleproxy ota_password

# If successful, should output the password
# If fails, check your password manager configuration
```

## Secret Naming Convention

All secrets follow this pattern:

**Bitwarden/pass:** `iotstack/<role>/<secret-type>`
- Example: `iotstack/bleproxy/ota_password`

**1Password:** `iotstack_<role>_<secret-type>`
- Example: `iotstack_bleproxy_ota_password`

**Secret types:**
- `ota_password` — OTA flashing authentication
- `api_encryption_key` — API encryption (future use)

## Password Versioning

When rotating passwords, old versions are kept with suffixes:

```
bleproxy_ota_password_v0 = "firstPassword"
bleproxy_ota_password_v1 = "secondPassword"
bleproxy_ota_password = "thirdPassword"  # Current
```

In password manager (Bitwarden example):
- `iotstack/bleproxy/ota_password_v0`
- `iotstack/bleproxy/ota_password_v1`
- `iotstack/bleproxy/ota_password` (current)

This allows recovery if newer password is lost, and audit trail of rotations.

## Usage with iotstack

Once configured, you don't interact with password manager directly. Instead:

```bash
# Reassign device with custom OTA password
# (gets prompted or uses env var, no hardcoded secret visible)
iotstack reassign 11cdc4 bleproxy --api-key "kOKuNAPXcbSdYch5AJFtrcoZPr3RyljAkN5Yu9n9oA"

# Rotate password for entire role
iotstack rotate-password bleproxy "newPassword123"
# Old password kept as _v1, new is active
```

## Security Best Practices

1. **Never commit secrets.yaml** — add to `.gitignore` ✓ (already done)
2. **Use strong passwords** — 32+ characters, random
3. **Backup password manager** — especially for offline managers like pass/KeePassXC
4. **Rotate passwords periodically** — especially for production devices
5. **Use different passwords per role** — if one is compromised, others are safe
6. **Keep historical passwords secure** — needed for recovery, but should be in password manager only

## Troubleshooting

### Test command fails

```bash
# Check if password manager CLI is installed
which bw    # Bitwarden
which pass  # pass
which op    # 1Password
which keepassxc-cli  # KeePassXC

# Check config file
cat ~/.iotstack/config

# Verify credentials with password manager directly
bw login  # For Bitwarden
```

### "Unable to find secret" error

- Verify secret exists in password manager
- Check naming convention (spaces, underscores)
- Ensure config file points to correct vault
- Try retrieving secret manually with password manager CLI

### "Authentication failed" during OTA

This happens when you use the wrong OTA password. Use `--api-key` option:

```bash
iotstack reassign <mac> <role> --api-key "correct-password"
```

## See Also

- [Rotate Passwords](ROTATE-PASSWORDS.md)
- [Device Reassignment with Custom Keys](../README.md#reassign)
