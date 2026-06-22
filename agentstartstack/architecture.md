# Architecture

The `update_devices.sh` script is a batch OTA flash tool for managing multiple ESPHome devices discovered via mDNS. It supports device renaming, role reassignment, and Home Assistant entity ID recreation.

The `iotstack.sh` CLI tool provides a user-friendly wrapper around this script with device roles (defined in `roles.conf`).

**Development process:** see [workflow.md](workflow.md) for Grok clones, commit/push policy, and git sync. Tagged releases use annotated git tags (e.g. `v0.1.0`); firmware `project_version` is derived from the latest tag at compile time.

## Core architecture

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
- `yaml_name`: YAML filename (e.g., `bleproxy.yaml`, `.iotstack-bootstrap-esp32c6.yaml`)
- `yaml_sha`: last 10 hex chars of SHA256 over YAML + `yamls/external_components/` + `yamls/common/` + **current git tag** (cache key)
- `binary_sha`: last 10 hex chars of SHA256 of compiled `firmware.bin`
- `image_hash`: 8-char hex ESPHome image hash (ESPHome `config_hash`; primary runtime comparison key)

Per-device build cache also at `~/.iotstack/logs/<device>.build.cache` (used by `update_devices.sh`).

**Cache invalidation:**
- Changes to any device YAML, `external_components/`, or `common/` package
- New git tag or commit (`iotstack_project_version` folded into `yaml_sha` via `scripts/iotstack-version.sh`)
- ESPHome version change (`update_devices.sh` per-device cache)
- Set `DISABLE_COMPILATION_CACHE=1` to force recompilation

**Example cache contents:**
```
yaml_name,yaml_sha,binary_sha,image_hash
bleproxy.yaml,a1b5f8e3e2c9,c4f3b1c7e2a8,1a25e0c8
bootstrap.yaml,f9e3fc2375e6,cc50a183d757,3ea7c88a
```

### Serial Flash Baud Rate (per chip)
`esp_esptool_baud_for_chip()` in `scripts/esp-serial.sh` selects the rate:

| Chip | Baud | Rationale |
|------|------|-----------|
| **ESP32-C6** (XIAO) | **9600** | Higher rates corrupt large firmware transfers (~52KB+ into 807KB) |
| **ESP32-S3 / S2** | **460800** | USB CDC / DevKit bridges; 9600 often yields no serial data |

Override with `IOTSTACK_ESPTOOL_BAUD` for experiments. Flash logs include the baud in use.

**Flash params:** `esp_esptool_flash_params_for_build()` reads mode/freq/size from `.pioenvs/<name>/flash_args` (often **dio / 80m / 16MB** on ESP32-S3 DevKit). Used by `_flash_bootstrap_esptool` write-flash steps.

Bootstrap serial flash writes `bootloader.bin`, `partitions.bin`, **OTA init at `0xd000`** (`esp_ota_init_bin_for_build()`), and bootstrap `firmware.bin`.

### Session registry (agent monitoring)

`create_log_watch_append()` writes one TSV line per invocation to `~/.iotstack/logs/sessions.watch` (`IOTSTACK_SESSION_WATCH`). Agents use it to discover new runs and tail `session_log` / `serial_log` columns. Details: `workflow.md` § Watching live iotstack runs.

### YAML Configuration
- ESPHome devices are configured via YAML files in `yamls/` (one file per role, e.g. `bleproxy.yaml`, `matrixdisplay.yaml`)
- `esphome.name` is the role name; `name_add_mac_suffix: true` produces hostnames like `bleproxy-8238cc`
- **Production YAMLs must not include `ota:`** -- OTA server lives only on bootstrap firmware; production is updated via bootstrap-mediated OTA
- **No `safe_mode:`** -- boot-loop recovery is handled by `partition_manager`
- **No `factory_reset` button** -- physical reset is `common/boot_button.yaml`

### Project Version (Build-Time Git Tag)

All role YAMLs use a substitution variable injected before every `esphome compile`:

```yaml
substitutions:
  project_version: "0.0.0-dev"  # placeholder in source; overridden at compile time
esphome:
  project:
    version: "${project_version}"
```

**Resolution** (`scripts/iotstack-version.sh`, `iotstack_git_tag()`):
- Latest annotated tag via `git describe --tags --abbrev=0` (e.g. `v0.1.0`)
- Fallback `untagged` when no tags exist

**Injection:** `iotstack_prepare_compile_yaml()` copies the source YAML to a temp file (`yamls/.temp-compile-<role>.yaml.<pid>`) and patches `project_version` with `sed`. Source YAMLs in git stay at `0.0.0-dev`; only compile-time copies get the real tag.

**Cache invalidation:** compilation caches invalidate when the tag changes (tag is folded into the `yaml_sha` cache key). Commits that do not create a new tag do NOT trigger recompilation -- this is intentional. To force a rebuild, create a new tag or set `DISABLE_COMPILATION_CACHE=1`.

**Gotcha:** compile-time copies must live under `yamls/` (e.g. `yamls/.temp-compile-matrixdisplay.yaml.<pid>`), not `/tmp`, because ESPHome resolves `!include common/...` relative to the YAML file path.

`project_version` is advertised in mDNS TXT and used as a **fallback** when `config_hash` is unavailable. It is not the primary flash/update comparison key.
