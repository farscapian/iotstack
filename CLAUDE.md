# ESP32 ESPHome Device Management — Development Notes

## Naming Convention

**Always use lowercase "iotstack"** — never "IoT Stack" or "iotStack". Examples:
- ✓ `iotstack update bleproxy`
- ✓ `iotstack devices`
- ✗ ~~IoT Stack~~
- ✗ ~~iotStack~~
- ✗ ~~IOTSTACK~~

This applies in code comments, documentation, help text, and all user-facing messages.

## Environment Variables

### Environment File Configuration

Environment variables are stored in `~/.iotstack/.env` and loaded automatically on every `iotstack` invocation.

**Setup:**
```bash
# View available options
cat resources/.env.example

# Create default configuration (done automatically by setup.sh)
cp resources/.env.example ~/.iotstack/.env

# Edit to customize
nano ~/.iotstack/.env
```

**Using Multiple Configurations:**
```bash
# Create alternate configuration
cp ~/.iotstack/.env.example ~/.iotstack/pangolin.env
# Edit pangolin.env with specific settings

# Use alternate config for a command
iotstack -env=pangolin.env flash recovery /dev/ttyACM0

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
iotstack -env=debug.env flash recovery /dev/ttyACM0

# Option 3: Set for single command
DISABLE_COMPILATION_CACHE=1 iotstack flash recovery /dev/ttyACM0
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

### Compilation Cache

Cache stored at `~/.iotstack/compilation-cache.csv` (CSV format with headers):

**Columns:**
- `yaml_name`: YAML filename (e.g., `recovery.yaml`)
- `yaml_sha`: SHA256 hash of YAML + all `yamls/external_components/` files (cache key)
- `binary_sha`: SHA256 of compiled `firmware.bin`

**Cache invalidation:**
- Changes to any YAML file automatically invalidate cache
- Changes to any file in `yamls/external_components/` automatically invalidate cache
- Set `DISABLE_COMPILATION_CACHE=1` to force recompilation

**Example cache contents:**
```
yaml_name,yaml_sha,binary_sha
recovery.yaml,75e67037f9e3fc23...,a183d757ba74cc50...
bleproxy.yaml,8f3e2c9d4a1b5f...,c9d2a8e7f3b1c4...
```

### Serial Flash Baud Rate: 9600 (Critical)
**⚠️ IMPORTANT: All esptool flash operations use 9600 baud, NOT 57600 or 115200**

Testing with ESP32-C6 devices revealed that higher baud rates cause data corruption during large firmware transfers:
- **57600 baud**: Firmware corruption starts ~52KB into 807KB transfers
- **115200 baud**: Worse corruption, more frequent failures
- **9600 baud**: 100% reliable, full file integrity verified

**Why?** Higher baud rates accumulate bit errors over long transfers. A single bit flip during 789KB transfer is catastrophic. Conservative 9600 baud prevents this.

**Performance tradeoff**: 57600 (~2.5 sec) vs 9600 (~10-15 sec). Reliability >> Speed.

If baud rate changes are ever considered, empirically test with actual 789KB firmware transfers and verify full SHA256 checksums.

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

### Device Mapping (roles.conf)
Device roles are defined in `roles.conf`. Network type (WiFi or Thread) is automatically detected by introspecting the YAML file:
```
bleproxy=yamls/bleproxy.yaml
mmwave=yamls/mmwave.yaml
sendspin=yamls/sendspin.yaml
ledlightstrip=yamls/ledlightstrip.yaml
threadrouter=yamls/threadrouter.yaml
```

Format: `<role>=<yaml-path>`
- Network type determined from YAML content: `wifi:` section → WiFi, `openthread:` section → Thread
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

## Partition Configuration — Dynamically Calculated

**Partition sizes are calculated AFTER firmware compilation based on actual firmware binary sizes.**

### Calculation Process

1. **Compile failsafe firmware** (`smart_compile`)
   - Compiles `yamls/recovery.yaml` via `esphome compile`
   - Output: `firmware.bin` in build directory

2. **Calculate partition sizes** (`_calculate_partition_sizes`)
   - Reads `firmware.bin` size
   - Recovery partition = firmware_size (rounded up to 4KB boundary for flash alignment)
   - Production partition = same size as recovery (for symmetry)
   - Production offset = calculated from recovery offset + recovery size

3. **Generate partition table** (`_generate_partition_table`)
   - Creates `~/.iotstack/iotstack_partition_table.csv` with calculated sizes/offsets
   - Accessed via symlink at `yamls/iotstack_partition_table.csv` (for ESPHome compatibility)
   - NVS (16KB, fixed) and OTA data (8KB, fixed) unchanged
   - Recovery and production partitions sized to actual firmware

4. **Use partition table**
   - `write-nvs-secrets.sh` reads NVS size from generated CSV
   - Flash operations use the calculated offsets
   - ESPHome finds partition table via symlink

### Why This Approach?

- ✅ **No hardcoded partition sizes** — All calculated from actual firmware
- ✅ **Zero chance of misalignment** — Partition table always matches firmware reality
- ✅ **Firmware changes auto-handled** — Larger firmware = larger partition, calculated automatically
- ✅ **Audit-friendly** — Partition table shows exactly what firmware needs
- ✅ **Exact fit** — Partitions are only as large as firmware needs (no wasted flash)
- ✅ **Artifacts in ~/.iotstack** — Generated files stored in user home, not repo

### Files Involved

- `smart_compile()`: Calls partition calculation after compilation
- `_calculate_partition_sizes()`: Determines sizes from firmware binary
- `_generate_partition_table()`: Creates CSV with calculated values
- `~/.iotstack/iotstack_partition_table.csv`: Generated output (actual file)
- `yamls/iotstack_partition_table.csv`: Symlink to ~/.iotstack/iotstack_partition_table.csv (for ESPHome)

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
- Build cache: `~/.iotstack/logs/<device>.build.cache` (SHA256 + version)
- Cache invalidated if YAML or ESPHome version changes

## Common Pitfalls & Solutions

| Issue | Root Cause | Solution |
|-------|-----------|----------|
| Prompt doesn't appear, script hangs | User input code runs after stdout redirect | Use `>&2` for messages, `</dev/tty` for input |
| `grep: invalid option -- '$'` | Pattern starts with dash (e.g., `-19b164$`) | Use `grep -- ` to stop option processing |
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

### Research FIRST, Then Debug

**When encountering a persistent problem, do targeted internet research BEFORE systematic debugging.**

Example: Baud rate issues with ESP32 flash corruption
- ❌ Bad: Try 460800 → 115200 → 57600 (3+ hours of testing)
- ✅ Good: Research "ESP32 firmware corruption baud rate" → find 9600 standard (5 minutes)

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
| NVS partition write | ✅ Working | Writes proper NVS binary format to the `nvs` partition offset read from the generated partition table |
| NVS key-value format | ✅ Working | Uses esp_idf_nvs_partition_gen; keys written under the **`iotstack` namespace** (see "NVS Namespace" pitfall below) |
| OTA password from NVS | ✅ Working | nvs_secrets component loads and applies password |
| WiFi credentials from NVS | ✅ Working | nvs_secrets reads SSID+password from NVS and applies them at runtime via `wifi::global_wifi_component->save_wifi_sta()` (see "WiFi Credentials From NVS" below) |
| API encryption key | ✅ Stored | Safely written to NVS, awaiting API component support |
| Flash encryption | ⏳ TODO | Planned for production hardening with eFuses |

### 🚨 CRITICAL PITFALL: NVS keys must be written under a named namespace

`esp_idf_nvs_partition_gen` accepts a CSV with **no `namespace` row without erroring** (exit 0), but it then writes every key into reserved namespace-index 0 (the internal namespace registry). No named namespace exists on the chip, so at runtime `nvs_open(<any name>, NVS_READONLY, ...)` returns `ESP_ERR_NVS_NOT_FOUND` and the keys are **unreachable** — even though they are physically present in flash.

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

### WiFi Credentials From NVS (✅ Solved)

The earlier limitation — "ESPHome's WiFi component can't take credentials at runtime" — is **solved**. The trick is the public WiFi API plus correct setup ordering:

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
  ↓
  Role secrets generated & stored in pass
  ↓
iotstack flash <device> <role>
  ↓
  ↓
  Firmware flashed to device via esptool
  ↓
  write-nvs-secrets.sh:
    - Retrieves role secret from pass
    - Derives device-specific secret (sha256 | mac)
    - Writes to device NVS partition
  ↓
Device boots
  ↓
  nvs_secrets component reads from NVS
  ↓
  Device has unique, secure secrets
```

