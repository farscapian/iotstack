# SendSpin Speaker (WiFi) -- In Development

## Overview

SendSpin Speaker enables synchronized multi-room audio through Home Assistant. You can play music across multiple rooms simultaneously using the Music Assistant integration.

**Current Status**: Basic functionality works, but this is an active development project. The implementation is still being tested and refined.

## What It Does

This device plays synchronized music across multiple rooms. You tell [Music Assistant](https://music-assistant.io/) what to play, and it sends the audio to all your speakers at the same time.

**In Home Assistant, you get:**
- A "media player" you can control with play/pause/volume
- Song information (title, artist, album)
- The ability to group speakers and play the same music everywhere

## Hardware Setup

**What you need:**
- Seeed XIAO ESP32-C6 microcontroller
- PCM5102A DAC (sound card) module
- Powered speaker or any speaker with an AUX (3.5mm) input

**Why PCM5102A?** It outputs normal line-level audio that 3.5mm speakers expect. It's cheap, reliable, and works great.

## Connecting It

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

## Network Setup

Make sure your home network allows port **8928** communication between Home Assistant (Music Assistant) and your speakers. Most home networks do this automatically, but check if you have strict firewall rules.

> **Note:** SendSpin is still relatively new and the settings may change in future ESPHome updates.

## Configuration

See `yamls/wifi-sendspin.yaml` for the full configuration.

## Known Limitations

- Development project -- API and settings may change
- Requires Music Assistant integration in Home Assistant
- Network-dependent (WiFi stability affects audio sync)

## Contributing

If you find issues or have improvements, please report them in the project's issue tracker.
