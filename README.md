# iotstack — Infrastructure for your SmartHome

iotstack is a command-line tool for deploying and managing a collection of smart home projects built on ESP32 microcontrollers. It provides a unified interface to compile, flash, and update various device types — from ESPHome firmware configurations to Matter commissioning infrastructure and beyond.

With iotstack, you can:
- Deploy and update multiple device types with a single command
- Manage device-specific secrets securely without hardcoding credentials
- Extend your smart home with Bluetooth connectivity, Thread mesh networking, presence detection, and more
- Leverage infrastructure like Thread Routers for multi-device coordination

## Your Smart Home Projects

### BLE Proxy

The **BLE Proxy** gives your home Bluetooth awareness across multiple rooms. It listens for Bluetooth signals from devices throughout your space and relays them to Home Assistant.

**Key capabilities:**
- **Room Presence**: Know which area you or your devices are in based on Bluetooth signal proximity
- **Distributed Bluetooth**: Extend Bluetooth connectivity throughout your home (typical Bluetooth range is 30-100 feet)
- **Matter Commissioning Foundation**: Supports Matter device commissioning flows for physically distant devices, making it easy to commission Bluetooth-enabled Matter devices from anywhere in your home

Each BLE Proxy has independent coverage, and Home Assistant automatically uses the closest one for optimal signal quality.

### Thread Router

The **Thread Router** provides network infrastructure for your Thread mesh. These always-on devices help other Thread devices reach the OTBR (OpenThread Border Router) and maintain a robust, self-healing mesh network.

**Key capabilities:**
- **Mesh Stability**: Ensures Thread devices can reach the border router even if some devices go offline
- **Extended Coverage**: Place routers strategically to extend Thread coverage throughout your home
- **Coordination**: Enables coordinated multi-device automations

For a complete OpenThread Border Router setup, see [otbrstack](https://github.com/farscapian/otbrstack).

### Presence Sensor (mmWave Radar)

Detects people in a room and their distance using millimeter-wave radar. Useful for automations like turning on lights or triggering scenes when someone enters a space.

### In-Development Projects

- **SendSpin Speaker**: Multi-room synchronized audio. [Full documentation →](docs/sendspinspeaker.md)
- **LED Light Strip**: Addressable WS2812B LED strip control. [Full documentation →](docs/ledlightstrip.md)
- **LED Matrix Display**: Text and animation display on LED matrices. [Development notes →](docs/ledmatrixdisplay.md)

---

## Getting Started

### Initial Setup

Set up the `iotstack` command so you can run it from anywhere:

```bash
./setup.sh
source ~/.bashrc
```

This creates a symlink in `~/.local/bin/` and configures your environment. Now you can use `iotstack` from any directory:

```bash
iotstack help         # Show available commands
iotstack update all   # Update all devices
```

### Device Files

Device configurations are YAML files in the `yamls/` directory:

```
yamls/
├── recovery.yaml                    # Recovery/dual-partition mode
├── bleproxy.yaml                    # BLE Proxy (WiFi)
├── threadrouter.yaml                # Thread Router (Thread mesh)
├── mmwave.yaml                      # Presence sensor (WiFi)
├── ledlightstrip.yaml               # LED strip controller (WiFi)
├── sendspin.yaml                    # Multi-room speaker (WiFi)
└── external_components/             # Custom ESPHome components
    ├── nvs_secrets/                 # Reads device credentials from NVS
```

---

## How iotstack Works

When you run `iotstack update`, here's what happens behind the scenes:

1. **Discovery**: Uses mDNS to find devices on your network. Each device advertises itself with a device name and version.

2. **Compilation**: ESPHome compiles your YAML configuration into a firmware binary. iotstack caches builds to avoid recompiling if nothing changed.

3. **Smart Updates**: Compares the compiled firmware's hash against what's on each device. Only devices with mismatched hashes are updated (delta mode).

4. **Parallel Flashing**: Wirelessly flashes firmware to multiple devices in parallel via OTA (Over-the-Air). Thread devices are flashed serially to avoid mesh contention.

5. **Secrets Management**: Device-specific credentials (OTA passwords, API keys) are derived from a role-based secret store and written to the device's NVS (Non-Volatile Storage) partition at flash time. Subsequent OTA updates use the device-specific credentials stored in NVS.

6. **Logging**: Detailed logs for each update are stored in `~/.iotstack/logs/` for troubleshooting.

This architecture keeps credentials out of firmware binaries — each device has unique secrets derived at flash time and stored safely in its flash memory.

---

## Deploying Devices

### The Recommended Order

Deploy devices in this order to build up your infrastructure:

1. **Thread Router first** (if using Thread)
   ```bash
   iotstack flash threadrouter /dev/ttyACM0
   ```
   This establishes your Thread mesh infrastructure for other Thread devices.

2. **BLE Proxy** (for Bluetooth support)
   ```bash
   iotstack flash bleproxy /dev/ttyACM0
   ```
   Place these strategically throughout your home for room-level Bluetooth coverage.

3. **Other devices** (presence sensors, LED strips, etc.)
   ```bash
   iotstack flash mmwave /dev/ttyACM0
   iotstack flash ledlightstrip /dev/ttyACM0
   ```

### Quick Commands

```bash
# Flash a single device via USB serial
iotstack flash threadrouter /dev/ttyACM0

# Update specific devices over-the-air
iotstack update bleproxy                # Update all BLE Proxies
iotstack update mmwave --dry-run        # Preview what would change

# Update everything
iotstack update all

# Reassign a device to a different configuration
iotstack reassign 8dfcac 0f4df4 to mmwave
```

---

## Advanced Topics

### Dual-Partition OTA & Recovery Mode

iotstack uses a dual-partition... firmware or production firmware. This enables safe updates even if production firmware becomes corrupted.

For detailed information, see [Dual-Partition OTA](docs/DUAL_PARTITION_OTA.md).

### Secrets & Credentials

Sensitive information (WiFi passwords, API keys, OTA passwords) is managed securely through:
- **Encrypted pass store** for role-based secrets
- **Device-specific derivation** at flash time
- **NVS partition** storage on device flash

For the complete secrets architecture and configuration, see [Secrets Management](docs/secrets.md).

### Home Assistant Integration (Optional)

Connect iotstack to Home Assistant to:
- Automatically verify device connectivity before updates
- Update entity names after device reassignment
- Preserve automations during firmware updates

Configuration details are in [Secrets Management](docs/secrets.md).

---

## Requirements

On your Linux machine running iotstack, you need:

- **ESPHome**: Firmware compilation (installed automatically via `setup.sh`)
- **Python 3.8+**: For scripts and tools
- **Bash 4.3+**: Shell scripting (standard on most Linux systems)
- **avahi-utils**: For mDNS device discovery (`sudo apt install avahi-utils`)
- **pass**: Password manager for role-based secrets (installed by `setup.sh`)

---

## Troubleshooting

If something goes wrong, check the logs:

```bash
ls ~/.iotstack/logs/flash/           # Flash operation logs
ls ~/.iotstack/logs/<device>/        # Build logs per device
```

Each log file contains detailed error messages to help diagnose issues.

For more help:

```bash
iotstack help                        # Show all commands
iotstack help update                 # Help for a specific command
```

---

## For Developers

The technical architecture, firmware design, and implementation details are documented in [CLAUDE.md](CLAUDE.md). This includes:
- Compilation caching strategy
- Partition table design
- NVS secrets architecture
- Device-specific secret derivation
- Dual-partition OTA strategy
