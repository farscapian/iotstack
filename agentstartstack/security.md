# Security (iotstack-specific)

> Generic rules (never echo secrets, env hygiene): see `.agentstartstack/agentstartstack/security.md`.

## OTA password handling

```bash
# OK: password in env var, not printed
export OTA_PWD="actual_password"
iotstack update bleproxy --ota-password "$OTA_PWD"
unset OTA_PWD

# FAIL: password on command line or echoed
iotstack update bleproxy --ota-password "actual_password"
echo "[OK] OTA password: $password"
```

## Pass password handling

**When using `pass insert` to store secrets, ALWAYS echo the password TWICE** (for confirmation):

```bash
# OK: password echoed twice
{ echo "$password"; echo "$password"; } | pass insert -f "iotstack/roles/bleproxy/ota_password"

# FAIL: password only echoed once (WILL FAIL SILENTLY)
echo "$password" | pass insert -f "iotstack/roles/bleproxy/ota_password"
```

**Why:** `pass insert` requires confirmation like interactive entry. Single echo fails silently (exit 1).

**Applies to:** `setup.sh`, `scripts/iotstack-secrets`, `scripts/ha-websocket-query.sh`, and any script using `pass insert`.