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

### LED Light Strip
- YAML: `yamls/ledlightstrip.yaml`
- mDNS hostname: `ledstrip-<mac>`
- Board: Seeed XIAO ESP32-C6
- Network: Thread (FTD)
- Strip: SK6812 RGBW, default 300 LEDs
- Data pin: GPIO2 (D0 silkscreen) via 330 Ohm series resistor to DIN
- PSU: 5V 20A external supply; XIAO powered from same PSU (5V pin)
- See [docs/ledlightstrip.md](../docs/ledlightstrip.md) and [docs/led-light-strip-diagram.svg](../docs/led-light-strip-diagram.svg)
