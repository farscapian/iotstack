# Quick Start: Password Manager Setup

Get up and running with password manager integration in 5 minutes.

## 1. Choose Your Password Manager

```bash
# Bitwarden (recommended for teams)
npm install -g @bitwarden/cli
bw login your-email@example.com

# OR: pass (simple, local)
brew install pass  # macOS
apt install pass   # Linux
pass init your-gpg-key

# OR: 1Password
brew install 1password-cli  # macOS
op account add --shorthand myaccount
```

## 2. Create Configuration

```bash
mkdir -p ~/.iotstack
cp .iotstack-config-template ~/.iotstack/config
nano ~/.iotstack/config  # Edit to select your provider
```

Example for Bitwarden:

```ini
[password-manager]
provider = bitwarden

[bitwarden]
vault = iotstack
```

## 3. Test It

```bash
# Add a test secret to your password manager
# Bitwarden: Create entry "iotstack/test/secret" with password "testvalue123"
# pass: pass insert iotstack/test/secret (type "testvalue123")

# Retrieve it
./iotstack-secrets get test secret
# Should print: testvalue123
```

## 4. Add Your Device Passwords

For each device role (bleproxy, mmwave, etc.), add secrets:

```bash
# Bitwarden: Create entries
# iotstack/bleproxy/ota_password
# iotstack/mmwave/ota_password
# iotstack/threadrouter/ota_password

# pass: Add entries
pass insert iotstack/bleproxy/ota_password
pass insert iotstack/mmwave/ota_password
pass insert iotstack/threadrouter/ota_password
```

## 5. Use with iotstack

Now you can use OTA passwords without hardcoding them:

```bash
# Reassign device with authentication
# (you provide the password, we handle the rest)
iotstack reassign 11cdc4 bleproxy --api-key "your-ota-password"

# Rotate password for a role
iotstack rotate-password bleproxy "newPassword123"
```

## Done!

Your secrets are now:
- ✓ Not in git (secrets.yaml is gitignored)
- ✓ Not visible in your editor (stored in password manager)
- ✓ Audited and versioned (password manager history)
- ✓ Securely backed up (password manager backup)

## Next Steps

- Read [PASSWORD-MANAGER-SETUP.md](PASSWORD-MANAGER-SETUP.md) for detailed setup per manager
- Read [ROTATE-PASSWORDS.md](ROTATE-PASSWORDS.md) for rotation procedures
- Try reassigning a device: `iotstack reassign <mac> <role> --api-key "password"`

## Troubleshooting

```bash
# Test password manager is working
./iotstack-secrets get bleproxy ota_password
# Should print your password without errors

# If fails, check:
# 1. Password manager CLI is installed
# 2. Config file exists and has correct provider
# 3. Secret exists in password manager with correct name
# 4. Authentication/login status with password manager
```

## See Also

- Full password manager guide: [PASSWORD-MANAGER-SETUP.md](PASSWORD-MANAGER-SETUP.md)
- CLI tool documentation: `./iotstack-secrets --help`
