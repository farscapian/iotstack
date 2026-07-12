# Device Types


Roles are listed in `scripts/roles.conf`. Examples:

> **XIAO ESP32-C6 external antenna (REQUIRED when enabled):** the C6 roles
> (bleproxy, threadrouter, mmwave, ledlightstrip-c6-thread) include
> `yamls/common/xiao_c6_ext_antenna.yaml`, which selects the external u.FL
> connector (GPIO3 LOW + GPIO14 HIGH at boot). A unit running such a build
> **must have a u.FL pigtail attached** -- without it the board has no usable
> antenna (observed -69 dBm onboard vs -42 dBm external; weak signal also breaks
> mDNS, so `iotstack flash/update` can't discover the device). To run a C6 on
> the onboard ceramic antenna instead, drop that package from its YAML.

### WiFi BLE Proxy
- YAML: `yamls/bleproxy.yaml`
- mDNS hostname: `bleproxy-<mac>` (e.g. `bleproxy-8238cc`)
- Board: Seeed XIAO ESP32-C6

### Thread Router
- YAML: `yamls/threadrouter.yaml`
- mDNS hostname: `threadrouter-<mac>`
- Network: Thread (OpenThread)
- Special handling: forces `--jobs 1` (Thread OTA is slow; parallelism causes mesh contention)

### WiFi mmWave
- YAML: `yamls/mmwave.yaml`
- mDNS hostname: `mmwave-<mac>`

### Matrix Display
- YAML: `yamls/matrixdisplay.yaml`
- Board: ESP32-S3-DevKitC-1, HUB75 panels
- Panel layout in NVS; see [gotchas.md](gotchas.md) (Matrix display panel layout)
- Content comes from the `Display Text` entity over the HA API (there is no CLI
  knob for text). The display lambda walks it as UTF-8 codepoints, so it renders
  inline icons as well as text:

| Type in `Display Text` | Renders |
|------------------------|---------|
| `:btc:` | Full-color Bitcoin logo, inline, sized to `Text Size` |
| U+20BF (BITCOIN SIGN) | Monochrome glyph; follows the `Text Color` gradient |

`:btc:` is an ASCII token, so it can be typed or templated from HA without
entering literal Unicode; the lambda expands it to a Private Use Area codepoint
(U+E000) before rendering. Example: `BTC :btc: 100k`.

Two mechanisms, because they are not interchangeable. A font glyph is one color
by definition, so the two-tone roundel can only be an image; conversely an image
does not scale with the font or take the gradient. Icons are images (`image:`
block, rasterized from `yamls/images/*.svg` by resvg at build time); the sign is
a font glyph (`extras:` on each font, since no Roboto family ships U+20BF).

To add an icon: drop the SVG/PNG in `yamls/images/`, add three `image:` entries
(`_s`/`_m`/`_l`, sized 8/14/20 to match `Text Size`), then add a `case` to
`icon_for()` and an entry to `ICON_TOKENS` in the display lambda.

### LED Light Strip (SK6812 RGBW, default 300 LEDs)
Same strip + wiring across two board/network variants (roles in `roles.conf`).
Both use esp-idf + esp32_rmt_led_strip:

| Role | Board | Network | mDNS | Data pin |
|------|-------|---------|------|----------|
| `ledlightstrip-c6-thread` | XIAO ESP32-C6 | Thread (FTD) | `ledstrip-c6-thread-<mac>` | D0 = GPIO0 |
| `ledlightstrip-s3-wifi` | XIAO ESP32-S3 | WiFi | `ledstrip-s3-wifi-<mac>` | D0 = GPIO1 |

- Shared strip definition: `yamls/common/ledstrip_light.yaml` (both variants).
- C6 external u.FL antenna via `yamls/common/xiao_c6_ext_antenna.yaml` (GPIO3/GPIO14); S3 has no antenna GPIO.
- PSU: 5V 20A external supply; XIAO powered from same PSU (5V pin); 330 Ohm on data, 1000 uF at strip input.
- See [docs/ledlightstrip.md](../docs/ledlightstrip.md) and [docs/led-light-strip-diagram.svg](../docs/led-light-strip-diagram.svg)
