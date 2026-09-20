# otbr (OpenThread Border Router)

Flash a Raspberry Pi 4B with Ubuntu Server 26.04 LTS pre-configured as an OpenThread Border Router (OTBR), using an ESP32-C6 as the Radio Co-Processor (RCP). Combined with a UPS Hat, batteries, and a small USB keypad, this makes a purpose-built Thread OTBR with Bluetooth+Thread commissioning capability via the chiptool snap.

Part of iotstack -- invoked as `iotstack otbr <command>`, not as a standalone project.

## Key commands

```bash
# Full flash (or cloud-init-only if Ubuntu Server already present)
iotstack otbr flash /dev/sdX

# Force full reflash
iotstack otbr flash -f /dev/sdX

# Skip confirmation prompt
iotstack otbr flash -y /dev/sdX

# Use an alternate iotstack environment (~/.iotstack/environments/pangolin.env)
iotstack -env=pangolin.env otbr flash /dev/sdX

# Incus VM test (native x86_64, faster)
iotstack otbr vm x64

# Incus system container test
iotstack otbr vm x64 --container

# Tear down Incus instance
incus delete otbr-test-x64 --force   # or otbr-test-ct

# Docker on bare metal (Ubuntu Server/Desktop; installs Docker CE + nginx)
iotstack otbr docker

# Snap on bare metal (Ubuntu Server/Desktop; installs/configures openthread-border-router snap)
iotstack otbr snap [help|start|stop|restart|ufw|info]   # bare 'snap' prints help

# OTBR instances running on this host: snap, docker, incus vm x64/arm64 (-a: include stopped)
iotstack otbr list [-a]

# Manage which hosts (Home Assistant, Matter server, other OTBRs) may talk to the Thread mesh
iotstack otbr snap ufw [apply|list|add <name> <addr>...|remove <name> [addr...]]
```

## Environment setup

There is no otbr-specific env file. Configuration comes from the same
iotstack environment as everything else:

- **Settings** (`OTBR_HOSTNAME`, snap channels, MQTT, dongle IDs, etc.) live
  in `~/.iotstack/environments/default.env` -- see `docs/.env.example` for
  the full annotated list. Any setting can also be overridden by exporting
  the same variable in your shell before running `iotstack`.
- **Network secrets** (`WIFI_SSID`, `WIFI_PASSWORD`, `THREAD_DATASET_TLV`)
  come from the iotstack pass store, namespaced by the active `-env=`
  environment and seeded (as `CONFIGURE_ME` placeholders) by `setup.sh`:
  ```bash
  pass edit iotstack/default/common/wifi_ssid
  pass edit iotstack/default/common/wifi_password
  pass edit iotstack/default/common/thread_tlv
  ```

- **Known radios** are cached in pass at
  `iotstack/<env>/otbr/port_paths/stable_port_path`: one
  `/dev/serial/by-id/...` path per line, appended by `iotstack otbr snap start`
  after it verifies a radio (never removed automatically -- `pass edit` to
  prune). `_otbr_load_config()` exports them as `OTBR_PORT_PATHS` (and the
  entry name as `OTBR_PORT_PATHS_ENTRY`); `otbrstack-snap-setup.sh` and
  `flash_rcp.sh` try these before falling back to the vendor-ID scan of
  `/dev/ttyACM*`/`ttyUSB*`, and the snap's `radio-url` uses the by-id path so
  it survives ttyACM renumbering on replug.

`otbr/otbr.sh`'s `_otbr_load_config()` resolves and exports all of this
before an operational command (`vm`, `flash`, `docker`, `snap`) runs.

### Relevant settings

