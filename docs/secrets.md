# Secrets Management in iotstack

iotstack uses a multi-layered architecture to keep credentials secure without compiling them into firmware binaries.

## Overview

Sensitive information (WiFi passwords, API keys, OTA passwords) is managed through:

1. **Encrypted Pass Store** (`~/.iotstack/.pass/`)
   - Role-based secrets stored encrypted at rest
   - Never written unencrypted to disk

2. **Device-Specific Derivation** (at flash time)
   - Each device gets a unique secret: `sha256(role_secret | device_mac)`
   - Computed in-memory, never stored on disk

3. **NVS Partition** (on device flash)
   - Device-specific secrets written to flash after firmware flash
   - Persists across firmware updates
   - Read at device startup by custom components

4. **Runtime Loading** (device startup)
   - Custom ESPHome components read NVS at boot
   - No hardcoded secrets in compiled firmware binary

## Architecture Layers

### Layer 1: Role-Based Secrets (Encrypted Pass Store)

Each device role (bleproxy, threadrouter, mmwave, etc.) has a master secret stored in the encrypted pass store:

```
~/.iotstack/.pass/
`--- iotstack/
    `--- roles/
        |--- bleproxy/
        |   `--- ota_password
        |--- threadrouter/
        |   `--- ota_password
        `--- mmwave/
            `--- ota_password
```

These master secrets are:
- Encrypted with your GPG key
- Stored locally in the pass store
- Never written unencrypted to disk
- Used to derive device-specific secrets at flash time

### Layer 2: Device-Specific Derivation

When you flash a device, iotstack derives a unique secret for that device:

```
Device-specific secret = sha256(role_secret | device_mac)

Example:
  Role secret: "9273bd66b82ddd6e93a38cb513b3a409" (from pass store)
  Device MAC: "58:e6:c5:13:72:84"
  
  Device secret = sha256("9273bd66b82ddd6e93a38cb513b3a409|137284")
                = "346b5d0cd072a11c68ba6eb5be55ab44"
```

This ensures:
- Each device has a unique password/key
- Even if one device is compromised, others remain secure
- The secret is only computed at flash time, never stored on disk

### Layer 3: NVS Partition (Device Flash)

After flashing firmware, iotstack writes the device-specific secrets to the device's NVS (Non-Volatile Storage) partition:

```
Device Flash Memory (4MB)
|--- Bootloader (32KB)
|--- NVS Partition (16KB) <- Device-specific secrets stored here
|   |--- ota_password: "346b5d0cd072a11c68ba6eb5be55ab44"
|   |--- api_key: "a1b2c3d4e5f6..." (derived)
|   `--- wifi credentials (if configured)
|--- Recovery Firmware (1.5MB)
`--- Production Firmware (2.25MB)
```

The NVS data:
- Persists across firmware updates
- Is read at device startup
- Is plaintext on flash (see "Security Model" below)

### Layer 4: Runtime Loading

Custom ESPHome components read from NVS at device startup:

```cpp
// nvs_ota_password component reads NVS at startup
nvs_open(NULL, NVS_READONLY, &handle);
nvs_get_str(handle, "ota_password", buffer, size);
ota_service.set_password(buffer);  // Dynamic OTA authentication

// nvs_secrets component reads WiFi/API credentials
nvs_get_str(handle, "wifi_ssid", ssid_buffer, size);
nvs_get_str(handle, "api_key", key_buffer, size);
```

Result: **Firmware binary contains no secrets** -- all come from NVS at runtime.

## Setup

### Initial Configuration (setup.sh)

When you run `./setup.sh`:

1. Creates GPG key in `~/.iotstack/.gnupg/`
2. Initializes pass store at `~/.iotstack/.pass/`
3. Creates default environment file at `~/.iotstack/.env`
4. Seeds common configuration items (WiFi SSID, Home Assistant URL, etc.)

### Creating Role Secrets

When you first flash a device, iotstack will:

1. Check if a role secret exists in pass
2. If not, prompt you to create one
3. Store it encrypted in the pass store
4. Use it to derive device-specific secrets

You can also manually create a role secret:

```bash
# Generate a strong random secret
openssl rand -hex 16 | tr -d '\n'

# Store it in pass (enter it twice for confirmation)
pass insert iotstack/roles/bleproxy/ota_password
```

### Home Assistant Integration

To enable automatic entity ID updates after device reassignment:

```bash
# Get your Home Assistant long-lived token:
# Settings -> Developer Tools -> Long-Lived Access Tokens -> Create Token

# Store it in pass
pass insert iotstack/common/ha_token
pass insert iotstack/common/ha_url  # e.g., http://homeassistant.local:8123
```

## Security Model

### What's Protected

[OK] **Firmware binary extraction** -> No secrets in compiled code
[OK] **Device password reuse** -> Each device has unique derived secret
[OK] **Pass store compromise** -> Still need device MAC to derive secrets
[OK] **Secrets at rest** -> Encrypted in pass store
[OK] **Secrets in transit** -> Unique per-device secrets, not shared

### What's NOT Protected

[WARN] **Physical flash chip extraction** -> NVS data is plaintext on flash
[WARN] **Device physical access** -> Someone with the device can read NVS
[WARN] **Role secret compromise** -> If role secret is leaked, all future devices of that role are compromised (old devices are unaffected)

### Production Hardening

For production deployments, consider:

1. **Flash Encryption** (eFuses)
   - Encrypts NVS partition with device-unique eFuse key
   - Read-protected at hardware level
   - Requires recompilation with encryption enabled

2. **Secure Boot** (eFuses)
   - Verifies firmware signatures before boot
   - Prevents unsigned firmware from running

3. **Unique per-device Role Secrets**
   - Instead of one secret per role, generate unique secrets per device
   - Store in pass with device MAC in the path
   - Slightly more management overhead but maximum security

See [CLAUDE.md -> Flash Encryption & eFuses](../CLAUDE.md#flash-encryption--efuses---production-enhancement-todo) for implementation details.

## Troubleshooting

### "OTA password not found in pass" errors

This means the role secret doesn't exist yet. Create it:

```bash
# Generate and store a new secret
openssl rand -hex 16 | (read pwd; echo "$pwd"; echo "$pwd") | pass insert iotstack/roles/<role>/ota_password
```

### "Failed to write NVS partition"

Check that:
1. Device is connected via USB
2. Serial port permissions allow write (usually automatic)
3. Device isn't in use by another process (check `lsof /dev/ttyACM*`)

### "NVS key not found" on device

If the device logs show NVS keys aren't found:

1. Verify `write-nvs-secrets.sh` completed without errors
2. Check device logs: `iotstack logs bleproxy --device <device_name>`
3. Re-flash the device with `iotstack flash`

## Advanced: Manual Secret Operations

### Viewing pass store structure

```bash
# List all stored secrets
pass iotstack/

# View a specific secret (requires password)
pass show iotstack/roles/bleproxy/ota_password
```

### Rotating Secrets

To rotate all role secrets:

```bash
iotstack rotate-secrets bleproxy
```

This:
1. Generates a new role secret
2. Stores it in pass (with version tracking)
3. On next flash, all devices of that role get the new secret
4. Previous secrets are archived for recovery

### Manual NVS Writing

To manually write NVS to a device (advanced):

```bash
# Write NVS without flashing firmware
scripts/write-nvs-secrets.sh /dev/ttyACM0 137284 bleproxy <ota_password>
```

Where:
- `/dev/ttyACM0` is your serial device
- `137284` is the device MAC suffix
- `bleproxy` is the device role
- `<ota_password>` is the device-specific OTA password (or omit to prompt)
