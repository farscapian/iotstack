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
