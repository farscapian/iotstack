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
  - Area assigned in HA: bare `<friendly_name>` (no area, no MAC suffix), e.g.
    `friendly_name: "SendSpin Speaker"` -> `SendSpin Speaker`. HA's own default
    `entity_id_parts` (AREA, PARENT_DEVICE, DEVICE, ENTITY --
    `homeassistant/helpers/entity_registry.py`, `_async_generate_entity_id`) already
    prepends the area to both the entity friendly name and the generated entity ID, so
    `name_by_user` must NOT also carry the area -- doing so double-prefixes it (device
    "Office Matrix Display" in area "Office" -> `text.office_office_matrix_display_...`).
  - Matrix displays' physical "Display Text" entity still gets pushed the full
    `<Area> <friendly_name>` string (e.g. "Office Matrix Display") since the LED screen
    has no HA area logic of its own -- that string is computed separately and never
    written to `name_by_user`.
  - The area is read from HA, never written: assign it in the HA UI and the next
    flash/reassign/entity update adopts it.
  - Device matching is by the MAC in the registry's `connections` (ESPHome devices have
    NO `identifiers`), scoped to devices owned by an `esphome` config entry. Do not match
    on the MAC alone: other integrations (Music Assistant) create their own device for the
    same hardware with the MAC inside their identifier, and would be renamed by mistake.
  - Every matched device is also tagged with a label named after its own MAC suffix (e.g.
    `8238cc`), merged into any existing labels rather than replacing them. Renaming a
    device makes it unfindable by MAC in HA's device/entity search otherwise; labels
    survive renames and HA's search matches label names, so the MAC suffix stays
    searchable regardless of what the device is later renamed to.
- Commands used:
  - `config/entity_registry/list` -- get all entities
  - `config/area_registry/list` -- resolve a device's `area_id` to its area name
  - `config/device_registry/update` -- set the device `name_by_user` and `labels`
  - `config/entity_registry/get_automatic_entity_ids` -- compute new IDs for given device_name
  - `config/entity_registry/update` -- update entity ID
  - `config/label_registry/list` / `config/label_registry/create` -- ensure the MAC-suffix label exists
- Entity ID security: only updates entities with `platform == 'esphome'`, preventing accidental updates to beacon trackers, iBeacon integrations, etc.
- Post-registration restart (`iotstack.sh` `_ha_register_esphome_device`): if `finalize-esphome`
  reports a device rename, a recreated entity ID, or an updated "Display Text" value, the device
  is restarted over the ESPHome native/device API (`_restart_press_button` ->
  `scripts/esphome-button.sh` -> the `restart` button every device ships, see
  `yamls/common/partition_manager_base.yaml`) rather than HA's `button.press` service, so the
  change is live right away instead of waiting for the device's next unrelated reboot. A failed
  restart only warns -- it never fails the registration step.
  - Batched: a multi-device command (`iotstack update <role>`, `iotstack reassign`,
    `iotstack rotate-secrets`) OTAs every device in the batch first and only runs HA
    registration/restart afterward, once all of them are back online -- not per-device inside
    the flashing loop. `_ota_via_bootstrap` defers via `IOTSTACK_DEFER_HA_REGISTRATION` /
    `IOTSTACK_PENDING_HA_HOSTNAMES`, flushed by `_ota_via_bootstrap_flush_ha` after the loop.
    A single-device `iotstack flash` still registers/restarts that one device immediately.
