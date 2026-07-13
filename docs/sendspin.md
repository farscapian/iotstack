# SendSpin Speaker (WiFi) -- In Development

## Overview

SendSpin Speaker enables synchronized multi-room audio through Home Assistant. You can play music across multiple rooms simultaneously using the Music Assistant integration.

**Current Status**: Active development. The config validates but has not been flashed to hardware yet, so treat the pinout below as the intended wiring rather than a verified one.

## What It Does

This device plays synchronized music across multiple rooms. You tell [Music Assistant](https://music-assistant.io/) what to play, and it sends the audio to all your speakers at the same time.

**In Home Assistant, you get:**
- A "media player" you can control with play/pause/volume
- Song information (title, artist, album)
- The ability to group speakers and play the same music everywhere

## Hardware Setup

**What you need:**
- ESP32-S3-DevKitC-1, **N16R8** variant (16MB flash + 8MB octal PSRAM)
- PCM5102A DAC (sound card) module
- Powered speaker or any speaker with an AUX (3.5mm) input
- External u.FL antenna pigtail (see Antenna below)

**Why the N16R8 specifically?** The PSRAM is not optional in spirit. SendSpin
buffers a network audio stream, and with 8MB of PSRAM the stream task's stack and
the full 1MB audio buffer both live there, leaving internal RAM to WiFi. On a
PSRAM-less chip the buffer has to be cut to a fraction of that, and a shallow
buffer is exactly what turns a brief network hiccup into an audible dropout.

**Why PCM5102A?** It outputs normal line-level audio that 3.5mm speakers expect. It's cheap, reliable, and works great.

## Connecting It

| PCM5102A | ESP32-S3 | Purpose |
|---|---|---|
| VCC | 3.3V | Power |
| GND | GND | Ground |
| BCK | GPIO4 | Audio timing (bit clock) |
| LCK | GPIO5 | Audio timing (left/right clock) |
| DIN | GPIO6 | Audio data |
| SCK | GND | Clock (usually hardwired to GND) |

Then plug the 3.5mm output from the DAC into your speaker.

**Note on SCK:** Most PCM5102A modules come with SCK already wired to GND (which is correct). If yours doesn't, uncomment the `i2s_mclk_pin` line in the YAML config.

**Pins you cannot use on this board:**
- **GPIO35, GPIO36, GPIO37** -- consumed by the octal PSRAM on any R8 module. This is the easy trap to fall into, because they look free on the pinout diagram.
- GPIO0 (BOOT button), GPIO19/20 (USB serial JTAG -- the logger runs over it), GPIO26-32 (SPI flash).

The three I2S pins are defined as substitutions at the top of the YAML, so a different board (for example the XIAO ESP32-S3) only needs those three values changed.

## Antenna

The board has a u.FL connector; attach the external antenna pigtail.

Unlike the XIAO ESP32-C6, the S3 has **no RF-switch GPIO**, so there is nothing to configure in software and no antenna package to include. Attach the pigtail and you are done.

## Network Setup

Make sure your home network allows port **8928** communication between Home Assistant (Music Assistant) and your speakers. Most home networks do this automatically, but check if you have strict firewall rules.

> **Note:** SendSpin is still relatively new and the settings may change in future ESPHome updates.

## Configuration

See `yamls/sendspin.yaml` for the full configuration.

## Known Limitations

- Development project -- API and settings may change
- Not yet flashed to hardware; config validates against ESPHome 2026.6.1 only
- Requires Music Assistant integration in Home Assistant
- Network-dependent (WiFi stability affects audio sync)

## Contributing

If you find issues or have improvements, please report them in the project's issue tracker.
