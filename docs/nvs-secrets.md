# NVS and Secrets

**Secrets are stored in device flash (NVS partition), not in firmware binary or YAML files.**

## Implementation status (updated 2026-06-14)

| Component | Status | Notes |
|-----------|--------|-------|
| NVS partition write | [OK] Working | Writes proper NVS binary format to the `nvs` partition offset read from the generated partition table |
| NVS key-value format | [OK] Working | Uses esp_idf_nvs_partition_gen; keys written under the **`iotstack` namespace** (see "NVS Namespace" pitfall below) |
| OTA password from NVS | [OK] Working | nvs_secrets component loads and applies password |
| WiFi credentials from NVS | [OK] Working | nvs_secrets reads SSID+password from NVS and applies them at runtime via `wifi::global_wifi_component->save_wifi_sta()` (see WiFi Credentials From NVS below) |
| Production API key (`prod_api_key`) | [OK] Working | Per-device key from NVS applied at boot (`set_noise_psk`); used for HA API auth |
| Bootstrap API key (`boot_api_key`) | [OK] Working | Per-device noise PSK for the encrypted bootstrap API; written OOB over USB only (see [security.md](security.md) "Bootstrap API encryption"). Needs hardware validation. |
| Flash encryption | [TODO] TODO | Planned for production hardening with eFuses |

## CRITICAL: NVS namespace row required

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
- `CONFLICTS_WITH = ["wifi"]` in the openthread component means a single image cannot do both radios -- WiFi and Thread are **separate bootstrap/production variants** (one radio per image; the C6 runs whichever image is booted). The dynamic partition table sizes each slot to whatever image lands there.

Status: compiles on threadrouter (Thread stack) and on WiFi-only devices (OT code excluded by the guard). **Not yet validated on a live Thread network** -- the runtime `otDatasetSetActiveTlvs` + re-attach sequence (and its timing vs. the OT task spin-up) needs hardware confirmation; the disable->set->enable order may need tuning.

### TODO: production self-recovery into bootstrap

For a device parked where its production radio is weak, the production image
can't be rescued remotely (only via the physical boot button). A production
image *could* self-recover: watch connectivity (e.g. `wifi_signal` below a
threshold for N minutes, or repeated disconnects) and, on sustained failure,
call `partition_manager::boot_bootstrap()` to drop into the bootstrap image --
which (if Thread) is reachable over the mesh for re-flash. ESPHome has the hooks
(`wifi` `on_disconnect`, signal sensors, `interval:`). Not implemented; would
live as an optional shared package so each device opts in.

### TODO: cascading bootstrap (3-tier, future)

The generalization of the above. Three app partitions forming a recovery
cascade, from most-reliable at the base to production at the top:

```
ota_0  bootstrap-thread   (base -- slowest OTA, presumed most reliable / best range)
ota_1  bootstrap-wifi     (faster recovery)
ota_2  production
```

Cascade (each tier detects its own failure and steps the boot slot DOWN, never
up; needs a boot-loop guard via the safe_mode counter):
- production fails to stay connected -> boot `bootstrap-wifi`
- `bootstrap-wifi` can't get on WiFi within a timeout -> boot `bootstrap-thread`
- `bootstrap-thread` is the floor (retries; never steps down)

**Only deploy all three IF they fit the flash.** Use the dynamic partition
sizing to sum bootstrap-thread + bootstrap-wifi + production; if the total fits
(comfortable on 8MB; tight on 4MB -- production drops from ~2.88MB to ~2.2MB,
still fits bleproxy 1.40MB), build the 3-tier layout. Otherwise fall back to the
current 2-partition scheme (bootstrap-wifi + production). The decision is made at
provision time from the measured image sizes.

**The hard part -- OTA targeting with 3 OTA slots.** `esp_ota_get_next_update_partition()`
cycles ota_0->ota_1->ota_2->ota_0, so:
- OTA run from `bootstrap-wifi` (ota_1) -> lands in `production` (ota_2) [OK] -- normal
  updates work out of the box.
- OTA run from `bootstrap-thread` (ota_0) -> lands in `bootstrap-wifi` (ota_1) [FAIL].
  A deep Thread-only recovery OTA (WiFi dead) therefore needs **explicit
  partition selection** in the OTA backend (ESPHome uses get_next and doesn't
  expose a target), which is the one piece beyond a weekend.

**Naming:** with the cascade, rename the current `bootstrap` -> `bootstrap-wifi`
(touches the mDNS name `bootstrap-<mac>`, the `iotstack/roles/bootstrap/...` pass
paths, the flash wait logic, and the `bootstrap` partition label) and add
`bootstrap-thread`. Do the rename *with* the cascade, not piecemeal.

**Build order:** (1) matched 2-variant bootstrap (wifi/thread) + validated
Thread-from-NVS; (2) single-step self-recovery trigger (above); (3) full 3-tier
cascade + the explicit-OTA-target work. Keep `partition_manager`'s boot logic
able to target a *specific* slot (not just toggle) so it's cascade-ready.

Architecture:
1. **Pass store** (`~/.iotstack/.pass/`): Role-based master secrets (encrypted)
   - One secret per role (e.g., `iotstack/roles/bleproxy/ota_password`)
   - Generated during setup.sh, stored securely
   - Never written to disk unencrypted

2. **NVS partition** (device flash): Device-specific secrets
   - Unique per device: `sha256(role_secret | device_mac)`
   - Written after firmware flash via `write-nvs-secrets.sh`
   - Persists across firmware updates; separate from firmware binary
   - Offset and size from generated partition table ([partitions.md](partitions.md)), not hardcoded

3. **YAML placeholders** (in git, compile-time only)
   - Role YAMLs use safe placeholder values checked into the repo
   - Real credentials are read from NVS at runtime, not compiled into firmware

### Provisioning workflow

```
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

## NVS fundamentals

### What is NVS?

**NVS = Simple key-value store on ESP32 flash memory (NOT encrypted by default)**

NVS is NOT:
- A TPM (Trusted Platform Module)
- Hardware-encrypted storage
- Protected from physical flash reads
- Device-certificate based encryption

NVS IS:
- A key-value database on reserved flash partition (see [partitions.md](partitions.md))
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
  iotstack/roles/bootstrap/ota_password = "base_secret_xyz"
  
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
- Applies WiFi SSID/password from NVS via `save_wifi_sta()` (see **WiFi Credentials From NVS** above)
- Status: [OK] OTA password working, [OK] WiFi credentials read from NVS and applied to the WiFi component

Future hardening: [flash-encryption.md](flash-encryption.md).
