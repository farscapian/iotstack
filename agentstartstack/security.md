# Security

## CRITICAL: Never print passwords or secrets

**Rule: NEVER echo passwords, API keys, or secrets to stdout/stderr**

Passwords printed to console can be captured in:
- Shell history (`~/.bash_history`, `~/.zsh_history`)
- Log files (CI logs, audit logs, syslog)
- Terminal session recordings
- Process monitoring tools (`ps`, `top`)
- Script output redirections

**Correct pattern:** Use environment variables and avoid console output

```bash
# [OK] CORRECT - password in env var, not printed
export OTA_PWD="actual_password"
iotstack update bleproxy --ota-password "$OTA_PWD"
unset OTA_PWD

# [FAIL] WRONG - password printed to console
iotstack update bleproxy --ota-password "actual_password"

# [FAIL] WRONG - password in command line (visible in ps, history)
iotstack update bleproxy --ota-password "myPassword123"
```

**In code:**
- [OK] Output: `echo "[OK] OTA password updated (provided)"`
- [FAIL] Output: `echo "[OK] OTA password: $password"`
- [OK] Output: `echo "[OK] Generated cryptographically secure password"`
- [FAIL] Output: `echo "[OK] Generated password: $new_password"`

## CRITICAL: Pass password handling

**When using `pass insert` to store secrets, ALWAYS echo the password TWICE** (for confirmation):

```bash
# [OK] CORRECT - password echoed twice
{ echo "$password"; echo "$password"; } | pass insert -f "iotstack/roles/bleproxy/ota_password"

# [FAIL] WRONG - password only echoed once (WILL FAIL SILENTLY)
echo "$password" | pass insert -f "iotstack/roles/bleproxy/ota_password"
```

**Why:** `pass insert` requires the password to be entered twice (for confirmation), just like interactive password entry. If only provided once, the insert fails silently with exit code 1, causing:
- Secret never gets stored in pass
- Subsequent script runs see it as "missing" and try to sync again
- Results in repeated warnings and failed secret syncing

**This applies to:**
- `setup.sh` -- initial secret seeding
- `scripts/iotstack-secrets` -- manual secret updates
- `scripts/ha-websocket-query.sh` -- syncing secrets from YAML
- Any script that uses `pass insert`

**Impact of getting this wrong:**
- Silent failures (no visible error message)
- Repeated warning messages on every invocation
- Hours of debugging to figure out why secrets won't sync
- Wasted time investigating pass store, permissions, etc.
