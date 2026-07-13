# Architecture Decisions and Gotchas


### Bootstrap-mediated production OTA

Production firmware has **no OTA server** in YAML. Update/reassign/flash paths:
1. Switch device to bootstrap (`switch_to_bootstrap` API or serial refresh)
2. Wait for `bootstrap-<mac>.local` on `_iotstack-bootstrap._tcp`
3. OTA production image from bootstrap via `update_devices.sh --reassign`

`iotstack flash --erase` on an online production device still goes through this bootstrap path for the actual OTA step.

### `--erase` is `iotstack flash`-only

`--erase` is a USB-only flag meaning "erase the entire flash chip before writing." It is only valid for `iotstack flash`.

- **`update_devices.sh`** and **`iotstack update`** reject `--erase` with an immediate error -- it has no meaning in an OTA-only context.
- `iotstack flash` does NOT forward `--erase` to the internal `update_devices.sh --reassign` call for the production OTA step. The erase already happened at the USB bootstrap step.
- `_flash_invoke_update` (the function that calls `update_devices.sh --reassign`) must not include `--erase` in its `update_args`.

**iotstack.sh flash assessment** (`FLASH_ERASE=1`):
- Must skip early exit in `_flash_production_matches_build` when hashes match
- Must skip the **second** mDNS `config_hash` match check in `_flash_assess_device` (there were two independent "current" checks)
- Export `FLASH_ERASE=1` explicitly before assessment helpers run

### `iotstack verify` and `set -e`

`update_devices.sh` runs with `set -e`. The old `log()` helper returned exit 1 when not verbose, which killed the script on the first `log` call in verify mode before any output.

**Fix:** `log()` always `return 0`; use `info()` for messages that must print in non-verbose verify/discovery paths.

### Bootstrap mDNS TXT records

Bootstrap firmware advertises `_iotstack-bootstrap._tcp` (not `_esphomelib._tcp`, which is removed on WiFi connect to keep Home Assistant from auto-discovering bootstrap devices). The custom service includes explicit TXT records in `yamls/bootstrap.yaml`:

- `config_hash` -- 8-char hex from `App.get_config_hash()` (primary runtime comparison key)
- `project_version` -- compile-time git tag+commit (fallback when hash unavailable)

`flash_assess_bootstrap_device()` (`scripts/flash-compare.sh`) prefers mDNS `config_hash` comparison when `bootstrap-<mac>` is online, avoiding slow USB `read-flash` at 9600 baud. Falls back to on-flash MD5 compare when the device is not on WiFi or TXT is empty (pre-OTA bootstrap builds).

### Post-OTA hash reporting

During reassign OTA the discovered host is `bootstrap-<mac>`. Do **not** compare that host's mDNS `config_hash` to the production build hash -- bootstrap TXT carries the bootstrap image hash, not production. `update_devices.sh` always queues a production OTA in `--reassign` mode (no misleading `hash X -> Y` warn).

The flash success line (`ok "${HOSTNAME}: flash successful. (installed: ${hash_short})"`) uses `NEW_CONFIG_HASH` (the production firmware hash from `build_info.json`) -- **not** `DEVICE_HASHES[$HOSTNAME]` (the pre-flash mDNS hash of the bootstrap device). The pre-flash hash is the bootstrap's config_hash and would be misleading here. `NEW_CONFIG_HASH` is always set before the flash loop runs.

After USB bootstrap flash, WiFi readiness is detected by probing `bootstrap-<mac>.local:3232` (`_wait_for_bootstrap_wifi_ready`), not by a serial log line. Default wait is **10s** (`_BOOTSTRAP_WIFI_READY_TIMEOUT_SEC`) -- sufficient only when bootstrap is already running; a **ROM boot loop** (repeating `ESP-ROM:esp32s3`, `entry 0x403c8914`, no `[nvs_secrets]` lines) means the app never started -- do not blame WiFi timeout until serial shows bootstrap firmware booted.

### `FIRMWARE_BIN` must use `${YAMLS_DIR}`, not `yamls/`

`update_devices.sh` resolves the OTA binary as:
```bash
FIRMWARE_BIN="${YAMLS_DIR}/.esphome/build/${DEVICE_NAME}/.pioenvs/${DEVICE_NAME}/firmware.ota.bin"
```

`YAMLS_DIR` is an absolute path exported from `config.sh`. **Never use a relative `yamls/` prefix** -- if iotstack is invoked from any directory other than the project root, `FIRMWARE_BIN` resolves to a nonexistent path, `esphome upload --file ""` fails immediately with no visible error, and the OTA log directory is left empty.

### Build cache sync between `iotstack flash` Step 1 and Step 5

`iotstack flash` compiles both bootstrap and production in Step 1 via `smart_compile`. `update_devices.sh` (Step 5) has its own independent build cache at `~/.iotstack/logs/<device>.build.cache` (`esphome_version` + `config_hash`). Without syncing them, Step 5 sees a cache miss and recompiles.

`_flash_sync_update_devices_cache()` in `iotstack.sh` is called immediately after the production `smart_compile` in Step 1. It writes the same cache keys that `update_devices.sh` would write itself, giving Step 5 an instant cache hit. If you refactor the compile flow, ensure this sync call is preserved after production compilation.

