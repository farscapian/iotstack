# ESPHome Device Configs

This repository contains ESPHome firmware configurations for a home automation network built around ESP32-C6 devices. The primary goals are to extend Bluetooth LE coverage throughout the home via Wi-Fi-connected BLE proxy nodes, provide a resilient OpenThread border-router mesh for Matter and Thread devices, deploy mmWave presence sensors, enable synchronized multi-room audio via the Sendspin protocol, and keep all firmware reproducible, version-tracked, and easy to update in bulk. Devices advertise their config hash via mDNS, enabling smart delta updates that skip nodes already running the current build.

## Directory Structure

Device configs are organized by network type:

```
esphome/
├── wifi/
│   ├── wifi-bleproxy.yaml          # ESP32-C6 BLE proxy
│   ├── wifi-mmwave.yaml            # mmWave presence sensor (Wi-Fi)
│   └── wifi-sendspin.yaml          # Multi-room audio speaker
├── thread/
│   ├── thread-router.yaml          # ESP32-C6 Thread router
│   └── thread-mmwave.yaml          # mmWave presence sensor (Thread)
├── secrets.yaml                    # Shared credentials (gitignored)
├── update_devices.sh               # Flash a single device type
└── update_all.sh                   # Flash all device types
```

## Devices

| YAML | Role |
|------|------|
| `wifi/wifi-bleproxy.yaml` | ESP32-C6 BLE proxy — bridges BLE advertisements to Home Assistant over Wi-Fi |
| `thread/thread-router.yaml` | ESP32-C6 Full Thread Device — extends the OpenThread mesh |
| `wifi/wifi-mmwave.yaml` | mmWave presence + vital-signs sensor (Wi-Fi, Seeed MR60BHA2) |
| `thread/thread-mmwave.yaml` | mmWave presence + vital-signs sensor (Thread, Seeed MR60BHA2) |
| `wifi/wifi-sendspin.yaml` | Multi-room synchronized audio speaker via Sendspin protocol (Music Assistant) |

---

## wifi-sendspin

Multi-room audio speaker using the [Sendspin protocol](https://esphome.io/components/sendspin/) introduced in ESPHome 2026.5.0. Pairs with [Music Assistant](https://music-assistant.io/) as the Sendspin server. Audio is streamed over Wi-Fi and synchronized across multiple nodes. Exposes a `media_player` entity in Home Assistant along with now-playing metadata (title, artist, album).

> ⚠ Sendspin is experimental — the protocol and YAML API may change between ESPHome releases.

### Hardware

**Microcontroller:** Seeed XIAO ESP32-C6  
**DAC:** PCM5102A stereo I2S DAC breakout (line-level output, no amplifier)  
**Output:** 3.5mm TRS → powered speaker or Bluetooth speaker AUX input

The ESP32-C6 has no PSRAM; `buffer_size` is reduced from the 1 MB default to 250 KB and `task_stack_in_psram` is disabled accordingly.

### Wiring — PCM5102A → XIAO ESP32-C6

| PCM5102A pin | XIAO ESP32-C6 | Notes |
|---|---|---|
| VCC | 3.3V | |
| GND | GND | |
| BCK | GPIO3 | Bit clock |
| LCK | GPIO4 | Left/right clock (WS) |
| DIN | GPIO5 | I2S data |
| SCK | GND | Ties to GND for internal clock mode — verify solder jumper on board |
| OUT (3.5mm) | — | 3.5mm cable → speaker AUX in |

**SCK jumper:** Most PCM5102A breakouts ship with SCK bridged to GND (internal clock mode). If yours does not, uncomment `i2s_mclk_pin: GPIO2` in the YAML and wire MCLK → GPIO2.

**Why PCM5102A over MAX98357A:** The PCM5102A outputs line-level stereo analog, which is what a 3.5mm AUX input expects. The MAX98357A is an amplified mono output — too hot for AUX and single-channel only.

### Network requirement

TCP port **8928** must be reachable between the Sendspin server (Music Assistant) and each `wifi-sendspin` device.

---

## OTA Update Scripts

### `update_devices.sh`

Discovers all ESPHome devices matching a given config's `esphome.name` via mDNS and OTA-flashes those whose firmware has changed. Version detection uses the `config_hash` advertised in each device's mDNS TXT record — no HTTP calls, no log connection required. A SHA256 cache of each YAML + ESPHome version skips unnecessary recompilation on unchanged configs.

```bash
# Flash devices whose config_hash differs from the current build (default)
./update_devices.sh wifi/wifi-bleproxy.yaml

# Preview what would be flashed without flashing
./update_devices.sh --dry-run thread/thread-router.yaml

# Force-flash all devices regardless of running firmware
./update_devices.sh --no-upgrade-delta wifi/wifi-mmwave.yaml

# Verify all devices match the current build hash; no flashing
./update_devices.sh --verify wifi/wifi-sendspin.yaml

# Control parallelism (default: 4 concurrent flash jobs)
./update_devices.sh --jobs 9 wifi/wifi-bleproxy.yaml
```

| Flag | Default | Description |
|------|---------|-------------|
| `--upgrade-delta` | on | Skip devices already at the current build hash |
| `--no-upgrade-delta` | — | Flash all discovered devices unconditionally |
| `--verify` | — | Check hashes and report pass/fail; no flashing |
| `--dry-run` | — | Compile and print flash plan without flashing |
| `--jobs N` | 4 | Maximum concurrent OTA flash jobs |

### `update_all.sh`

Runs `update_devices.sh` for every device config in the project directory (any `.yaml` with a top-level `esphome:` block). All flags are forwarded.

```bash
./update_all.sh                   # update everything
./update_all.sh --dry-run         # preview across all device types
./update_all.sh --verify          # verify entire fleet
```

### Requirements

- `avahi-browse` (`avahi-utils`)
- `esphome` CLI at `~/.local/esphome/venv/bin/esphome` or on `$PATH`
- `python3` (for Home Assistant integration)
- `python3-websocket` (for entity ID recreation) — installed automatically if needed
- Bash 4.3+ (for `wait -n`)

### Home Assistant integration

If `ha_url` and `ha_token` (long-lived access token) are present in `secrets.yaml`, the script:

1. **Device registry check** — Compares HA-registered devices against the mDNS-discovered set, surfacing any that are registered but not reachable on the network
2. **Entity ID recreation** — When devices are flashed with a new name (e.g., renaming from `wifi-bleproxy` to `c6-wifi-bleproxy`), automatically recreates entity IDs to match the new device name while preserving device metadata (area, labels, custom names)

Entity ID recreation is performed via Home Assistant's official WebSocket API and preserves all device configuration, relationships, and long-term statistics.

```yaml
# secrets.yaml additions
ha_url: "http://homeassistant.local:8123"
ha_token: "eyJ..."
```

### Logs

Logs are organized by YAML config name:

```
~/.ancapistan/esphome/logs/{yaml-name}/
├── {timestamp}.compile.log          # Compilation output
├── {timestamp}-{hash}/              # After successful compilation
│   ├── ttyACM0.log                  # USB serial flash (if applicable)
│   ├── {device1}.log                # OTA flash logs
│   ├── {device2}.log
│   └── ...
└── {yaml-name}.build.cache          # SHA256 + config_hash cache
```

- Compilation logs are separate (no hash in filename until after build)
- Device flash logs are organized by compilation run + resulting hash
- Build cache file prevents unnecessary recompilation of unchanged configs

---

## Secrets

Device credentials live in `secrets.yaml` (gitignored). See ESPHome docs for the expected format.
