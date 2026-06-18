# ESP32 ESPHome Device Management -- Development Notes

## Naming Convention

**Always use lowercase "iotstack"** -- never "IoT Stack" or "iotStack". Examples:
- OK: `iotstack update bleproxy`
- OK: `iotstack devices`
- BAD: ~~IoT Stack~~, ~~iotStack~~, ~~IOTSTACK~~

This applies in code comments, documentation, help text, and all user-facing messages.

## Canonical Development Path

- **Primary repo:** `~/Sync/mini_projects/iotstack` on branch `main`
- **CLI entrypoint:** `~/.local/bin/iotstack` -> symlinks to `iotstack.sh` in that repo
- **Before testing fixes:** `git pull` on `main` -- stale local trees produce confusing output (e.g. `--flash-anyway` appearing to do nothing when the fix is not yet pulled)
- Grok/Cursor worktrees may mirror the same commit but are not the install target; develop and commit on `main` unless explicitly working in a worktree

## ASCII-Only Text (Repo-Wide)

**All documents, logging output, code comments, and help text must be ASCII-only.**

- No Unicode symbols: checkmarks, arrows, emoji, box-drawing, em dashes, etc.
- Use `--` instead of em dash, `->` instead of arrow, `[OK]`/`[FAIL]` instead of checkmarks
- Section dividers in shell comments: `# -- Title --` not box-drawing characters
- ANSI color escape bytes in `$'\033[...]'` variables are OK for terminal coloring; message text itself stays ASCII
- Maintenance script: `scripts/ascii-only-sanitize.py` (character substitution only; preserves indentation)
- Run check: `python3 scripts/ascii-only-sanitize.py .` (exit 0 = all scanned text files ASCII)

## CLI Output Conventions

Runtime script output uses plain ASCII status tags:

- `[INFO]`, `[OK]`, `[WARN]`, `[ERR]`, `[FAIL]`
- Use `matches`, `!=`, `...` instead of decorative characters
- Compile progress: `info "Compiling firmware..."` -- no animated compile spinners
- `iotstack.sh` uses `$'\033[...]'` only for tag colors in `echo -e`, never Unicode in message text

## Environment Variables

### Environment File Configuration

Environment variables are stored in `~/.iotstack/.env` and loaded automatically on every `iotstack` invocation.

**Setup:**
```bash
# View available options
cat docs/.env.example

# Create default configuration (done automatically by setup.sh)
cp docs/.env.example ~/.iotstack/.env

# Edit to customize
nano ~/.iotstack/.env
```

**Using Multiple Configurations:**
```bash
# Create alternate configuration
cp ~/.iotstack/.env.example ~/.iotstack/pangolin.env
# Edit pangolin.env with specific settings

# Use alternate config for a command
iotstack -env=pangolin.env flash bleproxy /dev/ttyACM0

# Or combine with other flags
iotstack -v -env=debug.env update bleproxy
```

### DISABLE_COMPILATION_CACHE
**Purpose:** Force recompilation of firmware regardless of cache state

**Values:**
- `0` (default): Use compilation cache for faster builds
- `1`: Always recompile, ignore cache

**Usage:**
```bash
# Option 1: Set in ~/.iotstack/.env (persistent for all commands)
echo "DISABLE_COMPILATION_CACHE=1" >> ~/.iotstack/.env

# Option 2: Use alternate config file
iotstack -env=debug.env flash bleproxy /dev/ttyACM0

# Option 3: Set for single command
DISABLE_COMPILATION_CACHE=1 iotstack flash bleproxy /dev/ttyACM0
```

**Examples:**
```bash
# Create debug configuration with caching disabled
cp ~/.iotstack/.env.example ~/.iotstack/debug.env
sed -i 's/DISABLE_COMPILATION_CACHE=0/DISABLE_COMPILATION_CACHE=1/' ~/.iotstack/debug.env

# Use it
iotstack -env=debug.env update bleproxy

# Revert to default
iotstack update bleproxy  # Uses ~/.iotstack/.env
```

## Overview

The `update_devices.sh` script is a batch OTA flash tool for managing multiple ESPHome devices discovered via mDNS. It supports device renaming, role reassignment, and Home Assistant entity ID recreation.

The `iotstack.sh` CLI tool provides a user-friendly wrapper around this script with device roles (defined in `roles.conf`).

