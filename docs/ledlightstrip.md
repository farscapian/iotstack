# LED Light Strip Control [WARN] -- In Development

**This LED light strip implementation is IN DEVELOPMENT and NOT FULLY TESTED.**

## Overview

Experimental controller for SK6812 RGBW addressable LED light strips (4-channel: red, green,
blue, white). Control colors, brightness, and effects from Home Assistant via Thread.

**Current Status**: Basic functionality defined. neopixelbus + esp-idf + Thread path not yet
tested on hardware. Effects stability not confirmed.

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
| MCU | Seeed XIAO ESP32-C6 | Thread end device |
| Strip | SK6812 RGBW | 5V, 4-channel (GRBW order) |
| PSU | Aclorol 5V 20A (or equivalent) | See power budget below |
| Series resistor | 330 Ohm | GPIO2 to DIN; no polarity |
| Bulk capacitor | 1000 uF electrolytic | Across strip VCC/GND at input; + to VCC |

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
| Strip DIN (green) | XIAO GPIO2 (D0) via 330 Ohm resistor |
| 1000 uF cap | Across +V / -V at strip input; + lead to +V |

### Pin assignments (XIAO ESP32-C6)

| GPIO | Function |
|------|----------|
| GPIO2 (D0) | LED strip data out -> 330 Ohm -> DIN |
| GPIO9 | Boot button (default; handled by boot_button package) |
| GPIO15 | Onboard status LED (active-low) |

## Electrical notes

### 3.3V logic to 5V SK6812

The XIAO ESP32-C6 outputs 3.3V logic. SK6812 at 5V VCC has a HIGH input threshold of
~3.5V (0.7 x VCC). This is marginal. In practice it works reliably at short data wire
lengths (< ~2-3m) with clean power.

For longer runs or if you see flickering/corrupted colors: add a 74AHCT125 or SN74HCT245
level shifter between GPIO2 and the 330 Ohm resistor. The resistor stays on the output
side of the level shifter.

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

Thread end device (FTD). Joins the existing Thread mesh via the Thread Router device.
Home Assistant accesses it through the border router over IPv6. No WiFi credentials needed.

## Configuration

YAML: `yamls/ledlightstrip.yaml`

Tunable substitutions at the top of the YAML:

| Substitution | Default | Description |
|---|---|---|
| strip_data_pin | GPIO2 | Data GPIO (D0 on XIAO C6 silkscreen) |
| strip_num_leds | 300 | LED count for your strip |
| strip_gamma | 2.8 | Gamma correction exponent |
| strip_transition | 500ms | Default transition length |

## Features

- [OK] Basic RGBW color control
- [OK] Brightness adjustment
- [WARN] Effects (experimental, stability not confirmed)
- [WARN] neopixelbus + esp-idf + Thread not yet tested on hardware
- [FAIL] Power management not optimized
- [FAIL] Not tested with full-length high-current strips

## Known limitations

- In-development -- API may change
- 3.3V -> 5V data is marginal; level shifter recommended for long runs
- Effects stability unconfirmed
- Power budget tight at maximum brightness

## Contributing

Found an issue? Have an improvement? Please report it in the project's issue tracker.
