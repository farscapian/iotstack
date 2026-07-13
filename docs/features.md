# Features


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
```

**How it works:**
- MAC suffixes are 6-character hex strings (last 6 chars of MAC address)
- MACs come before the device name in command
- Only devices matching specified MACs are flashed
- Production updates run **via bootstrap** (`_update_via_bootstrap`) so OTA never overwrites the bootstrap partition

### 2. Delta Updates (Default: On)
- **Primary comparison:** `config_hash` from device mDNS TXT vs. compiled build
- Only flashes devices with mismatched hashes (`--upgrade-delta`, default in `update_devices.sh`)
- Fallback to `project_version` comparison if `config_hash` unavailable in mDNS
- **`--erase` is not a valid `iotstack update` flag** -- it is USB-only and belongs to `iotstack flash` only


### 3. Device Reassignment (`iotstack reassign` / `--reassign`)
Flash a target configuration only to specific devices (always via bootstrap OTA):

```bash
# Reassign specific devices to a different role
iotstack reassign 19b164 199ef4 mmwave

# Or call update_devices.sh directly
scripts/update_devices.sh --reassign 19b164 199ef4 yamls/mmwave.yaml
```

**Arguments:**
- `<MACs...>`: One or more MAC suffixes (space-separated)
- `<target_yaml>`: Target YAML configuration file

**Behavior:**
- Discovers all devices on network, filters to specified MAC suffixes
- Flashes target configuration only to matched devices
- Updates Home Assistant entity IDs if HA integration is configured
- Warns if any requested MACs are offline

### 4. Verify (`iotstack verify`)
Compile (or cache-hit) and compare each device's runtime `config_hash` against the build -- no flashing:

```bash
iotstack verify bleproxy
iotstack verify all
```

Uses `update_devices.sh --verify`. Discovery and mismatch reporting must use `info()` / `ok()` / `err()`, not `log()` alone (see gotchas).

### 5. Home Assistant Integration
- Uses WebSocket API (NOT REST API -- REST endpoints are internal, not public)
- Recreates entity IDs after reassignment to reflect new device configuration
- Filters updates to ESPHome platform only (`platform == 'esphome'`)
- Verifies entity ID consistency across all discovered devices
- Device naming (`name_by_user` in the device registry):
  - No area assigned in HA: `<rolename>` (hostname minus the MAC suffix) -- the status quo
  - Area assigned in HA: `<Area> <rolename>` (still no MAC suffix), e.g. area `Office` +
    role `c6-wifi-mmwave` -> `Office c6-wifi-mmwave`. Entity IDs are regenerated from
    that name, so they pick up the area prefix too.
  - The area is read from HA, never written: assign it in the HA UI and the next
    flash/reassign/entity update adopts it.
- Commands used:
  - `config/entity_registry/list` -- get all entities
  - `config/area_registry/list` -- resolve a device's `area_id` to its area name
  - `config/device_registry/update` -- set the device `name_by_user`
  - `config/entity_registry/get_automatic_entity_ids` -- compute new IDs for given device_name
  - `config/entity_registry/update` -- update entity ID
- Entity ID security: only updates entities with `platform == 'esphome'`, preventing accidental updates to beacon trackers, iBeacon integrations, etc.