**IMPORTANT: Development Process**
- Default: stage changes and wait for human device testing before commit
- Commit/push only after explicit human approval (or when the human explicitly asks to commit)
- Tagged releases use annotated git tags (e.g. `v0.1.0`); firmware `project_version` is derived from the latest tag at compile time
- See [Development Workflow](#development-workflow) section below for details

## Core Architecture

### Device Discovery
- Uses `avahi-browse -t -r _esphomelib._tcp` to discover devices on the network
- Devices must advertise `_esphomelib._tcp` service (native ESPHome)
- Extracts device names, config_hash, and project version from mDNS TXT records
- No HTTP calls needed -- all discovery is via mDNS

### Build & Flash Strategy
- Compilation happens once serially (with SHA256 cache to skip unnecessary rebuilds)
- OTA flashing runs in parallel (default `--jobs 4`)
- Uses `wait -n` for slot-based job queuing
- Respects Thread device constraints: forces `--jobs 1` for Thread configs (Thread OTA is slow; parallelism causes mesh contention)

### Compilation Cache

Cache stored at `~/.iotstack/compilation-cache.csv` (CSV format with headers):

**Columns:**
- `yaml_name`: YAML filename (e.g., `bleproxy.yaml`, `.iotstack-failsafe-esp32c6.yaml`)
- `yaml_sha`: SHA256 hash of YAML + `yamls/external_components/` + `yamls/common/` + **current git tag** (cache key)
- `binary_sha`: SHA256 of compiled `firmware.bin`
- `config_hash`: 8-char hex ESPHome config hash (primary runtime comparison key)

Per-device build cache also at `~/.iotstack/logs/<device>.build.cache` (used by `update_devices.sh`).

**Cache invalidation:**
- Changes to any device YAML, `external_components/`, or `common/` package
- New git tag (`iotstack_project_version` folded into `yaml_sha` via `scripts/iotstack-version.sh`)
- ESPHome version change (`update_devices.sh` per-device cache)
- Set `DISABLE_COMPILATION_CACHE=1` to force recompilation

**Example cache contents:**
```
yaml_name,yaml_sha,binary_sha,config_hash
bleproxy.yaml,8f3e2c9d4a1b5f...,c9d2a8e7f3b1c4...,1a25e0c8
failsafe.yaml,75e67037f9e3fc23...,a183d757ba74cc50...,3ea7c88a
```

### Serial Flash Baud Rate: 9600 (Critical)
**[WARN] IMPORTANT: All esptool flash operations use 9600 baud, NOT 57600 or 115200**

Testing with ESP32-C6 devices revealed that higher baud rates cause data corruption during large firmware transfers:
- **57600 baud**: Firmware corruption starts ~52KB into 807KB transfers
- **115200 baud**: Worse corruption, more frequent failures
- **9600 baud**: 100% reliable, full file integrity verified

**Why?** Higher baud rates accumulate bit errors over long transfers. A single bit flip during 789KB transfer is catastrophic. Conservative 9600 baud prevents this.

**Performance tradeoff**: 57600 (~2.5 sec) vs 9600 (~10-15 sec). Reliability >> Speed.

If baud rate changes are ever considered, empirically test with actual 789KB firmware transfers and verify full SHA256 checksums.

### YAML Configuration
- ESPHome devices are configured via YAML files in `yamls/` (one file per role, e.g. `bleproxy.yaml`, `matrixdisplay.yaml`)
- `esphome.name` is the role name; `name_add_mac_suffix: true` produces hostnames like `bleproxy-8238cc`
- **Production YAMLs must not include `ota:`** -- OTA server lives only on failsafe firmware; production is updated via failsafe-mediated OTA
- **No `safe_mode:`** -- boot-loop recovery is handled by `partition_manager`
- **No `factory_reset` button** -- physical reset is `common/boot_button.yaml`

### Project Version (Build-Time Git Tag)

All role YAMLs use a substitution injected before every `esphome compile`:

```yaml
substitutions:
  project_version: "0.0.0-dev"  # placeholder; overridden at compile time
esphome:
  project:
    version: "${project_version}"
```

**Resolution order** (`scripts/iotstack-version.sh`):
1. `IOTSTACK_PROJECT_VERSION` env var (tests/overrides)
2. Latest git tag: `git describe --tags --abbrev=0` (e.g. `v0.1.0`)
3. Fallback `0.0.0-dev` when no tags exist

**Injection points:** `iotstack.sh` `_esphome_compile`, `update_devices.sh`, `failsafe-yaml.sh` (variant artifacts). Source YAMLs in git stay at `0.0.0-dev`; only compile-time copies get the real tag.

`project_version` is advertised in mDNS TXT and used as a **fallback** when `config_hash` is unavailable. It is not the primary flash/update comparison key.

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
iotstack update a1a7b0 mmwave --flash-anyway
```

**How it works:**
- MAC suffixes are 6-character hex strings (last 6 chars of MAC address)
- MACs come before the device name in command
- Only devices matching specified MACs are flashed
- Production updates run **via failsafe** (`_update_via_failsafe`) so OTA never overwrites the failsafe partition

### 2. Delta Updates (Default: On)
- **Primary comparison:** `config_hash` from device mDNS TXT vs. compiled build
- Only flashes devices with mismatched hashes (`--upgrade-delta`, default in `update_devices.sh`)
- **`--flash-anyway`:** force all matched devices onto the flash list (separate `FLASH_ANYWAY` flag -- does not disable compile cache)
- Fallback to `project_version` comparison if `config_hash` unavailable in mDNS
- Note: some help text still says `--force-reflash`; the implemented flag is `--flash-anyway`

### 3. Device Reassignment (`iotstack reassign` / `--reassign`)
Flash a target configuration only to specific devices (always via failsafe OTA):

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
- Commands used:
  - `config/entity_registry/list` -- get all entities
  - `config/entity_registry/get_automatic_entity_ids` -- compute new IDs for given device_name
  - `config/entity_registry/update` -- update entity ID
- Entity ID security: only updates entities with `platform == 'esphome'`, preventing accidental updates to beacon trackers, iBeacon integrations, etc.

## iotstack CLI Tool

### Overview
`iotstack.sh` is a user-friendly wrapper around `scripts/update_devices.sh`. It provides device roles (e.g., `iotstack update bleproxy`) instead of requiring full YAML paths (e.g., `scripts/update_devices.sh yamls/bleproxy.yaml`).

Users run `setup.sh` once to symlink `iotstack` into `~/.local/bin/` and ensure that directory is on `PATH` (via `~/.bashrc`).

### Device Mapping (scripts/roles.conf)
Device roles are defined in `scripts/roles.conf`. Network type (WiFi or Thread) is automatically detected by introspecting the YAML file:
```
bleproxy=yamls/bleproxy.yaml
mmwave=yamls/mmwave.yaml
sendspinspeaker=yamls/sendspinspeaker.yaml
ledlightstrip=yamls/ledlightstrip.yaml
threadrouter=yamls/threadrouter.yaml
silentnotify=yamls/silentnotify.yaml
matrixdisplay=yamls/matrixdisplay.yaml
```

Format: `<role>=<yaml-path>`
- Network type determined from YAML content: `wifi:` section -> WiFi, `openthread:` section -> Thread
- Each YAML file is introspected at runtime (no need to specify variant in config)

### Usage Examples
```bash
# Update a device
iotstack update bleproxy
iotstack update threadrouter

# Update all devices listed in roles.conf
iotstack update all

# Reassign devices to different config
iotstack reassign 8dfcac 0f4df4 mmwave

# Or use direct YAML path
iotstack update yamls/custom.yaml
```

### Implementation Details
- `iotstack.sh` loads role list from `roles.conf`
- Network type auto-detected: checks for `wifi:` or `openthread:` sections in YAML
- User can pass either a device role or direct YAML path
- Internally calls `update_devices.sh` with resolved YAML paths
- All underlying features (reassign, verify, etc.) work the same way

## Partition Configuration -- Dynamically Calculated

**Two-partition scheme:** permanent **failsafe** (`ota_0`) + **production** (`ota_1`). All production OTA runs from failsafe so the failsafe image is never overwritten. Partition sizes are calculated from actual compiled firmware binary sizes.

### Calculation Process

1. **Compile failsafe firmware** (`smart_compile`)
   - Template: `yamls/failsafe.yaml`
   - Rendered per chip to `yamls/.iotstack-failsafe-<variant>.yaml` (`scripts/failsafe-yaml.sh`)
   - Output: `firmware.bin` in build directory

2. **Measure failsafe size** and set `IOTSTACK_FAILSAFE_PART_SIZE`
   - Failsafe partition = firmware size + margin, rounded up to 64 KB
   - Production partition = remaining flash after fixed NVS/OTA/metadata regions

3. **Generate partition table** (`scripts/partition-table.sh`)
   - Creates `~/.iotstack/iotstack_partition_table.csv`
   - Symlink at `yamls/iotstack_partition_table.csv` (ESPHome `!include`)
   - Failsafe may require a second compile pass after the table is regenerated

4. **Use partition table**
   - `write-nvs-secrets.sh` reads NVS offset/size from generated CSV
   - Serial flash and assessment code use calculated production offset

### Why This Approach?

- [OK] **No hardcoded partition sizes** -- All calculated from actual firmware
- [OK] **Zero chance of misalignment** -- Partition table always matches firmware reality
- [OK] **Firmware changes auto-handled** -- Larger firmware = larger partition, calculated automatically
- [OK] **Audit-friendly** -- Partition table shows exactly what firmware needs
- [OK] **Exact fit** -- Partitions are only as large as firmware needs (no wasted flash)
- [OK] **Artifacts in ~/.iotstack** -- Generated files stored in user home, not repo

### Files Involved

- `smart_compile()`: Calls partition calculation after compilation
- `_calculate_partition_sizes()`: Determines sizes from firmware binary
- `_generate_partition_table()`: Creates CSV with calculated values
- `~/.iotstack/iotstack_partition_table.csv`: Generated output (actual file)
- `yamls/iotstack_partition_table.csv`: Symlink to ~/.iotstack/iotstack_partition_table.csv (for ESPHome)

## Important Implementation Details

### Stdout/Stderr Redirection Issue
[WARN] **Critical for User Interaction**

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
- Temp files are cleaned up on script exit via `trap` handler
- Pattern: `.temp-reassign-<PID>.yaml` is gitignored

### Project.name Regex Handling
The `project.name` field in YAML can be quoted or unquoted:
```yaml
project:
  name: "iotstack.${device_name}"    # quoted
  # or
  name: iotstack.${device_name}      # unquoted
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
- Per-device build cache: `~/.iotstack/logs/<device>.build.cache` (YAML SHA + ESPHome version + config_hash)
- Global compilation cache: `~/.iotstack/compilation-cache.csv` (used by `smart_compile` / flash assessment)
- Cache invalidated on YAML/common/external_components changes, new git tag, or ESPHome upgrade

## Architecture Decisions & Gotchas

### Failsafe-mediated production OTA

Production firmware has **no OTA server** in YAML. Update/reassign/flash paths:
1. Switch device to failsafe (`switch_to_failsafe` API or serial refresh)
2. Wait for `failsafe-<mac>.local` on `_iotstack-failsafe._tcp`
3. OTA production image from failsafe via `update_devices.sh --reassign`

`iotstack flash --flash-anyway` on an online production device still goes through this failsafe path for the actual OTA step.

### `--flash-anyway` assessment and update_devices

**iotstack.sh flash assessment** (`FLASH_ANYWAY=1`):
- Must skip early exit in `_flash_production_matches_build` when hashes match
- Must skip the **second** mDNS `config_hash` match check in `_flash_assess_device` (there were two independent "current" checks)
- Export `FLASH_ANYWAY=1` explicitly before assessment helpers run

**update_devices.sh** (`--flash-anyway`):
- Uses a dedicated `FLASH_ANYWAY=true` flag to force devices onto the flash list
- **Do not** tie `--flash-anyway` to `UPGRADE_DELTA=false` -- that skipped compile-cache / `NEW_CONFIG_HASH` resolution and caused `hash: unknown` plus redundant compiles
- `iotstack flash` passes **both** `--upgrade-delta` and `--flash-anyway` during failsafe OTA; argument order must leave `FLASH_ANYWAY` effective without disabling delta compile logic

### `iotstack verify` and `set -e`

`update_devices.sh` runs with `set -e`. The old `log()` helper returned exit 1 when not verbose, which killed the script on the first `log` call in verify mode before any output.

**Fix:** `log()` always `return 0`; use `info()` for messages that must print in non-verbose verify/discovery paths.

### Post-OTA hash reporting

During reassign OTA the discovered host is `failsafe-<mac>` -- failsafe mDNS typically has **no `config_hash`**. Success line should fall back to build hash from `NEW_CONFIG_HASH`, `build_info.json`, or `compilation-cache.csv` (`_resolve_build_config_hash`).

### Matrix display panel layout (NVS, not config_hash)

Panel count and dimensions live in **NVS**, not in firmware `config_hash`. A device can run current firmware but wrong panel layout.

- CLI flags: `--panel-count`, `--panel-width`, `--panel-height` (flags -> pass store -> role defaults)
- Runtime sensor: `panel_count` (legacy fallback: `matrix_panel_columns`)
- **Preferred path:** switch to failsafe -> `update_nvs_secrets` API with `matrix_cols`, `matrix_panel_w`, `matrix_panel_h`
- **USB fallback:** `write-nvs-secrets.sh` only when failsafe API unreachable (first provision)
- Flash with current firmware but wrong layout: assessment reports NVS update action without recompiling

### NVS secrets update policy

Network-first, USB-last:
1. `update_nvs_secrets` on `failsafe-<mac>.local` (production API for read/compare, failsafe API for write)
2. `write-nvs-secrets.sh` / esptool only when failsafe is not yet on WiFi or API is down

### Color variables and `printf`

`update_devices.sh` color vars must use ANSI-C quoting (`GRN=$'\033[0;32m'`). Single-quoted `'\033[...]'` stores a literal backslash; `echo -e` in `[OK]` lines still works but `printf '%s'` prints raw `\033[0;32m`.

## Common Pitfalls & Solutions

| Issue | Root Cause | Solution |
|-------|-----------|----------|
| Prompt doesn't appear, script hangs | User input code runs after stdout redirect | Use `>&2` for messages, `</dev/tty` for input |
| `grep: invalid option -- '$'` | Pattern starts with dash (e.g., `-19b164$`) | Use `grep -- ` to stop option processing |
| Device discovery finds wrong devices | Filtering by device_name in reassign mode | In reassign mode, discover `_iotstack-failsafe._tcp`, filter by MAC suffix |
| Entity updates affect wrong integrations | Not checking platform field | Always filter: `if platform != 'esphome': continue` |
| `iotstack verify` prints nothing / exits immediately | `log()` returned 1 under `set -e` when not verbose | `log()` always returns 0; use `info()` for required output |
| `--flash-anyway` says it will reflash but exits early | Assessment ignored `FLASH_ANYWAY` on mDNS hash match | Honor `FLASH_ANYWAY` in all match branches; pull latest `main` |
| OTA success shows `hash: unknown` | Failsafe host has no mDNS config_hash; compile cache skipped hash | Separate `FLASH_ANYWAY` from `UPGRADE_DELTA`; `_resolve_build_config_hash` fallback |
| Literal `\033[0;32m` in compile spinner | `printf` + single-quoted color vars | Use `$'\033[...]'` or `[INFO]` lines only |
| `--panel-count=2` ignored when firmware current | Layout is NVS, not config_hash | Failsafe NVS update path even when firmware matches |
| Stale CLI behavior after fixes | Testing against unpulled `main` | `git pull` on `~/Sync/mini_projects/iotstack` |

## Device Types

Roles are listed in `scripts/roles.conf`. Examples:

### WiFi BLE Proxy
- YAML: `yamls/bleproxy.yaml`
- mDNS hostname: `bleproxy-<mac>` (e.g. `bleproxy-8238cc`)
- Board: Seeed XIAO ESP32-C6

### Thread Router
- YAML: `yamls/threadrouter.yaml`
- mDNS hostname: `threadrouter-<mac>`
- Network: Thread (OpenThread)
- Special handling: forces `--jobs 1` (Thread OTA is slow; parallelism causes mesh contention)

### WiFi mmWave
- YAML: `yamls/mmwave.yaml`
- mDNS hostname: `mmwave-<mac>`

### Matrix Display
- YAML: `yamls/matrixdisplay.yaml`
- Board: ESP32-S3-DevKitC-1, HUB75 panels
- Panel layout in NVS; see [Matrix display panel layout](#matrix-display-panel-layout-nvs-not-config_hash) above

## Development Workflow

**CRITICAL: Git Operations Only After Human Testing**

Default workflow -- **git commits and pushes only after the human has**:
1. **Tested the changes** against actual devices (not just compilation)
2. **Verified functionality** works as expected
3. **Explicitly approved** the changes (or directly requested commit/push)

**Workflow:**
1. Make code changes on `main` at `~/Sync/mini_projects/iotstack`
2. Stage changes (`git add`)
3. Wait for human approval unless they explicitly ask to commit
4. Commit with a clear message; push to `origin/main` when approved
5. Tag releases with annotated tags (`git tag -a vX.Y.Z`) when appropriate -- firmware picks up the tag on next compile

This keeps commits aligned with validated device behavior. AI-assisted sessions may commit when the human explicitly requests it, but device validation remains the bar for correctness.

### Research FIRST, Then Debug

**When encountering a persistent problem, do targeted internet research BEFORE systematic debugging.**

Example: Baud rate issues with ESP32 flash corruption
- [FAIL] Bad: Try 460800 -> 115200 -> 57600 (3+ hours of testing)
- [OK] Good: Research "ESP32 firmware corruption baud rate" -> find 9600 standard (5 minutes)

**When to research:**
- Problem seems common or straightforward (baud rates, timeouts, memory issues)
- Embedded systems problem (existing best practices likely exist)
- Multiple attempts are failing with similar symptoms
- Problem affects reliability/stability (not just convenience)

**Why this matters:**
- Embedded systems have well-established best practices (9600 baud for large transfers, etc.)
- Community knowledge saves hours of empirical debugging
- Understanding root cause (via research) prevents re-discovering the same issue

**When systematic debugging is still appropriate:**
- Cutting-edge/novel problems without community precedent
- Edge cases specific to this project's architecture
- After research has identified the likely cause (then test to confirm)

## Secrets Management: NVS-Based Architecture

**Secrets are stored in device flash (NVS partition), not in firmware binary or YAML files.**

### Implementation Status (updated 2026-06-14)

| Component | Status | Notes |
|-----------|--------|-------|
| NVS partition write | [OK] Working | Writes proper NVS binary format to the `nvs` partition offset read from the generated partition table |
| NVS key-value format | [OK] Working | Uses esp_idf_nvs_partition_gen; keys written under the **`iotstack` namespace** (see "NVS Namespace" pitfall below) |
| OTA password from NVS | [OK] Working | nvs_secrets component loads and applies password |
| WiFi credentials from NVS | [OK] Working | nvs_secrets reads SSID+password from NVS and applies them at runtime via `wifi::global_wifi_component->save_wifi_sta()` (see "WiFi Credentials From NVS" below) |
| API encryption key | [OK] Stored | Safely written to NVS, awaiting API component support |
| Flash encryption | [TODO] TODO | Planned for production hardening with eFuses |

### [CRITICAL] CRITICAL PITFALL: NVS keys must be written under a named namespace

`esp_idf_nvs_partition_gen` accepts a CSV with **no `namespace` row without erroring** (exit 0), but it then writes every key into reserved namespace-index 0 (the internal namespace registry). No named namespace exists on the chip, so at runtime `nvs_open(<any name>, NVS_READONLY, ...)` returns `ESP_ERR_NVS_NOT_FOUND` and the keys are **unreachable** -- even though they are physically present in flash.

**The CSV fed to `nvs_partition_gen` MUST start with a namespace row, and that name MUST match the `NAMESPACE` constant the C++ opens.** Both sides currently use `iotstack`:

```
key,type,encoding,value
iotstack,namespace,,          # <-- REQUIRED first data row
wifi_ssid,data,string,...
wifi_password,data,string,...
ota_password,data,string,...
api_key,data,string,...
```

- Write side: `scripts/write-nvs-secrets.sh` (emits the `iotstack,namespace,,` row)
- Read side: `NAMESPACE = "iotstack"` in `yamls/external_components/nvs_secrets/nvs_secrets.cpp`

**How to verify** what landed on the chip (read flash back and decode NVS entry namespace indices):

```bash
python3 -m esptool --chip esp32c6 --port /dev/ttyACM0 --baud 921600 \
  read-flash 0x9000 0x4000 /tmp/nvs.bin
# Decode: keys should be in ns_index >= 1 with a matching namespace-def entry.
# If keys are in ns_index 0 with no namespace-def entry, the namespace row is missing.
```

### WiFi Credentials From NVS ([OK] Solved)

The earlier limitation -- "ESPHome's WiFi component can't take credentials at runtime" -- is **solved**. The trick is the public WiFi API plus correct setup ordering:

- `nvs_secrets` runs at `setup_priority::AFTER_WIFI` (200.0f). The WiFi component runs at `setup_priority::WIFI` (250.0f), so WiFi is already initialized when `nvs_secrets::setup()` executes.
- In `setup()`, after reading the credentials, nvs_secrets calls:
  ```cpp
  #ifdef USE_WIFI
    wifi::global_wifi_component->save_wifi_sta(wifi_ssid_, wifi_password_);
  #endif
  ```
- `save_wifi_sta()` replaces the STA config with the NVS values, persists them to ESPHome preferences, and calls `connect_soon_()` to trigger an immediate reconnect (the same path the `improv` provisioning components use). This overrides the YAML placeholder (`configured-via-nvs`).
- The `#ifdef USE_WIFI` guard keeps the component compiling on thread-only configs that have no WiFi component.

Verified on hardware: boot log shows `[NVS] Applying WiFi credentials from NVS to WiFi component (SSID: ...)` followed by `[wifi] Connecting to '<real-ssid>'` and a DHCP-assigned IP.

### Thread Credentials From NVS ([TODO] built, needs hardware validation)

The Thread analog of the WiFi-from-NVS path. ESPHome's `openthread` component bakes the operational dataset in at compile time (`USE_OPENTHREAD_TLVS` / `CONFIG_OPENTHREAD_NETWORK_MASTERKEY`) and exposes no config-time NVS hook, so thread-only yamls carry a **placeholder** `network_key` (just to satisfy `has_exactly_one_key(network_key, tlv)` and compile). The real dataset comes from NVS at runtime:

- `nvs_secrets` reads the `thread_tlv` key (hex operational-dataset TLVs) from NVS.
- Guarded by `#ifdef USE_OPENTHREAD`, it parses the hex, takes the OpenThread stack lock (`openthread::InstanceLock::acquire()`), and applies it:
  ```cpp
  otThreadSetEnabled(inst, false);
  otDatasetSetActiveTlvs(inst, &dataset);
  otIp6SetEnabled(inst, true);
  otThreadSetEnabled(inst, true);
  ```
- Ordering works like WiFi: the openthread component is `setup_priority::WIFI` (250), `nvs_secrets` is `AFTER_WIFI` (200), so the stack exists when nvs_secrets runs.
- `CONFLICTS_WITH = ["wifi"]` in the openthread component means a single image cannot do both radios -- WiFi and Thread are **separate failsafe/production variants** (one radio per image; the C6 runs whichever image is booted). The dynamic partition table sizes each slot to whatever image lands there.

Status: compiles on threadrouter (Thread stack) and on WiFi-only devices (OT code excluded by the guard). **Not yet validated on a live Thread network** -- the runtime `otDatasetSetActiveTlvs` + re-attach sequence (and its timing vs. the OT task spin-up) needs hardware confirmation; the disable->set->enable order may need tuning.

### TODO: production self-recovery into failsafe

For a device parked where its production radio is weak, the production image
can't be rescued remotely (only via the physical boot button). A production
image *could* self-recover: watch connectivity (e.g. `wifi_signal` below a
threshold for N minutes, or repeated disconnects) and, on sustained failure,
call `partition_manager::boot_failsafe()` to drop into the failsafe image --
which (if Thread) is reachable over the mesh for re-flash. ESPHome has the hooks
(`wifi` `on_disconnect`, signal sensors, `interval:`). Not implemented; would
live as an optional shared package so each device opts in.

### TODO: cascading failsafe (3-tier, future)

The generalization of the above. Three app partitions forming a recovery
cascade, from most-reliable at the base to production at the top:

```
ota_0  failsafe-thread   (base -- slowest OTA, presumed most reliable / best range)
ota_1  failsafe-wifi     (faster recovery)
ota_2  production
```

Cascade (each tier detects its own failure and steps the boot slot DOWN, never
up; needs a boot-loop guard via the safe_mode counter):
- production fails to stay connected -> boot `failsafe-wifi`
- `failsafe-wifi` can't get on WiFi within a timeout -> boot `failsafe-thread`
- `failsafe-thread` is the floor (retries; never steps down)

**Only deploy all three IF they fit the flash.** Use the dynamic partition
sizing to sum failsafe-thread + failsafe-wifi + production; if the total fits
(comfortable on 8MB; tight on 4MB -- production drops from ~2.88MB to ~2.2MB,
still fits bleproxy 1.40MB), build the 3-tier layout. Otherwise fall back to the
current 2-partition scheme (failsafe-wifi + production). The decision is made at
provision time from the measured image sizes.

**The hard part -- OTA targeting with 3 OTA slots.** `esp_ota_get_next_update_partition()`
cycles ota_0->ota_1->ota_2->ota_0, so:
- OTA run from `failsafe-wifi` (ota_1) -> lands in `production` (ota_2) [OK] -- normal
  updates work out of the box.
- OTA run from `failsafe-thread` (ota_0) -> lands in `failsafe-wifi` (ota_1) [FAIL].
  A deep Thread-only recovery OTA (WiFi dead) therefore needs **explicit
  partition selection** in the OTA backend (ESPHome uses get_next and doesn't
  expose a target), which is the one piece beyond a weekend.

**Naming:** with the cascade, rename the current `failsafe` -> `failsafe-wifi`
(touches the mDNS name `failsafe-<mac>`, the `iotstack/roles/failsafe/...` pass
paths, the flash wait logic, and the `failsafe` partition label) and add
`failsafe-thread`. Do the rename *with* the cascade, not piecemeal.

**Build order:** (1) matched 2-variant failsafe (wifi/thread) + validated
Thread-from-NVS; (2) single-step self-recovery trigger (above); (3) full 3-tier
cascade + the explicit-OTA-target work. Keep `partition_manager`'s boot logic
able to target a *specific* slot (not just toggle) so it's cascade-ready.

Architecture:
1. **Pass store** (`~/.iotstack/.pass/`): Role-based master secrets (encrypted)
   - One secret per role (e.g., `iotstack/roles/bleproxy/ota_password`)
   - Generated during setup.sh, stored securely
   - Never written to disk unencrypted

2. **NVS partition** (device flash at 0x9000): Device-specific secrets
   - Unique per device: `sha256(role_secret | device_mac)`
   - Written after firmware flash via `write-nvs-secrets.sh`
   - Persists across firmware updates
   - Separate from firmware binary
   - Offset and size defined in `partition-config.sh` (not hardcoded)

   - Checked into git (safe for repo)
   - Used only at compile time (fallback/default)
   - Actual secrets come from NVS at runtime

Workflow:
```
setup.sh (first run)
  v
  Role secrets generated & stored in pass
  v
iotstack flash <device> <role>
  v
  v
  Firmware flashed to device via esptool
  v
  write-nvs-secrets.sh:
    - Retrieves role secret from pass
    - Derives device-specific secret (sha256 | mac)
    - Writes to device NVS partition
  v
Device boots
  v
  nvs_secrets component reads from NVS
  v
  Device has unique, secure secrets
```

Key benefit: **Single firmware binary for all devices, unique secrets per device, no disk exposure of real secrets.**

## [CRITICAL] CRITICAL: Never Print Passwords or Secrets to Console

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

## [CRITICAL] CRITICAL: Pass Password Handling

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

## NVS (Non-Volatile Storage) Architecture - Detailed

### What is NVS?

**NVS = Simple key-value store on ESP32 flash memory (NOT encrypted by default)**

NVS is NOT:
- A TPM (Trusted Platform Module)
- Hardware-encrypted storage
- Protected from physical flash reads
- Device-certificate based encryption

NVS IS:
- A key-value database on reserved flash partition (see CLAUDE.md Partition Configuration section)
- Persistent across power cycles and firmware updates
- Simple plaintext storage of device-specific secrets
- Readable if someone physically extracts the flash chip

### Why We Use NVS Despite Limitations

Our threat model protects against:
- [OK] **Firmware binary extraction** -> Attacker can't derive device passwords (not compiled in)
- [OK] **Hardcoded secrets in code** -> Eliminated, now device-specific in NVS
- [OK] **Single password for all devices** -> Each device has unique derived password
- [FAIL] **Physical flash chip extraction** -> NVS data is plaintext (not protected)

### Device-Specific Secret Derivation

```
Role-based secret (in pass store):
  iotstack/roles/failsafe/ota_password = "base_secret_xyz"
  
Device-specific computation (in-memory during flash):
  device_password = sha256("base_secret_xyz" | "1af95c")[0:32]
  
Stored in NVS only:
  ota_password = "a1b2c3d4e5..." (unique to this device)
  
Firmware at startup:
  nvs_secrets component reads NVS
  `-- Sets OTA service password from NVS value
  `-- Loads WiFi and API credentials
  `-- Enables device-specific OTA authentication
```

### Security Properties

| Threat | Protection | Attack Cost |
|--------|-----------|------------|
| Firmware binary extraction | [OK] No compiled passwords | Can't derive from binary |
| Firmware disassembly | [OK] No hardcoded secrets | Even reverse-engineers see nothing |
| Device password reuse | [OK] Unique per device (derived) | Each device has different password |
| Pass store compromise | [OK] Role secret stays encrypted | Still need device MAC to derive |
| Physical flash read | [FAIL] NVS plaintext | Moderate (requires soldering programmer) |
| Flash encryption bypass | [WARN] Future enhancement (see TODO) | Would require eFuse key extraction |

### Custom NVS Component

One custom ESPHome component reads from NVS at runtime:

**nvs_secrets**: Reads all device-specific secrets from NVS
- Reads `ota_password`, `wifi_ssid`, `wifi_password`, `api_key` from NVS partition
- No secrets in firmware binary (all come from device flash at runtime)
- Dynamically sets OTA authentication password from NVS
- Logs what was found (for debugging)
- Applies WiFi SSID/password from NVS to the WiFi component at runtime (see below)
- Status: [OK] OTA password working, [OK] WiFi credentials read from NVS and applied to the WiFi component

### WiFi Credential Challenge ([OK] Solved)

**Former problem:** It was believed ESPHome's WiFi component initializes from YAML during setup and cannot be changed at runtime, so the device was stuck on the YAML placeholder (`configured-via-nvs`).

**Solution (implemented):** ESPHome exposes a public runtime API, and the `improv` provisioning components use it. `nvs_secrets` calls it after reading NVS:

```cpp
#ifdef USE_WIFI
  wifi::global_wifi_component->save_wifi_sta(wifi_ssid_, wifi_password_);
#endif
```

Why it works:
- `save_wifi_sta()` replaces the STA config with the given credentials, persists them to ESPHome preferences, and calls `connect_soon_()` for an immediate reconnect.
- Setup ordering is correct by construction: `nvs_secrets` is at `setup_priority::AFTER_WIFI` (200.0f) and the WiFi component is at `setup_priority::WIFI` (250.0f), so `global_wifi_component` is already initialized when `nvs_secrets::setup()` runs.
- The call is guarded by `#ifdef USE_WIFI` so thread-only configs (no WiFi component) still compile.

**Result:** a single generic firmware binary connects every device to the real network using per-device credentials from NVS -- no per-device recompilation, no provisioning portal needed.

## Flash Encryption & eFuses - Production Enhancement (TODO)

### What are eFuses?

**eFuse = Electronic Fuse (one-time programmable bit in ESP32 silicon)**

- Burned directly into chip during manufacturing or first boot
- Once written -> **permanently locked** (cannot be unwritten or changed)
- Hardware-protected by ROM bootloader (before your code runs)
- Each chip has unique random key (per-device security)

### Current State vs Production

**Current (Development):**
- NVS data is plaintext in flash
- Acceptable for lab/testing environment
- Easy to reflash and debug devices

**Production (Future):**
```
Enable flash encryption:
  1. Add to menuconfig: Security -> Flash Encryption -> Development Mode
  2. First flash: ROM bootloader generates random key, burns to eFuses
  3. Key is locked (read-protected)
  4. All subsequent flash I/O transparently encrypted/decrypted
  5. NVS data automatically encrypted with device-specific key
```

### Security Impact

```
Without Flash Encryption:
  Attacker: "I'll read the flash directly with a programmer"
  Result: Plaintext NVS data extracted (ota_password, api_key, etc.)

With Flash Encryption (eFuse-protected key):
  Attacker: "I'll read the flash directly with a programmer"
  Device: "Here's encrypted data (looks like garbage)"
  Attacker: "I'll extract the encryption key from eFuses"
  Device: "Nope, eFuses are read-protected in release mode"
  Attacker: "I'll physically extract the key from silicon"
  Cost: $$$,$$$ and specialized equipment
```

### TODO: Flash Encryption Implementation

- [ ] Test flash encryption on dev devices (Development Mode)
- [ ] Verify transparent encryption/decryption of NVS works
- [ ] Test device reflashing with encrypted flash
- [ ] Document eFuse burn procedure and recovery
- [ ] Implement release-mode lockdown for production deployment
- [ ] Create per-device eFuse programming guide
- [ ] Test that firmware updates preserve NVS encryption

**Why not implemented yet:**
- Development/testing friction (limited reflash capability)
- Risk of bricking device if eFuse key is lost
- Current threat model (firmware extraction) is addressed without it
- Production-only feature (adds complexity for testing phases)

**When to implement:**
- Product hardening before production deployment
- When shipping to untrusted locations (requires physical security)
- As part of secure boot implementation (firmware signature verification)

## Testing Checklist

Before requesting human approval:
- Run actual flashing against devices (not just compilation)
- Verify Home Assistant entities are updated correctly
- Test edge cases (offline devices, mismatched MAC suffixes, etc.)
- Check that logs are written to correct locations
- Verify that prompts appear and accept user input correctly
- Verify all new features work as documented
- Check for any regressions in existing functionality

## Code Quality & Validation

### ShellCheck: Shell Script Validation

**All shell scripts must pass shellcheck with NO warnings**, including stylistic recommendations.

**Command to validate all scripts:**
```bash
find . -name "*.sh" -type f ! -path "./.git/*" ! -path "./resources/*" -print0 | xargs -0 shellcheck -x
```

**When to run:**
- Before committing any shell script changes
- When adding new .sh files
- Periodically as part of code review

**Key rules we follow:**

| Code | Rule | Why |
|------|------|-----|
| SC2155 | Declare and assign separately | Separates variable declaration from command substitution to prevent masking exit codes |
| SC2004 | Remove $() from arithmetic | Arithmetic expansion doesn't need command substitution syntax |
| SC2059 | Don't use variables in printf format string | Format strings should be literal; use arguments for data |
| SC2064 | Use single quotes in trap | Prevents variable expansion when trap is SET (should expand only when triggered) |
| SC2034 | Remove unused variables | Reduces noise and makes intent clearer |
| SC2038 | Use find with -print0 / xargs -0 | Handles filenames with spaces and special characters safely |
| SC2259 | Avoid redirecting piped output | Redirects in pipes override earlier redirections unexpectedly |
| SC2015 | Avoid A && B \|\| C patterns | Can silently fail if B exits with error; use if/then instead |

**Examples of fixed patterns:**

```bash
# SC2155: Declare and assign separately
# [FAIL] WRONG
local_var=$(command) && echo "ok"

# [OK] CORRECT
local_var=$(command)
echo "ok"

# SC2004: Remove $() from arithmetic
# [FAIL] WRONG
result=$(($(echo "5") + 3))

# [OK] CORRECT
result=$((5 + 3))

# SC2059: Use literal format string
# [FAIL] WRONG
printf "$message_template" "$arg"

# [OK] CORRECT
printf '%s\n' "$message_template"
# or with literal format:
printf 'Value: %s\n' "$arg"

# SC2064: Single quotes in trap
# [FAIL] WRONG
trap "cleanup $temp_file" EXIT

# [OK] CORRECT
trap 'cleanup "$temp_file"' EXIT
# Explanation: Single quotes prevent $temp_file expansion at trap SET time,
# allowing it to expand at trap TRIGGER time with the actual value
```

### References

- ShellCheck: https://www.shellcheck.net/
- ShellCheck Wiki: https://www.shellcheck.net/wiki/

## References

- mDNS discovery: `avahi-browse(1)` man page
- ESPHome YAML: https://esphome.io (substitutions, name_add_mac_suffix)
- Home Assistant WebSocket API: `config/entity_registry/*` commands
- Project version injection: `scripts/iotstack-version.sh`
- Failsafe YAML artifacts: `scripts/failsafe-yaml.sh`
- Flash assessment: `iotstack.sh` `_flash_assess_device`, `_flash_production_matches_build`