| Variable | Scripts | Purpose |
|----------|---------|---------|
| `THREAD_DATASET_TLV` | all | Thread Active Operational Dataset (hex). From pass store (`common/thread_tlv`); required. |
| `SKIP_HA_THREAD_VERIFY` | vm, flash, docker, snap | `1` skips the Home Assistant Thread dataset check (default `0`); see below |
| `WIFI_SSID` / `WIFI_PASSWORD` | flash | From pass store (`common/wifi_ssid`/`wifi_password`); optional if using Ethernet. |
| `OTBR_HOSTNAME` | flash | Device hostname (default: `otbr-raspi4`) |
| `SSH_PUBKEY` | flash, incus | SSH public key to inject into VM/image |
| `SSH_MGMT_CIDRS` | flash | Space-separated IPs/CIDRs allowed SSH inbound via UFW (empty = allow all) |
| `IDF_PATH` | snap, incus | Path to existing ESP-IDF install (optional); if unset and `idf.py` not in PATH, ESP-IDF is auto-cloned to `~/.iotstack/otbr/cache/esp-idf` |
| `DONGLE_VENDOR` | docker | USB vendor ID for Thread dongle (from `udevadm info`) |
| `DONGLE_PRODUCT` | docker | USB product ID for Thread dongle |
| `DONGLE_SERIAL` | docker | USB serial string for Thread dongle (unique; creates stable symlink) |
| `DONGLE_SYMLINK` | docker | Symlink name under `/dev/` (default: `ttyTHREAD`) |
| `BAUD_RATE` | docker | Serial baud rate (default: `460800`) |
| `INFRA_IF` | snap | Backbone/infrastructure network interface (default: auto-detected) |
| `THREAD_IF` | snap | Thread virtual interface (default: `wpan0`) |
| `THREAD_PEERS_FILE` | snap | Named Thread peers for the ufw rules (default: `~/.iotstack/otbr/thread-peers.conf`) |
| `THREAD_HA_HOST` | snap | Home Assistant host for the `home-assistant` peer (default: pass `ha_url`, exported by `_otbr_load_config`) |
| `MQTT_BROKER` | flash | MQTT broker hostname/IP. When set, Pi registers with HA via MQTT Discovery (restart/shutdown buttons, OTBR agent status, Thread role, uptime). Leave empty to disable. |
| `MQTT_PORT` | flash | MQTT broker port (default: `1883`) |
| `MQTT_USER` | flash | MQTT username (optional) |
| `MQTT_PASSWORD` | flash | MQTT password (optional) |

### Home Assistant Thread dataset check

`cmd_otbr_dispatch` calls `_otbr_verify_thread_dataset_with_ha` (otbr.sh) after
`_otbr_load_config` for `vm`, `flash`, `docker` and `snap` -- the one choke point
before any provisioner runs. It compares the effective `THREAD_DATASET_TLV`
against Home Assistant over the WebSocket API (`ha_websocket.py
verify-thread-dataset`):

- Runs only when pass has a real `ha_url` AND `ha_token` (not empty/`CONFIGURE_ME`).
  Deliberately ignores `PERFORM_HA_DEVICE_REGISTRATION` (`load_ha_credentials_from_pass`).
- HA side: the Thread integration's preferred dataset (`thread/list_datasets` +
  `thread/get_dataset_tlv`), falling back to `otbr/info` `active_dataset_tlvs`.
  The former works while the border router itself is offline (e.g. re-flashing it).
- TLVs are parsed and compared per type, order-independent; HA's non-MeshCoP
  `0x4a` prefix is ignored. Only differing field names are printed -- the values
  hold the network key and PSKc.
- Exit codes of the subcommand: 0 match, 3 mismatch or malformed local dataset
  (aborts provisioning), 1 could not verify (HA down, bad token, no dataset in
  HA; warns and continues).
- A malformed local dataset is rejected before HA is contacted.
- `THREAD_DATASET_TLV` set in the environment is what gets checked, and the
  message says so. `SKIP_HA_THREAD_VERIFY=1` bypasses the check.

## Architecture

Four deployment paths share the same iotstack environment and pass-store secrets:

| Command | Target OS | Runtime | RCP detection |
|---------|-----------|---------|---------------|
| `iotstack otbr flash` | Ubuntu Server 26.04 (Raspberry Pi) | snap (cloud-init) | ESP32-C6 via USB |
| `iotstack otbr snap start` | Ubuntu Server/Desktop (bare metal) | snap (live) | ESP32-C6 or Sonoff |
| `iotstack otbr docker` | Ubuntu Server/Desktop (bare metal) | Docker CE + nginx | any USB dongle via udev symlink |
| `iotstack otbr vm x64` / `iotstack otbr vm arm64` | Incus VM or container (test) | snap | simulated or USB passthrough |

- `iotstack otbr flash` -- downloads Ubuntu Server 26.04 arm64+raspi image, verifies SHA-256, flashes to SD, injects cloud-init NoCloud payload into the `system-boot` partition
- `iotstack otbr snap start` -- detects USB RCP, verifies Spinel firmware, installs and configures the OTBR snap; runs as normal user (`sudo` invoked internally)
- `iotstack otbr docker` -- installs Docker CE, pulls the OTBR image, writes udev rule for stable dongle symlink, sets up nginx reverse proxy, joins Thread network; requires root
- `iotstack otbr vm x64` / `iotstack otbr vm arm64` -- Incus VM or system container test; native x86_64 or arm64
- `incus/` -- cloud-init template for Incus VM and container
- `cache/` -- all third-party downloaded content (see layout below)
- `artifacts/` -- generated shared artifacts (cloud-init output, pyspinel venv)