Key benefit: **Single firmware binary for all devices, unique secrets per device, no disk exposure of real secrets.**

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
- `scripts/iotstack-secrets` — manual secret updates
- `scripts/ha-websocket-query.sh` — syncing secrets from YAML
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
- ✅ **Firmware binary extraction** → Attacker can't derive device passwords (not compiled in)
- ✅ **Hardcoded secrets in code** → Eliminated, now device-specific in NVS
- ✅ **Single password for all devices** → Each device has unique derived password
- ❌ **Physical flash chip extraction** → NVS data is plaintext (not protected)

### Device-Specific Secret Derivation

```
Role-based secret (in pass store):
  iotstack/roles/recovery/ota_password = "base_secret_xyz"
  
Device-specific computation (in-memory during flash):
  device_password = sha256("base_secret_xyz" | "1af95c")[0:32]
  
Stored in NVS only:
  ota_password = "a1b2c3d4e5..." (unique to this device)
  
Firmware at startup:
  nvs_secrets component reads NVS
  └─ Sets OTA service password from NVS value
  └─ Loads WiFi and API credentials
  └─ Enables device-specific OTA authentication
```

### Security Properties

| Threat | Protection | Attack Cost |
|--------|-----------|------------|
| Firmware binary extraction | ✅ No compiled passwords | Can't derive from binary |
| Firmware disassembly | ✅ No hardcoded secrets | Even reverse-engineers see nothing |
| Device password reuse | ✅ Unique per device (derived) | Each device has different password |
| Pass store compromise | ✅ Role secret stays encrypted | Still need device MAC to derive |
| Physical flash read | ❌ NVS plaintext | Moderate (requires soldering programmer) |
| Flash encryption bypass | ⚠️ Future enhancement (see TODO) | Would require eFuse key extraction |

