# Rotating OTA Passwords

This guide explains how to rotate OTA passwords for device roles in iotstack.

## Why Rotate Passwords?

- **Security best practice** — periodically change credentials
- **Compliance** — meet security policies
- **Incident response** — if password is compromised
- **Team changes** — when team members leave
- **Secrets rotation** — automated or manual policies

## How Password Rotation Works

When you rotate a password for a role:

1. All devices in that role are flashed with new firmware
2. The new firmware contains the new OTA password
3. Old password is kept in password manager for recovery (versioned)
4. All historical passwords remain accessible for audit trail

**Key insight:** The new password is embedded in the firmware, so you need to authenticate OTA with the OLD password to deliver the NEW firmware.

## Usage

### Basic Usage

Prompt for new password:

```bash
iotstack rotate-password bleproxy
# Prompts: Enter new OTA password for 'bleproxy': 
```

Provide password directly:

```bash
iotstack rotate-password bleproxy "newPassword123"
```

## Workflow: Step-by-Step

### Step 1: Generate New Password

Create a strong 32+ character random password:

```bash
# Option A: openssl
openssl rand -base64 32

# Option B: pass generator
pwgen 32 1

# Option C: Just use a password manager to generate one
```

### Step 2: Rotate Password

```bash
iotstack rotate-password bleproxy "yourNewPassword123"
```

This will:

1. ✓ Discover all devices running `bleproxy` role
2. ✓ Get current OTA password from password manager
3. ✓ Flash all devices using old password, new firmware with new password
4. ✓ Create versioned entry in password manager: `bleproxy_ota_password_v<N>`
5. ✓ Update current password: `bleproxy_ota_password`
6. ✓ Report which devices succeeded/failed

### Step 3: Verify Rotation

```bash
# List devices with role - all should be online
iotstack list devices bleproxy

# Or verify they're responding
iotstack verify bleproxy
```

## Password Version History

When you rotate passwords, old versions are kept:

**Before rotation:**
```yaml
bleproxy_ota_password: "originalPassword123"
```

**After first rotation:**
```yaml
bleproxy_ota_password_v0: "originalPassword123"   # Historical
bleproxy_ota_password: "newPassword456"            # Current
```

**After second rotation:**
```yaml
bleproxy_ota_password_v0: "originalPassword123"   # Historical
bleproxy_ota_password_v1: "newPassword456"        # Historical
bleproxy_ota_password: "newestPassword789"        # Current
```

## Recovery: If Rotation Fails

If some devices fail to update during rotation:

### Option 1: Retry with current password

```bash
# All devices now have new firmware with new password
# Retry the ones that failed
iotstack reassign <failed-macs> bleproxy
```

### Option 2: Retry with old password

If devices still have old firmware:

```bash
# Get old password from password manager
# Use it to flash again
iotstack reassign <failed-macs> bleproxy --api-key "oldPassword123"
```

### Option 3: Reset to known state

If you lose track of which password devices are using:

```bash
# Get a historical version from password manager
bw item get "iotstack/bleproxy/ota_password_v0"

# Try the oldest known password
iotstack reassign <macs> bleproxy --api-key "veryOldPassword"
```

## Security Considerations

### Don't lose password history

**Never delete historical password versions.** Keep them in password manager:

```bash
# GOOD: Keep versioned history
iotstack/bleproxy/ota_password_v0  ← Keep this
iotstack/bleproxy/ota_password_v1  ← Keep this
iotstack/bleproxy/ota_password     ← Current

# BAD: Don't delete old versions
iotstack/bleproxy/ota_password     ← What version is on devices?
```

### Audit trail

All rotations are recorded in password manager with version numbers and timestamps. This provides:

- Who made the change (if using team password manager)
- When the change was made (version history)
- What the old value was (recovery)

### Separate passwords per role

Use different passwords for different roles. If bleproxy password is compromised, thread-router and other roles are still safe:

```
iotstack/bleproxy/ota_password
iotstack/mmwave/ota_password          ← Different!
iotstack/threadrouter/ota_password    ← Different!
```

## Troubleshooting

### "No devices found for role"

```bash
# Check if any devices are online with that role
iotstack list devices <role>

# If none show up, devices might be:
# - Offline (power cycling can help)
# - Running different firmware (manually reassign)
# - Network connectivity issues
```

### "Authentication failed" during rotation

The old password in password manager doesn't match what's on devices:

```bash
# Try manually with a different known password
iotstack reassign <macs> <role> --api-key "knownPassword"

# Once that works, update password manager and try rotation again
```

### "Rotation completed but some devices failed"

Check which ones failed:

```bash
# See which devices came back online
iotstack list devices <role>

# Retry the failed ones
iotstack reassign <failed-macs> <role>
# (Will use new password now, since they have new firmware)
```

## Automation & Policies

While `rotate-password` is currently manual, future enhancements could include:

- Scheduled rotation (e.g., monthly)
- Automated strong password generation
- Webhook integration for compliance systems
- Rotation policies per role (e.g., "change every 90 days")

## See Also

- [Password Manager Setup](PASSWORD-MANAGER-SETUP.md)
- [Device Reassignment](../README.md#reassign)
- [OTA Authentication](../README.md#ota-authentication)