### Docker architecture notes

`iotstack otbr docker` is designed for **any USB Thread dongle** (Sonoff, ESP32-C6, Silicon Labs, etc.). The dongle is identified by USB vendor/product/serial via udev, which creates a stable `/dev/ttyTHREAD` symlink. nginx exposes the OTBR REST API on `:8080` and the web UI on `:8088`, both proxied from the container's `127.0.0.1` ports.

### Snap architecture notes

`iotstack otbr snap start` prefers an **ESP32-C6** (Espressif vendor ID `303a`) and falls back to a Sonoff dongle (Silicon Labs `10c4:ea60`). It verifies RCP firmware via pyspinel before configuring the snap. The pyspinel venv is shared with other scripts at `~/.iotstack/otbr/artifacts/pyspinel-venv/`.

### `otbr list`

`otbrstack-list.sh` reports OTBR instances on this host, running only unless
`-a`: the snap (`otbr-agent` active), Docker containers (image
`openthread/otbr*` or name `otbr`; `sudo -n` fallback, never prompts), and Incus
instances (`kind` = `incus-vm|container` + `x64|arm64`). Incus instances are
matched by the `user.iotstack-otbr=true` config key `provision_incus.sh` sets, or
an `otbr*` name (older instances). An unreachable incus daemon (user not yet in
`incus-admin` for this shell) is a warning, not a silent skip.

### Snap firewall (ufw)

`otbrstack-snap-firewall.sh` owns the ufw rules for the Thread interface;
`otbrstack-snap-setup.sh` just calls its `apply`. Policy: `wpan0` only talks to
named peers. ufw has no named address sets, so peers live in
`~/.iotstack/otbr/thread-peers.conf` (`<name> <ip|cidr|hostname>...`, full-line
comments only) and each address is expanded into ufw rules whose comment is
tagged `iotstack otbr: <name> ...`:

- `route allow in on wpan0 out on $INFRA_IF to <addr>` and the reverse `from <addr>`
- `allow in on $INFRA_IF proto udp from <addr>` (TREL, ephemeral ports)
- mDNS multicast (`224.0.0.251`, `ff02::fb`, port 5353) on `$INFRA_IF` only
- `route deny out on wpan0` after the peer allows; `insert 1 deny in on wpan0`
- an infra-only ICMPv6 accept in a marked block of `/etc/ufw/before6.rules`

Every `apply` deletes all tagged rules (found via `ufw show added`, since
`ufw status` does not show comments) plus the untagged broad rules earlier
versions added (`route allow in|out on wpan0`, `allow in on wpan0`,
`allow 5353/udp`, the blanket ICMPv6 block), then rebuilds. Hostnames are
re-resolved on each apply. The `home-assistant` peer also gets the host from
pass `ha_url` (`THREAD_HA_HOST`). `snap ufw` skips the HA Thread dataset
check. The mesh is IPv6: an IPv4-only peer never matches Thread traffic.

`deny in on wpan0` also blocks Thread devices reaching services on this host
(e.g. SRP registrations to otbr-agent); if that is ever needed, add an explicit
allow for that port -- it must sit before the deny, so use `ufw insert 1`.

### Home directory layout

Runtime data lives under `~/.iotstack/otbr/` -- inside the shared iotstack
home, but namespaced away from ESP32 device artifacts (`~/.iotstack/artifacts/`
etc.) so the two subsystems don't collide.

```
~/.iotstack/otbr/
  cache/
    ubuntu/server/    <- Ubuntu Server 26.04 arm64+raspi .img.xz and .img (otbr flash)
    snap/             <- openthread-border-router .snap + .assert (all provisioners)
    esp32/rcp/        <- ESP32-C6 RCP app binary (built from esp-thread-br source)
    esp-idf/          <- shallow clone of espressif/esp-idf (auto-cloned if IDF_PATH unset)
    openthread/       <- shallow clone of openthread/openthread; cmake simulation build produces ot-rcp + ot-cli
    ot-rcp-sim/       <- ot-rcp and ot-cli sim binaries (built from cache/openthread/ by otbr vm)
  thread-peers.conf   <- named Thread peers for the snap ufw rules (snap ufw)
  logs/
    <hostname>/       <- per-device log directories (flash sessions, vm runs, etc.)
  artifacts/
    rpi/<hostname>/   <- cloud-init payloads from otbr flash
    x64vm/            <- cloud-init payloads from otbr vm x64 runs
    arm64vm/          <- cloud-init payloads from otbr vm arm64 runs
    pyspinel-venv/    <- auto-created Python venv for RCP Spinel probing
    esptool-venv/     <- auto-created Python venv for ESP32-C6 RCP flashing
```

