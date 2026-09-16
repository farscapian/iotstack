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
- **Bootstrap-parked devices are folded in when their production image already matches.**
  A bare `iotstack update <role>` (no explicit MACs) only discovers devices currently
  running production (`_esphomelib._tcp`) -- a device parked on bootstrap (e.g. left
  there by a prior interrupted OTA) is otherwise silently skipped forever, even if its
  production OTA slot already holds this exact role's build. `_update_via_bootstrap`
  (`iotstack.sh`) compiles first, then also browses `_iotstack-bootstrap._tcp` and
  compares each `bootstrap-<mac>`'s advertised `production_image_hash` TXT
  (`PartitionManager::get_production_image_hash()`, same 8-char `config_hash` format)
  against the freshly compiled hash; a match is added to the batch and OTA'd via the
  normal bootstrap-mediated path (`_ensure_device_on_bootstrap` already treats "already
  on bootstrap" as a no-op switch). A bootstrap-parked device whose production slot does
  **not** match is left alone -- bootstrap advertises no `device_role` TXT, so a mismatch
  could mean "belongs to this role but stale" or "a different role's device is on
  bootstrap right now," and only an explicit `iotstack update <role> <mac>` disambiguates.


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

### 4. OTA the Bootstrap Partition from Production (`iotstack ota-bootstrap`)

Opt-in. Pushes a new bootstrap image directly to devices that are currently
running production, so bootstrap can be refreshed across a fleet without a
USB trip. Requires `IOTSTACK_ENABLE_BOOTSTRAP_OTA=1` in the active `.env`
(see `docs/.env.example`) -- off by default, in which case production
firmware has no OTA server at all, matching the pre-existing invariant that
OTA never overwrites bootstrap:

```bash
iotstack ota-bootstrap bleproxy              # All bleproxy devices, skip up-to-date
iotstack ota-bootstrap 199ef4                # By MAC only; role via mDNS
iotstack ota-bootstrap all --dry-run         # Preview across the whole fleet
iotstack ota-bootstrap bleproxy --force      # Re-flash bootstrap even if unchanged
```

**How it works:**
- With the flag on, `iotstack_prepare_compile_yaml()` (`scripts/iotstack-version.sh`)
  injects `yamls/common/production_bootstrap_ota.yaml` as a `packages:` sibling
  into the temp compile copy of every production role -- the checked-in role
  YAML (e.g. `yamls/bleproxy.yaml`) is never edited, and a build with the flag
  off has zero trace of the package.
- ESP-IDF's `esp_ota_get_next_update_partition()` always targets the OTA slot
  that is NOT currently running. Since production firmware runs from `ota_1`,
  any OTA write it accepts automatically and unavoidably lands in `ota_0`
  (bootstrap) -- that IS the mechanism, nothing custom-built.
- `_ota_bootstrap_via_production` (`iotstack.sh`) drives one device at a time:
  confirms the device advertises `_iotstack-bootstrap-target._tcp` (built with
  the flag on -- a fleet may be mid-rollout, so this is checked per-device,
  not assumed from the local `.env`), preflight-checks the new bootstrap
  firmware's size against the device's own reported `ota_0` size
  (`bootstrap_partition_size` mDNS TXT, from
  `PartitionManager::get_bootstrap_partition_size()`), skips devices whose
  `bootstrap_image_hash` TXT already matches unless `--force`, then runs
  `esphome upload` against the production hostname with a distinct
  per-device password (see `docs/security.md`).
- ESPHome's OTA component always boots what it just wrote, so the device
  reboots into the new bootstrap image automatically. The command then
  confirms the new image re-advertised the expected `config_hash` over
  `_iotstack-bootstrap._tcp` -- a mandatory, non-skippable gate, since there
  is no automatic rollback if a bad-but-not-corrupt image boots and
  crash-loops (no boot-health watchdog exists yet, see `docs/boot-fallback.md`).
  Only after that confirmation does it flip the device back to production by
  pressing the same "Toggle Boot Partition" button entity `iotstack restart
  <device> --next` already uses (no new API surface).
- If the confirmation step fails, or the flip-back step is interrupted, the
  device is left parked on bootstrap rather than touched further -- recover
  it with `iotstack update <role> <mac>` or `iotstack restart <device> --next`,
  exactly as for any other device on bootstrap. No new recovery machinery
  was added for this; the existing bootstrap-mediated recovery flow already
  covers it.
- Uses a distinct pass-store secret (`bootstrap-ota-from-production`), never
  the existing bootstrap-mode OTA secret -- see `docs/security.md` for why.

**Residual risk:** unlike a bad production image (survivable -- bootstrap is
still there), a bad-but-not-corrupt bootstrap image that boots and later
crash-loops is not remotely recoverable, since bootstrap is the fleet's own
recovery floor. The mDNS-hash confirmation above is the only mitigation
today. Test on one device before rolling out to a fleet.

### 5. Verify (`iotstack verify`)
Compile (or cache-hit) and compare each device's runtime `config_hash` against the build -- no flashing:

```bash
iotstack verify bleproxy
iotstack verify all
```

Uses `update_devices.sh --verify`. Discovery and mismatch reporting must use `info()` / `ok()` / `err()`, not `log()` alone (see gotchas).

### 6. Home Assistant Integration
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

### 7. mmwave Area Composite Metrics
After every `iotstack update mmwave` (non-dry-run, HA configured), `update_devices.sh`
calls `ha_websocket.py sync-mmwave-composites --apply` to create per-Area "template
sensor" helpers averaging each raw metric across every mmwave device placed in that
Area, plus a time-based EMA of the average:
- Raw composites (all mmwave devices in an Area): Avg Heart Rate, Avg Respiratory Rate,
  Avg Detection Distance, Avg Illuminance, Avg Target Count, Presence Likelihood
  (percent of the Area's devices currently reporting `target_count > 0`).
- EMA composites (`<metric> EMA`, `alpha = 1 - e**(-dt/tau)`, default `tau = 180s`,
  `--tau-seconds` to override): Heart Rate, Respiratory Rate, Detection Distance,
  Illuminance only -- never Target Count or Presence Likelihood.
- The EMA is built from the *raw* per-device sensors (via the Area's own raw-average
  composite above), never from mmwave.yaml's on-device `(EMA)` sensors -- those already
  smooth a single device's readings and would double-smooth (and hide multi-device
  disagreement within the Area) if averaged together.
- mmwave devices are found by capability signature (entities named exactly "Heart Rate",
  "Respiratory Rate" and "Target Count" all present on the same device), not by hostname
  or role -- robust to renames.
- Idempotent by helper title (`"<Area> <label>"`): an existing title is left alone.
  Updating an existing helper's formula requires HA's options/subentries flow, not
  implemented yet -- delete and let the next `iotstack update mmwave` recreate it.
- Created via HA's config-flow API (`handler: "template"`), the same mechanism used for
  every other HA UI "helper" -- there is no dedicated WS command to create one. The
  flow's exact field names are version-dependent, so `_create_template_sensor_helper` in
  `ha_websocket.py` fills each step from its own live `data_schema` instead of assuming a
  fixed step sequence.
- `sensor: distance` in `yamls/mmwave.yaml` is exposed as a numeric entity ("Detection
  Distance (cm)", `device_class: distance`) specifically so this can average it -- the
  "Detection Distance" text sensor is pre-formatted for the per-device Imperial/Metric
  select and cannot be averaged.
- Dry-run by default (`sync-mmwave-composites` without `--apply`) prints the Jinja that
  would be created for every Area/metric without touching HA -- use this to sanity-check
  discovery before the first `--apply` run.
