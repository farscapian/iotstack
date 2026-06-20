# Architecture Decisions and Gotchas


### Bootstrap-mediated production OTA

Production firmware has **no OTA server** in YAML. Update/reassign/flash paths:
1. Switch device to bootstrap (`switch_to_bootstrap` API or serial refresh)
2. Wait for `bootstrap-<mac>.local` on `_iotstack-bootstrap._tcp`
3. OTA production image from bootstrap via `update_devices.sh --reassign`

`iotstack flash --erase` on an online production device still goes through this bootstrap path for the actual OTA step.

### `--erase` assessment and update_devices

**iotstack.sh flash assessment** (`FLASH_ERASE=1`):
- Must skip early exit in `_flash_production_matches_build` when hashes match
- Must skip the **second** mDNS `config_hash` match check in `_flash_assess_device` (there were two independent "current" checks)
- Export `FLASH_ERASE=1` explicitly before assessment helpers run

**update_devices.sh** (`--erase`):
- Uses a dedicated `FLASH_ERASE=true` flag to force devices onto the flash list
- **Do not** tie `--erase` to `UPGRADE_DELTA=false` -- that skipped compile-cache / `NEW_CONFIG_HASH` resolution and caused `hash: unknown` plus redundant compiles
- `iotstack flash` passes **both** `--upgrade-delta` and `--erase` during bootstrap OTA; argument order must leave `FLASH_ERASE` effective without disabling delta compile logic

### `iotstack verify` and `set -e`

`update_devices.sh` runs with `set -e`. The old `log()` helper returned exit 1 when not verbose, which killed the script on the first `log` call in verify mode before any output.

**Fix:** `log()` always `return 0`; use `info()` for messages that must print in non-verbose verify/discovery paths.

### Bootstrap mDNS TXT records

Bootstrap firmware advertises `_iotstack-bootstrap._tcp` (not `_esphomelib._tcp`, which is removed on WiFi connect to keep Home Assistant from auto-discovering bootstrap devices). The custom service includes explicit TXT records in `yamls/bootstrap.yaml`:

- `config_hash` -- 8-char hex from `App.get_config_hash()` (primary runtime comparison key)
- `project_version` -- compile-time git tag+commit (fallback when hash unavailable)

`flash_assess_bootstrap_device()` (`scripts/flash-compare.sh`) prefers mDNS `config_hash` comparison when `bootstrap-<mac>` is online, avoiding slow USB `read-flash` at 9600 baud. Falls back to on-flash MD5 compare when the device is not on WiFi or TXT is empty (pre-OTA bootstrap builds).

### Post-OTA hash reporting

During reassign OTA the discovered host is `bootstrap-<mac>`. Do **not** compare that host's mDNS `config_hash` to the production build hash -- bootstrap TXT carries the bootstrap image hash, not production. `update_devices.sh` always queues a production OTA in `--reassign` mode (no misleading `hash X -> Y` warn). Post-OTA success reporting falls back to build hash from `NEW_CONFIG_HASH`, `build_info.json`, or `compilation-cache.csv` (`image_hash` column via `_resolve_build_config_hash`) when the bootstrap host has no production hash.

After USB bootstrap flash, WiFi readiness is detected by probing `bootstrap-<mac>.local:3232` (`_wait_for_bootstrap_wifi_ready`), not by a serial log line.

### Matrix display panel layout (NVS, not config_hash)

Panel count and dimensions live in **NVS**, not in firmware `config_hash`. A device can run current firmware but wrong panel layout.

- CLI flags: `--panel-count`, `--panel-width`, `--panel-height` (flags -> pass store -> role defaults)
- Runtime sensor: `panel_count` (legacy fallback: `matrix_panel_columns`)
- **Preferred path:** switch to bootstrap -> `update_nvs_secrets` API with `matrix_cols`, `matrix_panel_w`, `matrix_panel_h`
- **USB fallback:** `write-nvs-secrets.sh` only when bootstrap API unreachable (first provision)
- Flash with current firmware but wrong layout: assessment reports NVS update action without recompiling

### NVS secrets update policy

Network-first, USB-last:
1. `update_nvs_secrets` on `bootstrap-<mac>.local` (production API for read/compare, bootstrap API for write)
2. `write-nvs-secrets.sh` / esptool only when bootstrap is not yet on WiFi or API is down

### Color variables and `printf`

`update_devices.sh` color vars must use ANSI-C quoting (`GRN=$'\033[0;32m'`). Single-quoted `'\033[...]'` stores a literal backslash; `echo -e` in `[OK]` lines still works but `printf '%s'` prints raw `\033[0;32m`.