### Custom NVS Component

One custom ESPHome component reads from NVS at runtime:

**nvs_secrets**: Reads all device-specific secrets from NVS
- Reads `ota_password`, `wifi_ssid`, `wifi_password`, `api_key` from NVS partition
- No secrets in firmware binary (all come from device flash at runtime)
- Dynamically sets OTA authentication password from NVS
- Logs what was found (for debugging)
- Applies WiFi SSID/password from NVS to the WiFi component at runtime (see below)
- Status: ✅ OTA password working, ✅ WiFi credentials read from NVS and applied to the WiFi component

### WiFi Credential Challenge (✅ Solved)

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

**Result:** a single generic firmware binary connects every device to the real network using per-device credentials from NVS — no per-device recompilation, no provisioning portal needed.

## Flash Encryption & eFuses - Production Enhancement (TODO)

### What are eFuses?

**eFuse = Electronic Fuse (one-time programmable bit in ESP32 silicon)**

- Burned directly into chip during manufacturing or first boot
- Once written → **permanently locked** (cannot be unwritten or changed)
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
  1. Add to menuconfig: Security → Flash Encryption → Development Mode
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
# ✗ WRONG
local_var=$(command) && echo "ok"

# ✓ CORRECT
local_var=$(command)
echo "ok"

# SC2004: Remove $() from arithmetic
# ✗ WRONG
result=$(($(echo "5") + 3))

# ✓ CORRECT
result=$((5 + 3))

# SC2059: Use literal format string
# ✗ WRONG
printf "$message_template" "$arg"

# ✓ CORRECT
printf '%s\n' "$message_template"
# or with literal format:
printf 'Value: %s\n' "$arg"

# SC2064: Single quotes in trap
# ✗ WRONG
trap "cleanup $temp_file" EXIT

# ✓ CORRECT
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
- Script memory: See `/home/derek/.claude/projects/.../memory/` for architecture notes
