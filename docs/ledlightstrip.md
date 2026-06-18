# LED Light Strip Control [WARN] -- In Development

**This LED light strip implementation is IN DEVELOPMENT and NOT FULLY TESTED. Please read before using.**

## Overview

Experimental controller for WS2812B addressable LED light strips (commonly called "NeoPixel" or "RGB LED strips"). Control colors, brightness, and effects from Home Assistant.

**Current Status**: Basic functionality works, but the implementation is still being tested and refined. Effects may not be stable. Power management is not optimized.

## [WARN] SAFETY DISCLAIMER

**ELECTRICAL SAFETY CRITICAL**

- **Electrical Safety**: LED strips require proper power management. Incorrect wiring can cause fire, electrical shock, or damage to your equipment.
- **No Warranty**: This code is experimental and provided as-is with no safety guarantees.
- **Test Carefully**: Only use with short test strips first. Verify all connections before powering on.
- **Fire Risk**: Poorly regulated power supplies can overheat and damage LED strips. Use proper power supplies rated for your strip's power requirements.
- **Overcurrent**: If wired incorrectly, the power supply can be damaged or overheat. Always double-check wiring before applying power.

**DISCONNECT POWER IMMEDIATELY if you experience:**
- LED strip getting hot
- Smell of burning plastic or electronics
- Unusual buzzing or clicking sounds
- Power supply getting hot

## Hardware Requirements

- Seeed XIAO ESP32-C6 microcontroller
- WS2812B LED strip (5V or 12V version)
- **Proper Power Supply**: A power supply rated for the LED strip's current draw (very important for safety)
- **Capacitor**: A 470-1000uF capacitor across the power supply (protects against power spikes)
- **Resistor**: A 470-1000Ohm resistor on the data line (protects the GPIO pin)

## Wiring Safety Notes

- **Do NOT** connect the LED strip directly to the ESP32 GPIO. Always use a resistor on the data line.
- **Do NOT** power the LED strip from the ESP32's 5V pin. Use a separate power supply.
- **Do use** a capacitor across power and ground at the LED strip's input.
- **Do verify** your power supply voltage matches your LED strip (5V or 12V).
- **Do test** with just a few LEDs before connecting the full strip.

**See the wiring diagram in the `resources/` folder for a reference schematic.**

## Features

- [OK] Basic LED color control
- [OK] Brightness adjustment
- [WARN] Effects (experimental)
- [FAIL] Power management not optimized
- [FAIL] Not tested with high-power strips (>500mA)

## Configuration

See `yamls/esp32s3-wifi-led-strip.yaml` for the configuration.

## Known Limitations

- Experimental/in-development -- API may change
- Effects are not stable
- Power management not optimized
- Not tested with high-power configurations

## Recommendation

Only use this if you're comfortable with electrical troubleshooting and can safely test it. Start with short test strips and verify all wiring before applying power.

## Contributing

Found an issue? Have an improvement? Please report it in the project's issue tracker.
