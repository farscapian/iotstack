# LED Light Strip Control [WARN] -- In Development

**This LED light strip implementation is IN DEVELOPMENT and NOT FULLY TESTED.**

## Overview

Experimental controller for SK6812 RGBW addressable LED light strips (4-channel: red, green,
blue, white). Control colors, brightness, and effects from Home Assistant.

**Current Status**: Basic functionality defined. None of the variants below are yet tested on
hardware. Effects stability not confirmed.

## Variants

Same strip and wiring; the board determines the network (the ESP32-S3 has no Thread radio).
All three are roles in `scripts/roles.conf`:

| Role | Board | Network | Framework | LED driver | Data pin |
|------|-------|---------|-----------|------------|----------|
| `ledlightstrip` | XIAO ESP32-C6 | Thread (FTD) | esp-idf | esp32_rmt_led_strip | D0 = GPIO0 |
| `ledlightstrip-s3` | XIAO ESP32-S3 | WiFi | esp-idf | esp32_rmt_led_strip | D0 = GPIO1 |
| `ledlightstrip-s3-arduino` | XIAO ESP32-S3 | WiFi | arduino | neopixelbus | D0 = GPIO1 |

The two esp-idf variants share the strip + effects via `yamls/common/ledstrip_light.yaml`.
The arduino variant is an A/B experiment: `neopixelbus` only builds under the Arduino
framework (it fails under esp-idf), so it carries its own light block. `iotstack roles`
shows the board/variant/framework/network for each.

## [WARN] SAFETY DISCLAIMER

**ELECTRICAL SAFETY CRITICAL**

- **Electrical Safety**: LED strips require proper power management. Incorrect wiring can cause
  fire, electrical shock, or damage to your equipment.
- **No Warranty**: This code is experimental and provided as-is with no safety guarantees.
- **Test Carefully**: Only use with short test strips first. Verify all connections before
  powering on.
- **Fire Risk**: Poorly regulated power supplies can overheat. Use a supply rated for your
  strip's full current draw.
- **Overcurrent**: Always double-check wiring before applying power.

**DISCONNECT POWER IMMEDIATELY if you experience:**
- LED strip getting hot
- Smell of burning plastic or electronics
- Unusual buzzing or clicking sounds
- Power supply getting hot

## Hardware

| Part | Value | Notes |
|------|-------|-------|
| MCU | Seeed XIAO ESP32-C6 or ESP32-S3 | C6 = Thread; S3 = WiFi (see Variants) |
| Strip | SK6812 RGBW | 5V, 4-channel (GRB + W) |
| PSU | Aclorol 5V 20A (or equivalent) | See power budget below |
| Series resistor | 330 Ohm | D0 to DIN; no polarity (D0 = GPIO0 on C6, GPIO1 on S3) |
| Bulk capacitor | 1000 uF electrolytic | Across strip VCC/GND at input; + to VCC |
| Antenna | External u.FL | C6: selected at boot via GPIO3/GPIO14 RF switch. S3: plain u.FL connector, no GPIO |

## Wiring

See [led-light-strip-diagram.svg](led-light-strip-diagram.svg) for the full schematic.

### AC side (mains -- treat with care)

| Wire | PSU terminal |
|------|-------------|
| Hot (brown) | L |
| Neutral (blue) | N |
| Earth (green/yellow) | E |

### DC side

| Connection | Detail |
|---|---|
| Strip VCC (red) | PSU +V terminal 1 |
| Strip GND (white) | PSU -V terminal 1 |
| XIAO 5V pin | PSU +V terminal 2 |
| XIAO GND pin | PSU -V terminal 2 |
| Strip DIN (green) | XIAO GPIO0 (D0) via 330 Ohm resistor |
| 1000 uF cap | Across +V / -V at strip input; + lead to +V |

### Pin assignments -- XIAO ESP32-C6 (Thread)

