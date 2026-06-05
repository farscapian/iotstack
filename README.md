# ESPHome Device Configs for Home Automation

This repository contains firmware configurations for ESP32-C6 smart home devices that work with Home Assistant. These devices extend your smart home's capabilities with Bluetooth connectivity, Thread networking, presence detection, and more.

## What Does This Do?

Think of these devices as **small computers** that run custom firmware and communicate with Home Assistant. Here's what you can do with them:

- **BLE Proxy**: Receive signals from Bluetooth devices throughout your house and relay them to Home Assistant (useful for tracking Bluetooth tags, sensors, etc.)
- **Thread Router**: Create a mesh network for Matter and Thread devices, extending range throughout your home
- **Presence Sensor**: Detect when people are in a room using mmWave radar
- **Multi-room Audio**: Sync music across multiple rooms

## Getting Started

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

### Quick Start

**Update all BLE proxy devices:**
```bash
./update_devices.sh wifi/esp32c6-wifi-bleproxy.yaml
```

The script:
1. Finds all BLE proxy devices on your network (automatically)
2. Builds the firmware from the YAML config
3. Sends the firmware to each device wirelessly
4. Only devices that need the update get flashed (saves time)

### More Options

```bash
# See what WOULD be updated without actually updating
./update_devices.sh --dry-run wifi/esp32c6-wifi-bleproxy.yaml

# Force update everything, even if it's already up-to-date
./update_devices.sh --no-upgrade-delta wifi/esp32c6-wifi-bleproxy.yaml

# Update 8 devices at the same time (default is 4)
./update_devices.sh --jobs 8 wifi/esp32c6-wifi-bleproxy.yaml

# Just check if devices are up-to-date (don't actually update)
./update_devices.sh --verify wifi/esp32c6-wifi-bleproxy.yaml
```

### Update ALL Device Types at Once

```bash
./update_all.sh
```

This runs the update for every YAML config at the same time.

### How It Works Behind the Scenes

The script finds your devices on your network using a feature called "mDNS" (a way devices announce themselves). It automatically detects which devices need updates and sends them the new firmware wirelessly. It also caches the build, so if you run it twice with the same config, it skips recompiling and goes straight to flashing.

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
- Automatically update entity names in Home Assistant when you rename devices
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

When the script runs, it keeps detailed logs of what happened. These are stored in `~/.iotstack/logs/` organized by device type.

If an update fails, look here for error messages. The logs show:
- Build errors (if the config has a problem)
- Flash errors (if the wireless update failed)
- Each device's individual update log

You don't need to worry about these unless something breaks — the script will tell you where to look.

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
