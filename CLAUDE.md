# ESP32 ESPHome Device Management — Development Notes

## Naming Convention

**Always use lowercase "iotstack"** — never "IoT Stack" or "iotStack". Examples:
- ✓ `iotstack update bleproxy`
- ✓ `iotstack list devices`
- ✗ ~~IoT Stack~~
- ✗ ~~iotStack~~
- ✗ ~~IOTSTACK~~

This applies in code comments, documentation, help text, and all user-facing messages.

## Overview

The `update_devices.sh` script is a batch OTA flash tool for managing multiple ESPHome devices discovered via mDNS. It supports device renaming, role reassignment, and Home Assistant entity ID recreation.

The `iotstack.sh` CLI tool provides a user-friendly wrapper around this script with device roles (defined in `iotstack-roles.conf`).

⚠️ **IMPORTANT: Development Process**
- When assisting with changes, changes are staged but NOT committed until the human has tested and approved them
- The human must verify functionality against actual devices before changes are committed to git
- This ensures all commits represent validated, working code
- See [Development Workflow](#development-workflow) section below for details

## Core Architecture

### Device Discovery
- Uses `avahi-browse -t -r _esphomelib._tcp` to discover devices on the network
- Devices must advertise `_esphomelib._tcp` service (native ESPHome)
- Extracts device names, config_hash, and project version from mDNS TXT records
- No HTTP calls needed — all discovery is via mDNS

### Build & Flash Strategy
- Compilation happens once serially (with SHA256 cache to skip unnecessary rebuilds)
- OTA flashing runs in parallel (default `--jobs 4`)
- Uses `wait -n` for slot-based job queuing
- Respects Thread device constraints: forces `--jobs 1` for Thread configs (Thread OTA is slow; parallelism causes mesh contention)

### YAML Configuration
- ESPHome devices are configured via YAML files in the `yamls/` directory
- Each device has a simple `name:` for mDNS discovery (e.g., `ble-proxy`, `thread-router`)
- MAC suffix is appended for device uniqueness

## Features

### 1. Subset Device Updating by MAC Suffix

Update only specific devices under a role instead of all devices:

```bash
# Update all bleproxy devices (default)
iotstack update bleproxy

# Update only specific devices by MAC suffix
iotstack update a1a7b0 8e1aa8 bleproxy

# Multiple MACs
iotstack update 135b60 1a7b00 1af95c threadrouter

# Works with all options
iotstack update a1a7b0 8e1aa8 bleproxy --dry-run
iotstack update a1a7b0 mmwave --force-reflash
```

**How it works:**
- MAC suffixes are 6-character hex strings (last 6 chars of MAC address)
- MACs come before the device name in command
- Only devices matching specified MACs are flashed
- All other update options (--dry-run, --force-reflash, etc.) work normally

### 2. Delta Updates (Default: On)
- Compares `config_hash` from device's mDNS TXT record vs. compiled firmware
- Only flashes devices with mismatched hashes
- `--no-upgrade-delta` forces flash all devices
- Fallback to `project_version` comparison if config_hash unavailable

### 2. Device Reassignment (`--reassign <MACs...> <target_yaml>`)
Flash a target configuration only to specific devices:

```bash
# Reassign specific devices to a different config
./update_devices.sh --reassign 19b164 199ef4 yamls/esp32c6-wifi-mmwave.yaml
```

**Arguments:**
- `<MACs...>`: One or more MAC suffixes (space-separated)
- `<target_yaml>`: Target YAML configuration file

**Behavior:**
- Discovers all devices on network, filters to specified MAC suffixes
- Flashes target configuration only to matched devices
- Updates Home Assistant entity IDs if HA integration is configured
- Warns if any requested MACs are offline

### 3. Home Assistant Integration
- Uses WebSocket API (NOT REST API — REST endpoints are internal, not public)
- Recreates entity IDs after reassignment to reflect new device configuration
- Filters updates to ESPHome platform only (`platform == 'esphome'`)
- Verifies entity ID consistency across all discovered devices
- Commands used:
  - `config/entity_registry/list` — get all entities
  - `config/entity_registry/get_automatic_entity_ids` — compute new IDs for given device_name
  - `config/entity_registry/update` — update entity ID
- Entity ID security: only updates entities with `platform == 'esphome'`, preventing accidental updates to beacon trackers, iBeacon integrations, etc.

## iotstack CLI Tool

### Overview
`iotstack.sh` is a user-friendly wrapper around `update_devices.sh`. It provides device roles (e.g., `iotstack update bleproxy`) instead of requiring full YAML paths (e.g., `./update_devices.sh wifi/esp32c6-wifi-bleproxy.yaml`).

Users run `setup.sh` once to add the `iotstack` alias to their `~/.bashrc`, making the command available globally.

### Device Mapping (iotstack-roles.conf)
Device shortcuts are defined in `iotstack-roles.conf`:
```
bleproxy=wifi/esp32c6-wifi-bleproxy.yaml:
mmwave=wifi/esp32c6-wifi-mmwave.yaml:
ledstrip=wifi/esp32s3-wifi-led-strip.yaml:
threadrouter=:thread/c6-thread-router.yaml
```

Format: `<shortcut>=<wifi-yaml>:<thread-yaml>`
- Left of colon: WiFi device role (required unless only Thread device role exists)
- Right of colon: Thread device role (optional, omit if no Thread version)

### Usage Examples
```bash
# Update WiFi variant (default)
iotstack update bleproxy

# Update Thread device role
iotstack update threadrouter

# Update all devices
iotstack update all

# Reassign devices to different config (simple flash)
iotstack reassign 8dfcac 0f4df4 to mmwave

# List available shortcuts
iotstack list shortcuts

# Show detailed help
iotstack help
iotstack help update
iotstack help reassign
```

### Implementation Details
- `iotstack.sh` loads the device map from `iotstack-roles.conf`
- User can pass either a device role or a direct YAML path
- Internally calls `update_devices.sh` with resolved YAML paths
- All underlying features (reassign, verify, etc.) work the same way

## Important Implementation Details

### Stdout/Stderr Redirection Issue
⚠️ **Critical for User Interaction**

The script redirects stdout to a log file:
```bash
exec > >(tee -a "$COMPILE_LOG_FILE") 2>&1
```

This breaks user prompts (`read -p`):
- Prompt goes to log file instead of terminal
- User can't see it and script appears to hang
- Input from stdin is lost

**Solution:** When you need user input AFTER the logging redirect:
```bash
# Write prompt/messages to stderr (bypasses stdout redirect)
echo "Continue?" >&2

# Read from terminal directly, not from stdin
read -p "Continue? (y/n) " -n 1 -r </dev/tty

# Confirm response to stderr
echo >&2
```

This is used in the `--reassign` offline device warning and the websocket client installation prompt.

### Temporary File Handling
- Temp YAML files go to `~/.iotstack/artifacts/` (not cluttering the repo)
- Single source of truth: `secrets.yaml` lives in `yamls/` directory
- ESPHome YAML files automatically find `secrets.yaml` in the same directory
- Temp files are cleaned up on script exit via `trap` handler
- Pattern: `.temp-reassign-<PID>.yaml` is gitignored

### Project.name Regex Handling
The `project.name` field in YAML can be quoted or unquoted:
```yaml
project:
  name: "farscapian.${device_name}"    # quoted
  # or
  name: farscapian.${device_name}      # unquoted
```

The regex must handle both:
```bash
r'(name:\s+["\']?)([^"\'\n]*)\$\{device_name\}([^"\'\n]*["\']?)'
```
- `["\']?` matches optional quote (start)
- `[^"\'\n]*` matches characters (no quotes, no newlines)
- `["\']?` matches optional quote (end)

### Logging Strategy
- Compilation output goes to: `~/.iotstack/logs/<device>/<timestamp>.compile.log`
- Flash logs per device: `~/.iotstack/logs/<device>/<timestamp>-<hash>/`
- Build cache: `~/.iotstack/logs/<device>.build.cache` (SHA256 + version)
- Cache invalidated if YAML or ESPHome version changes

## Common Pitfalls & Solutions

| Issue | Root Cause | Solution |
|-------|-----------|----------|
| Prompt doesn't appear, script hangs | User input code runs after stdout redirect | Use `>&2` for messages, `</dev/tty` for input |
| `grep: invalid option -- '$'` | Pattern starts with dash (e.g., `-19b164$`) | Use `grep -- ` to stop option processing |
| ESPHome can't find secrets.yaml | secrets.yaml not in yamls/ directory | Ensure secrets.yaml exists in yamls/ where YAML configs live |
| Device discovery finds wrong devices | Filtering by device_name in reassign mode | In reassign mode, discover ALL then filter by MAC suffix |
| Entity updates affect wrong integrations | Not checking platform field | Always filter: `if platform != 'esphome': continue` |

## Device Types

### WiFi BLE Proxy
- YAML: `yamls/esp32c6-wifi-bleproxy.yaml`
- mDNS Name: `ble-proxy`
- Board: ESP32-C6
- Example mDNS advertised name: `ble-proxy-19b164` (name-MAC suffix)

### Thread Router
- YAML: `yamls/esp32c6-thread-threadrouter.yaml`
- mDNS Name: `thread-router`
- Board: ESP32-C6
- Network: Thread (IPv6)
- Special handling: forces `--jobs 1` (Thread OTA is slow; parallelism causes mesh contention)
- Example mDNS advertised name: `thread-router-135b60` (name-MAC suffix)

### WiFi mmWave
- YAML: `yamls/esp32c6-wifi-mmwave.yaml`
- mDNS Name: `mmwave`
- Supports device reassignment via `--reassign`

## Development Workflow

⚠️ **CRITICAL: Git Operations Only After Human Testing**

All code changes should be staged and ready, but **git commits and pushes must ONLY occur after the human has**:
1. **Tested the changes** against actual devices (not just compilation)
2. **Verified functionality** works as expected
3. **Evaluated the implementation** for correctness and quality
4. **Explicitly approved** the changes for commit

**Workflow:**
1. Make code changes
2. Stage changes (git add)
3. **Wait for human approval** — do not commit yet
4. **After human testing and approval**, create commit with appropriate message
5. **Only push to remote** after commit succeeds

This ensures that all commits represent validated, tested, working changes — not experimental code that may need revision.

## Secrets Management: Seeding Pattern

**secrets.yaml is ONLY for seeding the pass store, not for operational values.**

Architecture:
- **secrets.yaml**: Initial seed with well-known defaults (e.g., `CHANGE_ME`)
- **pass store**: Encrypted operational source of truth (versioned, secure)
- **iotstack startup**: Auto-seeds pass from secrets.yaml (only if pass doesn't have key yet)

Precedence: If pass has a value, secrets.yaml is ignored
```
secrets.yaml value        →  pass (first run, if pass is empty)
                          ↓
                        pass value (all subsequent runs)
```

User updates secrets via `iotstack secret set <role> <ota|api> <value>`, which updates pass (not secrets.yaml).

This allows secrets.yaml to be checked into git with safe defaults while protecting actual secrets in encrypted pass store.

## 🚨 CRITICAL: Never Print Passwords or Secrets to Console

**Rule: NEVER echo passwords, API keys, or secrets to stdout/stderr**

Passwords printed to console can be captured in:
- Shell history (`~/.bash_history`, `~/.zsh_history`)
- Log files (CI logs, audit logs, syslog)
- Terminal session recordings
- Process monitoring tools (`ps`, `top`)
- Script output redirections

**Correct pattern:** Use environment variables and avoid console output

```bash
# ✓ CORRECT - password in env var, not printed
export OTA_PWD="actual_password"
iotstack update bleproxy --ota-password "$OTA_PWD"
unset OTA_PWD

# ✗ WRONG - password printed to console
iotstack update bleproxy --ota-password "actual_password"

# ✗ WRONG - password in command line (visible in ps, history)
iotstack update bleproxy --ota-password "myPassword123"
```

**In code:**
- ✓ Output: `echo "[OK] OTA password updated (provided)"`
- ✗ Output: `echo "[OK] OTA password: $password"`
- ✓ Output: `echo "[OK] Generated cryptographically secure password"`
- ✗ Output: `echo "[OK] Generated password: $new_password"`

## 🚨 CRITICAL: Pass Password Handling

**When using `pass insert` to store secrets, ALWAYS echo the password TWICE** (for confirmation):

```bash
# ✓ CORRECT - password echoed twice
{ echo "$password"; echo "$password"; } | pass insert -f "iotstack/roles/bleproxy/ota_password"

# ✗ WRONG - password only echoed once (WILL FAIL SILENTLY)
echo "$password" | pass insert -f "iotstack/roles/bleproxy/ota_password"
```

**Why:** `pass insert` requires the password to be entered twice (for confirmation), just like interactive password entry. If only provided once, the insert fails silently with exit code 1, causing:
- Secret never gets stored in pass
- Subsequent script runs see it as "missing" and try to sync again
- Results in repeated warnings and failed secret syncing

**This applies to:**
- `setup.sh` — initial secret seeding
- `iotstack-secrets` — manual secret updates
- `scripts/ha-websocket-query.sh` — syncing secrets from YAML
- Any script that uses `pass insert`

**Impact of getting this wrong:**
- Silent failures (no visible error message)
- Repeated warning messages on every invocation
- Hours of debugging to figure out why secrets won't sync
- Wasted time investigating pass store, permissions, etc.

## Testing Checklist

Before requesting human approval:
- Run actual flashing against devices (not just compilation)
- Verify Home Assistant entities are updated correctly
- Test edge cases (offline devices, mismatched MAC suffixes, etc.)
- Check that logs are written to correct locations
- Verify that prompts appear and accept user input correctly
- Verify all new features work as documented
- Check for any regressions in existing functionality

## References

- mDNS discovery: `avahi-browse(1)` man page
- ESPHome YAML: https://esphome.io (substitutions, name_add_mac_suffix)
- Home Assistant WebSocket API: `config/entity_registry/*` commands
- Script memory: See `/home/derek/.claude/projects/.../memory/` for architecture notes