| GPIO | Function |
|------|----------|
| GPIO0 (D0) | LED strip data out -> 330 Ohm -> DIN |
| GPIO3 | RF switch enable (driven LOW at boot to power the antenna switch) |
| GPIO9 | Boot button (default; handled by boot_button package) |
| GPIO14 | RF antenna select (driven HIGH at boot = external u.FL) |
| GPIO15 | Onboard status LED (active-low) |

### Pin assignments -- XIAO ESP32-S3 (WiFi)

| GPIO | Function |
|------|----------|
| GPIO1 (D0) | LED strip data out -> 330 Ohm -> DIN |
| GPIO0 | Boot button (override boot_button_pin; handled by boot_button package) |
| GPIO21 | Onboard status LED (active-low) |

The S3 has no RF-switch GPIOs -- the u.FL connector is wired directly, so there is no
antenna config and no GPIO3/GPIO14 use.

## Electrical notes

### 3.3V logic to 5V SK6812

Both the XIAO ESP32-C6 and ESP32-S3 output 3.3V logic. SK6812 at 5V VCC has a HIGH input
threshold of ~3.5V (0.7 x VCC). This is marginal. In practice it works reliably at short
data wire lengths (< ~2-3m) with clean power.

For longer runs or if you see flickering/corrupted colors: add a 74AHCT125 or SN74HCT245
level shifter between the data GPIO and the 330 Ohm resistor. The resistor stays on the
output side of the level shifter.

### Power budget

| Scenario | Current |
|---|---|
| 300 LEDs at full RGBW white (absolute max) | ~18A |
| PSU rating | 20A |
| Headroom at max | ~10% |

Do not run all 300 LEDs at full white simultaneously. Mixed colors and partial brightness
use far less current in practice. Start with a short test segment before connecting the
full strip.

## Network

**C6 (`ledlightstrip`)** -- Thread end device (FTD). Joins the existing Thread mesh via the
Thread Router device; Home Assistant reaches it through the border router over IPv6. No WiFi
credentials needed. Antenna: the C6 uses the external u.FL antenna, selected by driving GPIO3
LOW (power the RF switch) and GPIO14 HIGH (select external) in `esphome.on_boot` before the
radio starts (factored into `yamls/common/xiao_c6_ext_antenna.yaml`). To use the onboard
ceramic antenna instead, drop that package (onboard is the hardware default).

**S3 (`ledlightstrip-s3`, `ledlightstrip-s3-arduino`)** -- WiFi (the S3 has no Thread radio).
Credentials come from NVS like the other WiFi devices. The u.FL connector is wired directly;
no antenna GPIO config.

## Configuration

YAMLs: `yamls/ledlightstrip.yaml` (C6), `yamls/ledlightstrip-s3.yaml` (S3 esp-idf),
`yamls/ledlightstrip-s3-arduino.yaml` (S3 arduino). The shared strip definition lives in
`yamls/common/ledstrip_light.yaml` (used by the two esp-idf variants).

Tunable substitutions at the top of each board YAML:

| Substitution | Default | Description |
|---|---|---|
| strip_data_pin | GPIO0 (C6) / GPIO1 (S3) | Data GPIO (D0 silkscreen on either board) |
| strip_num_leds | 300 | LED count for your strip |
| strip_gamma | 2.8 | Gamma correction exponent |
| strip_transition | 500ms | Default transition length |

## Features

- [OK] Basic RGBW color control
- [OK] Brightness adjustment
- [WARN] Effects (experimental, stability not confirmed)
- [WARN] None of the three variants (C6/Thread, S3/esp-idf, S3/arduino) tested on hardware
- [FAIL] Power management not optimized
- [FAIL] Not tested with full-length high-current strips

## Known limitations

- In-development -- API may change
- 3.3V -> 5V data is marginal; level shifter recommended for long runs
- Effects stability unconfirmed
- Power budget tight at maximum brightness

## Contributing

Found an issue? Have an improvement? Please report it in the project's issue tracker.