### Build dir is named after `esphome.name`, NOT the role

ESPHome writes its build to `.esphome/build/<esphome.name>/`, and roles are free to
shorten that name to stay under ESPHome's 31-char node-name limit once
`name_add_mac_suffix` appends the MAC. Two roles still do:

| Role (YAML basename) | `esphome.name` -> build dir |
|----------------------|-----------------------------|
| `ledlightstrip-c6-thread` | `ledstrip-c6-thread` |
| `ledlightstrip-s3-wifi` | `ledstrip-s3-wifi` |

Keeping role == `esphome.name` avoids the whole class of bug, which is why the
`sendspinspeaker` role was renamed to `sendspin` (its `esphome.name`). Prefer that
when adding a role. The resolver below still exists because the `ledlightstrip`
roles cannot do it -- their names would exceed the 31-char limit.

Anything that touches a **build dir or firmware path** must resolve the name with
`_esphome_build_name_for_yaml()` (`scripts/iotstack-version.sh`) rather than using
the YAML basename. Anything that touches the **build cache file**
(`~/.iotstack/logs/<role>.build.cache`) stays keyed on the ROLE. They are different
keys; conflating them is the bug below.

Symptoms when this is wrong (all seen on `sendspin` before the fix):
`_config_hash_from_build_dir` looks in a build dir that does not exist, so the
config_hash can never match -- Step 1 reports `no build_info.json for <role>` on
every run, `_flash_sync_update_devices_cache()` silently no-ops on its
`[[ -f "$build_info" ]] || return 0` guard, and Step 5 recompiles from scratch. The
result is two full compiles per flash, forever, with no self-healing.

Worse, `update_devices.sh` used to fall back to *the most recently modified
`firmware.ota.bin` anywhere under `.esphome/build/`* when its path missed. That
fallback silently OTAs **another role's firmware** onto the device. It is gone --
a missing firmware path is now a hard error before any device is touched.

### Agent live-run watching (`sessions.watch`)

Every `iotstack` invocation appends one TSV line to `~/.iotstack/logs/sessions.watch` (`IOTSTACK_SESSION_WATCH`). Agents should tail it for new runs, then tail the `session_log` and `serial_log` paths from that line. Full workflow: `workflow.md` section Watching live iotstack runs.

- `iotstack ps` -- process trees for active sessions + detached `serial-logs.py` / esptool helpers
- `iotstack kill` -- stop all of the above (SIGCONT stopped jobs, then SIGTERM/SIGKILL per process group)

### esptool flash frequency (ESP32-S3 / S2)

Firmware builds record `--flash_mode`, `--flash_freq`, and `--flash_size` on the first line of `.pioenvs/<name>/flash_args`. Bootstrap USB writes must match (e.g. **80m** on ESP32-S3 DevKit). `esp_esptool_flash_params_for_build()` in `scripts/esp-serial.sh` parses `flash_args` / `flash_project_args`; a past hardcoded **40m** mismatch caused **ROM boot loops** after hash-verified writes. See `pitfalls.md`.

### OTA init partition at `0xd000`

`esp_ota_init_bin_for_build()` prefers build `ota_data_initial.bin`, then `boot_app0.bin`, then the Arduino package fallback. Log labels use the basename actually flashed (`ota_data_initial.bin` vs `boot_app0.bin`).

### Matrix display panel layout (NVS, not config_hash)

Panel count and dimensions live in **NVS**, not in firmware `config_hash`. A device can run current firmware but wrong panel layout.

- CLI flags: `--horizontal-panel-count` (cols, side by side), `--vertical-panel-count` (rows, stacked), `--matrix-panel-width`, `--matrix-panel-height` (flags -> pass store -> role defaults). `--panel-count` is a deprecated alias for `--horizontal-panel-count`.
- Runtime sensors: `panel_count` (cols), `panel_rows` (vertical; absent on pre-vertical firmware -> treated as 1); legacy cols fallback `matrix_panel_columns`
- **Preferred path:** switch to bootstrap -> `update_nvs_secrets` API with `matrix_cols`, `matrix_rows`, `matrix_panel_w`, `matrix_panel_h`
- **USB fallback:** `write-nvs-secrets.sh` only when bootstrap API unreachable (first provision)
- Flash with current firmware but wrong layout: assessment reports NVS update action without recompiling

### NVS secrets update policy

Network-first, USB-last:
1. `update_nvs_secrets` on `bootstrap-<mac>.local` (production API for read/compare, bootstrap API for write)
2. `write-nvs-secrets.sh` / esptool only when bootstrap is not yet on WiFi or API is down

The bootstrap API write is **encrypted** (noise PSK = per-device `boot_api_key`,
written OOB over USB) and **fails closed**: no PSK -> no plaintext connection, so
the caller falls back to USB. Firmware also refuses `update_nvs_secrets` without an
active PSK (`require_api_encryption: true`). A keyless/erased device is USB-recover
only. See [security.md](security.md) "Bootstrap API encryption".

### Color variables and `printf`

`update_devices.sh` color vars must use ANSI-C quoting (`GRN=$'\033[0;32m'`). Single-quoted `'\033[...]'` stores a literal backslash; `echo -e` in `[OK]` lines still works but `printf '%s'` prints raw `\033[0;32m`.
