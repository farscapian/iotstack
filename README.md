# ESPHome Device Configs for Home Automation

This repository contains firmware configurations for ESP32-C6 smart home devices that work with Home Assistant. These devices extend your smart home's capabilities with Bluetooth connectivity, Thread networking, presence detection, and more.

## What Does This Do?

Think of these devices as **small computers** that run custom firmware and communicate with Home Assistant. Here's what you can do with them:

- **BLE Proxy**: Receive signals from Bluetooth devices throughout your house and relay them to Home Assistant (useful for tracking Bluetooth tags, sensors, etc.)
- **Thread Router**: Create a mesh network for Matter and Thread devices, extending range throughout your home
- **Presence Sensor**: Detect when people are in a room using mmWave radar
- **Multi-room Audio**: Sync music across multiple rooms

## Getting Started

### Initial Setup

To set up the `iotstack` command so you can run it from anywhere:

```bash
./setup.sh
source ~/.bashrc
```

This creates a symlink in `~/.local/bin/` and updates your PATH. Now you can use `iotstack` from anywhere:

```bash
which iotstack        # Shows: /home/user/.local/bin/iotstack
iotstack help         # Works from any directory
```

## Architecture Overview

### Secrets Management

iotstack uses a **multi-layer secrets architecture** that keeps credentials secure without compiling them into firmware:

```
Layer 1: Role-Based Secrets (Encrypted Pass Store)
  ~/.iotstack/.pass/iotstack/roles/bleproxy/ota_password
  └─ Encrypted at rest, never written unencrypted to disk

Layer 2: Device-Specific Derivation (In-Memory)
  iotstack flash derives: sha256(role_secret | device_mac)
  └─ Unique password per device, never stored on disk

Layer 3: NVS Partition (Device Flash)
  Device flash contains: ota_password, api_encryption_key (plaintext)
  └─ Persists across firmware updates, read at device startup

Layer 4: Firmware Components (Dynamic)
  nvs_ota_password component reads NVS → sets OTA authentication
  nvs_secrets component reads NVS → sets WiFi/API credentials
  └─ No hardcoded secrets in compiled firmware binary
```

**Key benefit:** Single generic firmware binary works on all devices with device-specific secrets loaded from NVS at startup.

### Device Flash Workflow

1. **Compile**: Generic firmware (no device-specific secrets)
2. **Flash**: Via USB serial to blank/recovery device
3. **Write NVS**: Device-specific secrets derived and written to flash
4. **Device boots**: Reads NVS, loads device-specific credentials
5. **OTA updates**: Subsequent updates use device-specific OTA password from NVS

For details on security properties and threat models, see `CLAUDE.md` → "Secrets Management" and "NVS Architecture".

### Device Configuration

All device configurations are in YAML files organized by network type:

```
wifi/
├── esp32c6-wifi-bleproxy.yaml    # Bluetooth relay (uses Wi-Fi)
├── esp32c6-wifi-mmwave.yaml      # Motion/presence sensor (uses Wi-Fi)
└── wifi-sendspin.yaml            # Multi-room audio speaker (uses Wi-Fi)

thread/
└── c6-thread-router.yaml         # Thread mesh router (low-power)
```

## The Devices Explained

| What | File | What it does in Home Assistant |
|------|------|------|
| **BLE Proxy** | `esp32c6-wifi-bleproxy.yaml` | Listens for Bluetooth signals and sends them to Home Assistant so you can track and control Bluetooth devices |
| **Thread Router** | `c6-thread-router.yaml` | Creates a mesh network for Thread devices (like smart locks, sensors) and extends their range |
| **Presence Sensor** | `esp32c6-wifi-mmwave.yaml` | Detects when people are in a room and their distance (great for automations like turning on lights) |
| **Audio Speaker** | `wifi-sendspin.yaml` | Plays synced music across multiple rooms using Music Assistant |

---

## BLE Proxy (`esp32c6-wifi-bleproxy.yaml`)

### What It Does

A BLE Proxy is a **wireless bridge** between Bluetooth devices and Home Assistant. It listens for Bluetooth signals from devices around your home and relays them to Home Assistant over Wi-Fi.

**What can you do with it?**
- Track Bluetooth tags (useful for finding keys, bags, or pets)
- Receive sensor data from Bluetooth devices (temperature, humidity, motion sensors)
- Control Bluetooth devices from Home Assistant automations
- Extend the range of Bluetooth devices throughout your home

**In Home Assistant, you get:**
- Entities for each Bluetooth device it detects
- Real-time updates when Bluetooth devices connect/disconnect
- Signal strength information (RSSI)
- Integration with your automations and scripts

### Why You Need It

