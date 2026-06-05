# ESP32 ESPHome Device Management — Development Notes

## Overview

The `update_devices.sh` script is a batch OTA flash tool for managing multiple ESPHome devices discovered via mDNS. It supports device renaming, role reassignment, and Home Assistant entity ID recreation.

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

### YAML Substitution Handling
- Script parses the `substitutions:` block into a bash associative array
- Resolves `${var}` references in: friendly_name, project name/version
- **Role-based stable UUIDs**: Script extracts `role:` substitution and computes role_id via MD5 truncation:
  ```bash
  role_name="esp32c6-wifi-bleproxy"  # Read from YAML, not injected
  role_id=$(echo -n "$role_name" | md5sum | cut -c1-18)
  # Result: f9ae844f309077c78b
  ```
- Only `role_id` is injected at compile time via `-s` flag (computed on the fly):
  ```bash
  esphome compile <yaml> -s role_id "f9ae844f309077c78b"
  ```
- Example YAML:
  ```yaml
  substitutions:
    role_name: "esp32c6-wifi-bleproxy"  # Stays in YAML, not overridden
    role_id: "f9ae844f309077c78b"        # Default value, overridden by -s at compile time
    friendly_name: "WiFi BLEProxy"
  esphome:
    name: ${role_id}                      # Device announces as: role_id-MAC
    name_add_mac_suffix: true
  ```

## Features

### 1. Delta Updates (Default: On)
- Compares `config_hash` from device's mDNS TXT record vs. compiled firmware
- Only flashes devices with mismatched hashes
- `--no-upgrade-delta` forces flash all devices
- Fallback to `project_version` comparison if config_hash unavailable

### 2. Device Reassignment & Renaming (`--reassign <MACs...> --rename-from <old_role> <target_yaml>`)
Unified two-step process for moving devices between roles or renaming within a role:

```bash
# Move devices to a different role
./update_devices.sh --reassign 19b164 199ef4 --rename-from esp32c6-wifi-bleproxy ./wifi/esp32c6-wifi-mmwave.yaml

# Rename devices within same role
./update_devices.sh --reassign 8dfcac 0f4df4 --rename-from esp32c6-wifi-bleproxy ./wifi/esp32c6-wifi-bleproxy.yaml
```

**Arguments:**
- `<MACs...>`: One or more MAC suffixes (space-separated)
- `--rename-from <old_role>`: Current role name (for two-step process)
- `<target_yaml>`: Target YAML file

**Two-step process:**
1. **Step 1: Introduce device_new_name**
   - Creates temp YAML with `device_new_name` injected (from target YAML's `role_name`)
   - Updates `project.name` to use `${device_new_name}` instead of `${device_name}`
   - Flashes specified devices with temp YAML
   - Devices don't change their advertised mDNS name yet

2. **Step 2: Apply final state**
   - Compiles and flashes target YAML (final, permanent config)
   - Devices now report new name in mDNS (with MAC suffix if `name_add_mac_suffix: true`)
   - Updates Home Assistant entity IDs automatically

**Behavior:**
- Discovers ALL devices on network, filters to specified MACs only
- Warns if any requested MACs are offline
- Role_id remains stable throughout reassignment, preserving Home Assistant entity IDs

### 4. Home Assistant Integration
- Uses WebSocket API (NOT REST API — REST endpoints are internal, not public)
- Recreates entity IDs after device rename to reflect new device_name
- Filters updates to ESPHome platform only (`platform == 'esphome'`)
- Verifies entity ID consistency across all discovered devices
- Commands used:
  - `config/entity_registry/list` — get all entities
  - `config/entity_registry/get_automatic_entity_ids` — compute new IDs for given device_name
  - `config/entity_registry/update` — update entity ID

### 5. Entity ID Security
- Only updates entities with `platform == 'esphome'`
- Prevents accidental updates to beacon trackers, iBeacon integrations, etc.
- Validates consistency before flashing

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
- Temp YAML files go to `.esphome/artifacts/` (not cluttering the repo)
- `secrets.yaml` is copied to artifacts directory so ESPHome can find it
- Dangling symlinks are removed before copying: `rm -f .esphome/artifacts/secrets.yaml`
- Temp files are cleaned up on script exit via `trap` handler
- Pattern: `.temp-reassign-<PID>.yaml` is gitignored
- `secrets.yaml` copy is deleted after script completion to avoid accumulation

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
- Compilation output goes to: `.ancapistan/esphome/logs/<device>/<timestamp>.compile.log`
- Flash logs per device: `.ancapistan/esphome/logs/<device>/<timestamp>-<hash>/`
- Build cache: `.ancapistan/esphome/logs/<device>.build.cache` (SHA256 + version)
- Cache invalidated if YAML or ESPHome version changes

## Common Pitfalls & Solutions

| Issue | Root Cause | Solution |
|-------|-----------|----------|
| Prompt doesn't appear, script hangs | User input code runs after stdout redirect | Use `>&2` for messages, `</dev/tty` for input |
| `grep: invalid option -- '$'` | Pattern starts with dash (e.g., `-19b164$`) | Use `grep -- ` to stop option processing |
| Config not found in temp YAML | Secrets file missing from artifacts | Copy secrets.yaml before compile: `cp secrets.yaml .esphome/artifacts/secrets.yaml` |
| Device discovery finds wrong devices | Filtering by device_name in reassign mode | In reassign mode, discover ALL then filter by MAC suffix |
| Entity updates affect wrong integrations | Not checking platform field | Always filter: `if platform != 'esphome': continue` |

## Device Types

### WiFi BLE Proxy
- YAML: `wifi/c6-wifi-bleproxy.yaml`
- Role: `esp32c6-wifi-bleproxy`
- Role ID: `f9ae844f309077c78b` (computed from MD5)
- Project: `farscapian.WiFi BLEProxy`
- Board: ESP32-C6
- Example mDNS: `f9ae844f309077c78b-19b164` (role_id-MAC suffix)

### Thread Router
- YAML: `thread/c6-thread-router.yaml`
- Role: `c6-thread-router`
- Role ID: `6b671191303c9a2979` (computed from MD5)
- Project: `farscapian.Thread Router`
- Board: ESP32-C6
- Network: Thread (IPv6)
- Force `--jobs 1` (Thread OTA is slow)
- Example mDNS: `6b671191303c9a2979-135b60` (role_id-MAC suffix)

### WiFi mmWave (Multi-Purpose)
- YAML: `wifi/esp32c6-wifi-mmwave.yaml`
- Role: `esp32c6-wifi-mmwave`
- Role ID: `a44bb2f755825e3280` (computed from MD5)
- Supports reassignment and renaming via `--reassign --rename-from`
- Role ID remains stable across reassignments (preserves HA entity IDs)

## Testing Checklist

Before considering changes "done":
- Run actual flashing against devices (not just compilation)
- Verify Home Assistant entities are updated correctly
- Test edge cases (offline devices, mismatched MAC suffixes, etc.)
- Check that logs are written to correct locations
- Verify that prompts appear and accept user input correctly

## References

- mDNS discovery: `avahi-browse(1)` man page
- ESPHome YAML: https://esphome.io (substitutions, name_add_mac_suffix)
- Home Assistant WebSocket API: `config/entity_registry/*` commands
- Script memory: See `/home/derek/.claude/projects/.../memory/` for architecture notes