## Testing (Incus)

`iotstack otbr vm x64` provisions an Incus VM or system container with the same OTBR first-boot sequence, but on native x86_64 -- no emulation overhead.

```bash
iotstack otbr vm x64                          # VM (default), name=otbrvm64
iotstack otbr vm x64 --container              # system container, name=otbr-ct
iotstack otbr vm x64 --vm --name=otbr-test    # custom name
iotstack otbr vm x64 --reprovision            # delete and reprovision
```

**Container-only constraints:**
- `security.nesting=true` is set automatically (required for snapd)
- `modprobe` in the container is a no-op; host kernel must have `cdc_acm`/`cp210x` loaded
- If the OTBR snap's AppArmor profile blocks `/dev/pts/N` for the sim PTY, reconnect the interface manually: `incus exec <name> -- snap connect openthread-border-router:serial-port`

**Prerequisite:** Run `iotstack otbr setup` first (or say yes to incus during
the main `setup.sh`) to install and initialize incus and populate
`~/.iotstack/otbr/cache/snap/`. The Incus provisioner reuses that cache.

## RCP firmware flashing

When an ESP32-C6 is detected, the provisioner always builds from source using the `ot_rcp` example in [esp-thread-br](https://github.com/espressif/esp-thread-br). All three binaries (bootloader + partition table + app) are flashed via `idf.py flash` -- no pre-built binaries required.

### How it works

On every run the provisioner:

1. **Updates ESP-IDF** -- clones to `cache/esp-idf/` on first run, then `git fetch --depth 1` + `install.sh esp32c6` on subsequent runs. Skipped if `idf.py` is already in PATH or `IDF_PATH` points to an existing install.
2. **Updates esp-thread-br** -- clones `cache/esp-thread-br/` on first run, then pulls latest (`git fetch --depth 1` + `reset --hard origin/HEAD` + submodule update). Tracks the HEAD hash before and after.
3. **Rebuilds** only if the esp-thread-br HEAD changed or no prior build artifact exists. Uses `sdkconfig.defaults.otbrstack` with:
   - `CONFIG_OPENTHREAD_RCP_USB_SERIAL_JTAG=y` -- USB JTAG peripheral (`/dev/ttyACM0`)
   - `CONFIG_OPENTHREAD_RADIO=y` + `CONFIG_OPENTHREAD_RADIO_NATIVE=y` -- RCP mode
   - `CONFIG_ESP_COEX_SW_COEXIST_ENABLE=n` -- disable WiFi/BT coexistence
4. **Flashes** only if the freshly built binary differs (sha256) from `cache/esp32/rcp/esp_ot_rcp.bin` (the last-flashed copy). If identical, the connected device is already up to date and flash is skipped.
5. On flash, updates `cache/esp32/rcp/esp_ot_rcp.bin` to reflect what is now on the device.

The baud rate `460800` in the Spinel URL is conventional -- USB CDC-ACM doesn't use host-side baud rates internally. The setting is harmless and expected by the OTBR snap.

## Key constraints

- cloud-init on Ubuntu Server uses the **NoCloud** datasource, which reads `user-data` and `meta-data` from the **root** of the `system-boot` FAT32 partition (not a subdirectory).
- Ubuntu Core 24 intentionally disables cloud-init at first boot -- it is not a viable provisioning target for this approach. Use Ubuntu Server instead.
- Target arch is `arm64` (aarch64). The image is `ubuntu-26.04.4-preinstalled-server-arm64+raspi.img.xz`.
- RCP is an ESP32-C6 connected via USB, communicating over Spinel/HDLC at 460800 baud.

## Code style

- Shell scripts: bash, `set -euo pipefail`, functions for repeated logic
- Avoid hardcoding device paths -- always read from env or detect dynamically
- Log progress to stderr; only actionable output goes to stdout
