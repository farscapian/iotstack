# otbr -- OpenThread Border Router provisioning

Flash a Raspberry Pi 4B with Ubuntu Server 26.04 LTS, pre-configured as an
[OpenThread Border Router](https://openthread.io/guides/border-router) (OTBR).
An ESP32-C6 acts as the Thread Radio Co-Processor (RCP), connected via USB.

This is part of [iotstack](../README.md) -- invoked as `iotstack otbr
<command>`, not as a standalone project. The same iotstack environment and
pass store drive all four deployment paths:

| Command | Where it runs | How |
|---------|---------------|-----|
| `iotstack otbr flash` | Raspberry Pi 4B (SD card) | Ubuntu Server + cloud-init + snap |
| `iotstack otbr snap` | Any Ubuntu host (bare metal) | snap (live install) |
| `iotstack otbr docker` | Any Ubuntu host (bare metal) | Docker CE + nginx |
| `iotstack otbr vm x64` | Incus VM or container (testing) | snap (no hardware needed) |

---

## What you'll need

### Hardware (for the Pi path)

| Item | Notes |
|------|-------|
| Raspberry Pi 4B | Pi 3B also works |
| ESP32-C6 development board | The Thread radio. Connected to the Pi via USB at first boot |
| microSD card | 8 GB minimum, 16 GB+ recommended |
| Ethernet cable | Recommended for first boot. Wi-Fi is supported as a fallback |

### Software on your Linux host (x86-64)

`iotstack otbr setup` (or the OTBR prompts in the main `./setup.sh`) installs
the apt packages, esptool, and incus this needs. It also installs:

- Standard tools: `curl`, `xzcat`, `dd`, `lsblk`, `python3`, `snap`, `rsync`
- QEMU user-mode emulation (for the arm64 chroot step): `qemu-user-binfmt`

If anything is still missing:

```bash
sudo apt-get install qemu-user-binfmt rsync
```

---

## Getting started

### 1. One-time setup

From the iotstack repo root:

```bash
./setup.sh
```

This installs ESPHome, iotstack's pass/GPG stores, and (with a Y/n prompt)
incus, Docker, and snapd for OTBR. It also seeds `wifi_ssid`, `wifi_password`,
and `thread_tlv` in the pass store as `CONFIGURE_ME` placeholders. You can
re-run just the OTBR portion later with `iotstack otbr setup`.

### 2. Configure your network secrets

WiFi and Thread network credentials live in the iotstack pass store,
namespaced by the active environment (`default` unless you're using
`-env=<name>.env`):

```bash
pass edit iotstack/default/common/thread_tlv
pass edit iotstack/default/common/wifi_ssid
pass edit iotstack/default/common/wifi_password
```

- **`thread_tlv`** -- your Thread network's Active Operational Dataset (a hex string).
  If you don't have one yet, generate a new one:

  ```bash
  # On any machine with the OTBR snap or ot-ctl installed:
  snap run openthread-border-router.ot-ctl dataset init new
  snap run openthread-border-router.ot-ctl dataset commit active
  snap run openthread-border-router.ot-ctl dataset active -x
  # Paste the hex output into: pass edit iotstack/default/common/thread_tlv
  ```

  Or if you already have an existing Thread commissioner, export it:

  ```bash
  ot-ctl dataset active -x
  ```

- **`wifi_ssid` / `wifi_password`** -- optional if you're using Ethernet; leave
  the `CONFIGURE_ME` placeholder in place and it's treated as unset.

### 3. Configure your SSH key and other settings

Everything else lives in `~/.iotstack/environments/default.env` -- see
[`docs/.env.example`](../docs/.env.example) for the full annotated list
(`SSH_PUBKEY`, `OTBR_HOSTNAME`, snap channels, MQTT, dongle IDs, etc.). Any
of these can also be overridden by exporting the same variable in your shell
before running `iotstack`.

- **`SSH_PUBKEY`** -- your SSH public key (the contents of `~/.ssh/id_ed25519.pub`
  or similar). This is injected into the Pi image so you can SSH in without a
  password.

### 4. Add an SSH config entry for your Pi

The flash script checks that your `~/.ssh/config` has an entry for the Pi's
hostname (default: `otbr-raspi4`) so you can reach it by name after boot.
If one doesn't exist, the script will offer to create it. You can also add
it manually:

```
# ~/.ssh/config
Host otbr-raspi4
    User ubuntu
    # HostName 192.168.x.y   # optional if you use mDNS / .local hostname
```

---

## Flashing the Raspberry Pi

Insert the microSD card into your Linux host and identify its device path
(`lsblk` or `dmesg | tail` after inserting). It will look like `/dev/sdb`
or `/dev/mmcblk0` -- **never** `/dev/sda` (that's usually your main drive).

```bash
# Standard flash -- asks for confirmation before writing
iotstack otbr flash /dev/sdX

# Force a full reflash even if Ubuntu is already on the card
iotstack otbr flash -f /dev/sdX

# Skip the confirmation prompt (useful for scripting)
iotstack otbr flash -y /dev/sdX

# Set a custom hostname for this device
iotstack otbr flash --hostname=otbr-kitchen /dev/sdX
```

> **Smart re-flash:** If Ubuntu Server is already on the card (detected by the
> `system-boot` partition label), `iotstack otbr flash` skips the image download and
> `dd` step entirely and only rewrites the cloud-init config. This is much faster
> when you just changed a config value.

### What happens during the flash

1. Downloads `ubuntu-26.04-preinstalled-server-arm64+raspi.img.xz` from
   Canonical (cached under `~/.iotstack/otbr/cache/ubuntu/server/` -- only downloaded once).
2. Verifies the SHA-256 of the downloaded image.
3. Expands the root partition to fill the SD card.
4. Runs an arm64 chroot to pre-install packages (`git`, `cmake`, `python3`, etc.)
   and pre-load the ESP-IDF toolchain so the Pi doesn't have to download them at boot.
5. Caches arm64 snaps (`openthread-border-router`, `chip-tool`) and copies them
   to the SD card so first boot can install offline.
6. Writes a cloud-init config into the `system-boot` partition that sets up
   networking, installs and configures the OTBR snap, and seeds the Thread dataset.

---

## First boot

Insert the SD card into the Pi, connect the ESP32-C6 via USB, and power on.

First boot takes **5-15 minutes** depending on internet speed (the Pi may still
need to pull some packages). You can watch progress over SSH:

```bash
# Tail all logs in real time (journald + firstboot log)
iotstack otbr logs -f otbr-raspi4

# Or SSH in and check the firstboot log directly
ssh otbr-raspi4
sudo tail -f /var/log/otbr-firstboot.log
```

### What happens on first boot

1. **Networking** -- eth0 comes up via DHCP (preferred). If Wi-Fi credentials
   were set, wlan0 is configured as a fallback.
2. **RCP firmware** -- an RCP-update service waits for the ESP32-C6 to enumerate,
   then fetches the latest ESP-IDF release, builds the `ot_rcp` firmware, and
   flashes it to the ESP32-C6 if the firmware has changed. Identical firmware
   is detected by SHA-256 and skipped.
3. **Snap install** -- `openthread-border-router` is installed from the pre-loaded
   copy on the SD card (no store download needed). `chip-tool` is also installed
   for Matter commissioning.
4. **OTBR configuration** -- snap interfaces are connected, the radio URL is set,
   the backbone interface is configured, and the service is started.
5. **Thread dataset** -- the TLV from the pass store is committed and the Thread
   interface is brought up.
6. **Firewall** -- UFW is enabled. SSH is allowed from the CIDRs in
   `SSH_MGMT_CIDRS` (or from anywhere if that's empty).

After first boot, an RCP-update service runs on every subsequent boot to
keep the RCP firmware up to date. A weekly timer triggers a reboot to check for
new firmware.

### Checking OTBR status

```bash
ssh otbr-raspi4

# Check Thread state (should be leader, router, or child)
snap run openthread-border-router.ot-ctl state

# Check active dataset
snap run openthread-border-router.ot-ctl dataset active -x

# Check snap service status
snap services openthread-border-router
```

---

## Remote management

```bash
# Tail logs from any otbr-managed device
iotstack otbr logs -f otbr-raspi4

# View last-boot logs (static)
iotstack otbr logs otbr-raspi4

# Reboot the device
iotstack otbr restart otbr-raspi4

# Graceful shutdown
iotstack otbr shutdown otbr-raspi4
```

---

## Testing without hardware (Incus VM)

`iotstack otbr vm x64` provisions an Incus VM with the same OTBR first-boot
sequence -- no Raspberry Pi or ESP32-C6 needed. A simulated RCP (`ot-rcp`) is
built from OpenThread source and used instead of the physical ESP32-C6.

**Prerequisites:** incus installed and initialized -- `iotstack otbr setup`
(or `iotstack otbr vm x64` on its own will offer to install it).

```bash
iotstack otbr vm x64             # VM (default), instance name: otbrvm64
iotstack otbr vm x64 --container # system container (faster), name: otbr-ct
iotstack otbr vm arm64           # arm64 VM (QEMU-emulated, slower)
```

The first run clones and builds the OpenThread simulator (~5 min). Subsequent
runs reuse the cached binary at `~/.iotstack/otbr/cache/ot-rcp-sim/ot-rcp`.

To tear down an instance:

```bash
incus delete otbrvm64 --force
```

### Running the test suite

```bash
sudo ./otbr/tests/test_otbr_vm.sh                 # full test, x64 VM
sudo ./otbr/tests/test_otbr_vm.sh --no-peer-test  # skip neighbor exchange (T6)
```

Six tests verify: Ubuntu 26.04 running, OTBR snap installed, all services
active, Thread state is leader/router/child, dataset TLV committed, and
neighbor table has >=1 entry (T6, requires `ot-cli` binary).

---

## Bare-metal snap (`iotstack otbr snap`)

Installs and configures the `openthread-border-router` snap on any Ubuntu host
with a USB Thread radio attached. Runs as your normal user -- `sudo` is invoked
internally only where needed.

**Supported radios (auto-detected):**
1. ESP32-C6 (USB vendor `303a`) on `/dev/ttyACM0`
2. Sonoff Dongle-E / CP210x (Silicon Labs `10c4:ea60`) on `/dev/ttyUSB0`

```bash
iotstack otbr snap
```

The script detects the radio, verifies its Spinel firmware (flashing the
ESP32-C6 if needed), installs and configures the snap, and commits the Thread
dataset. Optional settings (`~/.iotstack/environments/default.env`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `INFRA_IF` | auto (default route) | Backbone network interface |
| `THREAD_IF` | `wpan0` | Thread virtual interface name |

---

## Bare-metal Docker (`iotstack otbr docker`)

Installs Docker CE, pulls the OTBR container image, writes a stable udev
symlink for the USB dongle, and sets up nginx as a reverse proxy. Run as root.

```bash
iotstack otbr docker
```

Exposes: REST API on `:8080`, web UI on `:8088`.

Required settings (find values with `udevadm info /dev/ttyACM0`):

| Variable | Purpose |
|----------|---------|
| `DONGLE_VENDOR` | USB vendor ID |
| `DONGLE_PRODUCT` | USB product ID |
| `DONGLE_SERIAL` | USB serial string (unique per device) |

Optional:

| Variable | Default | Purpose |
|----------|---------|---------|
| `DONGLE_SYMLINK` | `ttyTHREAD` | Symlink name under `/dev/` |
| `BAUD_RATE` | `460800` | Serial baud rate |

---

## Environment variable reference

See [`docs/.env.example`](../docs/.env.example) for the full annotated list.
Key variables:

| Variable | Used by | Purpose |
|----------|---------|---------|
| `THREAD_DATASET_TLV` | all | Thread Active Operational Dataset (hex). From the pass store. |
| `SSH_PUBKEY` | flash, vm | SSH public key injected into the image |
| `OTBR_SNAP_CHANNEL` | flash, snap, vm | Snap channel (default: `latest/edge`) |
| `CHIP_TOOL_SNAP_CHANNEL` | flash | chip-tool snap channel (default: `latest/stable`) |
| `WIFI_SSID` / `WIFI_PASSWORD` | flash | Wi-Fi credentials (from the pass store; optional, eth0 is preferred) |
| `OTBR_HOSTNAME` | flash | Device hostname (default: `otbr-raspi4`) |
| `SSH_MGMT_CIDRS` | flash | Space-separated CIDRs for SSH access via UFW |
| `HTTP_PROXY` | all | Optional HTTP proxy (e.g. `http://squid.local:3128`) |
| `INFRA_IF` | snap | Backbone interface (default: auto-detected) |
| `DONGLE_VENDOR/PRODUCT/SERIAL` | docker | USB dongle identification |

---

## Repository layout

```
otbr.sh                    # iotstack subcommand dispatcher (sourced by ../iotstack.sh's cmd_otbr)
scripts/
  flash-piotbr.sh             # Raspberry Pi SD card flasher (called by iotstack otbr flash)
  provision_incus.sh          # Incus VM/container provisioner (called by iotstack otbr vm)
  otbrstack-snap-setup.sh     # Bare-metal snap provisioner (called by iotstack otbr snap)
  otbrstack-docker-setup.sh   # Bare-metal Docker provisioner (called by iotstack otbr docker)
  commission.sh               # Standalone dev tool: commission a Thread network over SSH
  run_rpiotbr_cycle.sh        # Standalone dev tool: flash + boot-probe + log-stream cycle
  flash_rcp.sh                # ESP32-C6 RCP firmware builder and flasher
  verify_rcp.py               # Spinel probe (checks if RCP firmware responds correctly)
tests/
  test_otbr_vm.sh       # Integration test suite for Incus provisioning

~/.iotstack/otbr/           # Runtime data (created on first `iotstack otbr` run)
  cache/                # Downloaded images, snaps, firmware
  logs/                 # Per-device and per-session log files
  artifacts/            # Generated cloud-init payloads, pyspinel/esptool venvs
```

Configuration and secrets live alongside the rest of iotstack:
`~/.iotstack/environments/default.env` and the `iotstack/<env>/common/*`
pass-store entries -- see [Configuration](../docs/configuration.md) and
[Secrets](../docs/secrets.md).