Bluetooth has limited range (typically 30-100 feet). If you have Bluetooth devices in different rooms, one proxy in each location ensures you can reach them all. Multiple proxies work together — Home Assistant automatically uses the closest one.

### Hardware

You just need:
- Seeed XIAO ESP32-C6 microcontroller
- A power source (USB or battery)
- An optional LED for status indication (GPIO15)

The BLE Proxy has nothing else to connect — it's wireless in, wireless out.

### Deploying BLE Proxies

Place them strategically:
- One per room or zone (kitchen, bedroom, living room, etc.)
- On a shelf or wall mount for good coverage
- Near areas where you have the most Bluetooth devices

Each device gets its own MAC address suffix, so Home Assistant keeps them organized automatically.

---

## Multi-Room Audio Speaker (`wifi-sendspin.yaml`)

### What It Does

This device plays synchronized music across multiple rooms. You tell [Music Assistant](https://music-assistant.io/) what to play, and it sends the audio to all your speakers at the same time.

**In Home Assistant, you get:**
- A "media player" you can control with play/pause/volume
- Song information (title, artist, album)
- The ability to group speakers and play the same music everywhere

### Hardware Setup

**What you need:**
- Seeed XIAO ESP32-C6 microcontroller
- PCM5102A DAC (sound card) module
- Powered speaker or any speaker with an AUX (3.5mm) input

**Why PCM5102A?** It outputs normal line-level audio that 3.5mm speakers expect. It's cheap, reliable, and works great.

### Connecting It

| PCM5102A | ESP32-C6 | Purpose |
|---|---|---|
| VCC | 3.3V | Power |
| GND | GND | Ground |
| BCK | GPIO3 | Audio timing |
| LCK | GPIO4 | Audio timing |
| DIN | GPIO5 | Audio data |
| SCK | GND | Clock (usually hardwired to GND) |

Then plug the 3.5mm output from the DAC into your speaker.

**Note on SCK:** Most PCM5102A modules come with SCK already wired to GND (which is correct). If yours doesn't, uncomment the `i2s_mclk_pin` line in the YAML config.

### Network Setup

Make sure your home network allows port **8928** communication between Home Assistant (Music Assistant) and your speakers. Most home networks do this automatically, but check if you have strict firewall rules.

> **Note:** Sendspin is still relatively new and the settings may change in future ESPHome updates.

---

## LED Light Strip Control ⚠️ **EXPERIMENTAL — NOT FOR PRODUCTION USE**

### ⚠️ SAFETY DISCLAIMER

**This LED light strip implementation is IN DEVELOPMENT and NOT FULLY TESTED. Please read before using:**

- **Electrical Safety**: LED strips require proper power management. Incorrect wiring can cause fire, electrical shock, or damage to your equipment.
- **No Warranty**: This code is experimental and provided as-is with no safety guarantees.
- **Test Carefully**: Only use with short test strips first. Verify all connections before powering on.
- **Fire Risk**: Poorly regulated power supplies can overheat and damage LED strips. Use proper power supplies rated for your strip's power requirements.
- **Overcurrent**: If wired incorrectly, the power supply can be damaged or overheat. Always double-check wiring before applying power.

**If you experience any of the following, DISCONNECT POWER IMMEDIATELY:**
- LED strip getting hot
- Smell of burning plastic or electronics
- Unusual buzzing or clicking sounds
- Power supply getting hot

### What It Does

This is an experimental controller for WS2812B addressable LED light strips (commonly called "NeoPixel" or "RGB LED strips"). It allows you to control colors, brightness, and effects from Home Assistant.

**Current Status**: Basic functionality works, but the implementation is still being tested and refined. Effects may not be stable. Power management is not optimized.

### Hardware Requirements

- Seeed XIAO ESP32-C6 microcontroller
- WS2812B LED strip (5V or 12V version)
- **Proper Power Supply**: A power supply rated for the LED strip's current draw (very important for safety)
- **Capacitor**: A 470-1000µF capacitor across the power supply (protects against power spikes)
- **Resistor**: A 470-1000Ω resistor on the data line (protects the GPIO pin)

### ⚠️ Wiring Safety Notes

- **Do NOT** connect the LED strip directly to the ESP32 GPIO. Always use a resistor on the data line.
- **Do NOT** power the LED strip from the ESP32's 5V pin. Use a separate power supply.
- **Do use** a capacitor across power and ground at the LED strip's input.
- **Do verify** your power supply voltage matches your LED strip (5V or 12V).
- **Do test** with just a few LEDs before connecting the full strip.

**See the wiring diagram in the `resources/` folder for a reference schematic.**

### Status

- ✅ Basic LED control works
- ⚠️ Effects are experimental
- ❌ Power management not optimized
- ❌ Not tested with high-power strips (>500mA)

**Recommendation**: Only use this if you're comfortable with electrical troubleshooting and can safely test it.

---

## Updating Your Devices (Over-the-Air)

### Quick Start with iotstack CLI

The easiest way to manage your devices is with the `iotstack` command:

```bash
# See available device roles
iotstack list shortcuts

# Update a device by name (WiFi by default)
iotstack update bleproxy

# Update a device's Thread variant
iotstack update threadrouter

# Update all devices
iotstack update all

# See what would be updated without actually updating
iotstack update --dry-run mmwave

# Reassign devices to a different config
iotstack reassign 8dfcac 0f4df4 to mmwave

# Get help anytime
iotstack help
iotstack help reassign
```

### Using Direct YAML Paths

If you prefer to specify the YAML file directly:

```bash
# Update a specific config
./update_devices.sh wifi/esp32c6-wifi-bleproxy.yaml

# See what WOULD be updated without actually updating
./update_devices.sh --dry-run wifi/esp32c6-wifi-bleproxy.yaml

# Force update everything, even if it's already up-to-date
./update_devices.sh --force-reflash wifi/esp32c6-wifi-bleproxy.yaml

# Update 8 devices at the same time (default is 4)
./update_devices.sh --jobs 8 wifi/esp32c6-wifi-bleproxy.yaml

# Just check if devices are up-to-date (don't actually update)
./update_devices.sh --verify wifi/esp32c6-wifi-bleproxy.yaml
```

### Update ALL Device Types at Once

```bash
# Using iotstack
iotstack update all

# Or using the script directly
./update_all.sh
```

Both run the update for every YAML config at the same time.

### How It Works Behind the Scenes

The script finds your devices on your network using a feature called "mDNS" (a way devices announce themselves). It automatically detects which devices need updates and sends them the new firmware wirelessly (OTA flashing). It also caches the build, so if you run it twice with the same config, it skips recompiling and goes straight to flashing. Detailed logs of each update are stored in `~/.iotstack/logs/` for troubleshooting.

### What You Need Installed

On your Linux machine running the update script, you need:

- **ESPHome**: The build tool that compiles your configs into firmware
- **Python 3**: For running the script
- **Bash 4.3+**: The shell scripting language (most Linux systems have this)
- **avahi-browse**: For finding devices on your network (usually: `sudo apt install avahi-utils`)

Don't worry if you're missing something — the script will tell you.

### Home Assistant Integration (Optional)

If you connect this script to Home Assistant, it can:
- Check if all your devices are reachable on the network
- Automatically update entity names in Home Assistant after device reassignment
- Preserve all your automations and settings during updates

To enable this, add your Home Assistant URL and login token to `secrets.yaml`:

```yaml
ha_url: "http://homeassistant.local:8123"
ha_token: "eyJ0eXAiOiJKV1QiLCJhbGc..."  # Your long-lived access token
```

To get your Home Assistant token:
1. In Home Assistant, go to Settings → Developer Tools → Long-Lived Access Tokens
2. Click "Create Token" and copy it
3. Paste it into secrets.yaml

### Logs (If Something Goes Wrong)

When the script runs, it keeps detailed logs of what happened. These are stored in `~/.iotstack/logs/` organized by device type and timestamp.

If an update fails, look here for error messages. The logs show:
- Build errors (if the config has a problem)
- Flash errors (if the wireless update failed)
- Each device's individual update log with details

You don't need to worry about these unless something breaks — the script will tell you where to look. Most updates are silent and just work.

---

## Device Shortcuts (iotstack-roles.conf)

The `iotstack-roles.conf` file defines friendly names for your devices. This lets you use shortcuts like `iotstack update bleproxy` instead of typing the full path.

Example:
```
bleproxy=wifi/esp32c6-wifi-bleproxy.yaml:thread/c6-thread-router.yaml
mmwave=wifi/esp32c6-wifi-mmwave.yaml
threadrouter=:thread/c6-thread-router.yaml
ledstrip=wifi/esp32s3-wifi-led-strip.yaml:
```

Format: `<shortcut>=<wifi-yaml>:<thread-yaml>`
- Left of the colon: WiFi variant (or the only variant if no Thread version)
- Right of the colon: Thread variant (optional)

Use `iotstack list shortcuts` to see all available shortcuts.

---

## Credentials and Secrets

All sensitive information (WiFi passwords, API keys, etc.) goes in a file called `secrets.yaml` in this folder. This file is **NOT** checked into git, so your passwords stay private.

Create `secrets.yaml` with entries like:
```yaml
wifi_ssid: "YourWiFiName"
wifi_password: "YourWiFiPassword"
bleproxy_api_encryption_key: "your-api-key-here"
# ... other credentials
```

Refer to the [ESPHome documentation](https://esphome.io/) for a complete list of what each device needs.
