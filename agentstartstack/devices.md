# Device Types


Roles are listed in `scripts/roles.conf`. Examples:

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

### LED Light Strip (SK6812 RGBW, default 300 LEDs)
Same strip + wiring across two board/network variants (roles in `roles.conf`).
Both use esp-idf + esp32_rmt_led_strip:

| Role | Board | Network | mDNS | Data pin |
|------|-------|---------|------|----------|
| `ledlightstrip` | XIAO ESP32-C6 | Thread (FTD) | `ledstrip-<mac>` | D0 = GPIO0 |
| `ledlightstrip-s3` | XIAO ESP32-S3 | WiFi | `ledstrip-s3-<mac>` | D0 = GPIO1 |

- Shared strip definition: `yamls/common/ledstrip_light.yaml` (both variants).
- C6 external u.FL antenna via `yamls/common/xiao_c6_ext_antenna.yaml` (GPIO3/GPIO14); S3 has no antenna GPIO.
- PSU: 5V 20A external supply; XIAO powered from same PSU (5V pin); 330 Ohm on data, 1000 uF at strip input.
- See [docs/ledlightstrip.md](../docs/ledlightstrip.md) and [docs/led-light-strip-diagram.svg](../docs/led-light-strip-diagram.svg)
