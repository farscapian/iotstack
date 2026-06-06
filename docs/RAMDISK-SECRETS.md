# RAM-Only Secrets (tmpfs)

Keep `secrets.yaml` in memory only — never unencrypted on disk.

## Why RAM-Only?

- **No unencrypted disk writes** — secrets exist only in RAM
- **Automatic erasure** — all data wiped on reboot or unmount
- **Still encrypted** — master secrets stay in pass (encrypted on disk)
- **Performance** — RAM access is faster than disk
- **Audit trail** — pass maintains a permanent encrypted record

## How It Works

1. **mount-secrets** creates a tmpfs mount at `~/.iotstack/secrets`
2. Decrypts all secrets from pass into tmpfs
3. ESPHome reads secrets.yaml from RAM
4. On reboot or `unmount-secrets`, everything is erased
5. On next run, just mount again to regenerate

## Usage

### First Time Setup

```bash
# Run setup (creates pass repository with encrypted secrets)
./setup.sh

# Mount secrets into RAM
./scripts/mount-secrets
# Will prompt for sudo (needed for tmpfs mount)
# Creates ~/.iotstack/secrets with secrets.yaml

# Now you can use iotstack
iotstack update bleproxy
iotstack rotate-password mmwave "newPassword"
```

### Daily Usage

```bash
# Mount secrets at start of session
./scripts/mount-secrets

# Use iotstack normally
iotstack list devices
iotstack reassign 11cdc4 bleproxy

# When done (optional — data erased on reboot anyway)
./scripts/unmount-secrets
```

## Technical Details

### tmpfs Mount

- **Location**: `~/.iotstack/secrets`
- **Size**: 16MB (plenty for all secrets)
- **Type**: tmpfs (RAM-backed, no swap)
- **Mount point**: created by `mount-secrets`

### secrets.yaml Generation

On each mount, the script:

1. Checks if tmpfs is already mounted (skip if yes)
2. Mounts tmpfs at `~/.iotstack/secrets`
3. Decrypts all secrets from pass using `pass show`
4. Writes to `~/.iotstack/secrets/secrets.yaml` (RAM only)
5. Sets permissions to `600` (user read-write only)

### Directory Structure

```
~/.iotstack/
├── .pass/                    # Encrypted pass database (on disk)
│   ├── .git/               # Git repo for pass history
│   ├── .gpg-id
│   └── iotstack/
│       └── <role>/
│           ├── api_encryption_key
│           └── ota_password
└── secrets/                 # tmpfs mount (RAM only)
    └── secrets.yaml         # Generated on each mount
```

After reboot or `unmount-secrets`, the RAM is erased but pass data remains encrypted on disk.

## Security Notes

### What's Encrypted (stays on disk)
- All secrets in `~/.iotstack/.pass/` (GPG encrypted)
- Pass uses your system GPG key for encryption
- Master secrets safe even if disk is compromised

### What's Not Encrypted (but memory-only)
- `secrets.yaml` in tmpfs — exists only in RAM
- Only decrypted while tmpfs is mounted
- Automatically erased on unmount/reboot
- Never written to disk in plaintext

### Best Practices

1. **Mount only when needed**
   ```bash
   # Mount for a session
   ./scripts/mount-secrets
   # Do your work
   # Unmount when done
   ./scripts/unmount-secrets
   ```

2. **Automate if desired** — add to `.bashrc`:
   ```bash
   alias iotstack-work='./scripts/mount-secrets && echo "Secrets mounted"'
   ```

3. **Verify unmount** — check no secrets left:
   ```bash
   # Should show nothing or empty
   ls -la ~/.iotstack/secrets/
   ```

4. **Check mount status**
   ```bash
   mount | grep "\.iotstack/secrets"
   # If mounted, will show: tmpfs on /path/to/.iotstack/secrets
   ```

## Troubleshooting

### "Permission denied" when mounting

```bash
# mount-secrets uses sudo for tmpfs. If password required:
sudo mount -t tmpfs -o size=16M tmpfs ~/.iotstack/secrets
```

### secrets.yaml not found

Make sure tmpfs is mounted before using iotstack:

```bash
./scripts/mount-secrets
mount | grep secrets  # Verify it mounted
ls ~/.iotstack/secrets/secrets.yaml  # Should exist
```

### tmpfs already mounted

Just use it — no need to remount:

```bash
./scripts/mount-secrets
# [WARN] Secrets tmpfs already mounted at ~/.iotstack/secrets
# Script exits safely, tmpfs still available
```

### Secrets incorrect after rotate-password

After rotating, unmount and remount to refresh:

```bash
./scripts/unmount-secrets
./scripts/mount-secrets
```

The new password is now in RAM.

## Performance Impact

- **Mount time**: ~100ms (depends on number of secrets)
- **tmpfs access**: ~1µs (nanoseconds, orders faster than disk)
- **Memory usage**: ~1MB (very minimal)

## Comparison: tmpfs vs Disk

| Aspect | tmpfs (RAM) | Disk |
|--------|-----------|------|
| Encryption | Memory-only decryption | Encrypted in pass |
| Persistence | Lost on reboot | Permanent |
| Speed | Nanosecond access | Millisecond access |
| Audit trail | Only in pass history | Only in pass history |
| Security | No unencrypted disk writes | Encrypted at rest |

## See Also

- [Password Manager Setup](PASSWORD-MANAGER-SETUP.md)
- [Rotate Passwords](ROTATE-PASSWORDS.md)
