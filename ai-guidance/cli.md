# iotstack CLI


### Overview
`iotstack.sh` is a user-friendly wrapper around `scripts/update_devices.sh`. It provides device roles (e.g., `iotstack update bleproxy`) instead of requiring full YAML paths (e.g., `scripts/update_devices.sh yamls/bleproxy.yaml`).

Users run `setup.sh` once to symlink `iotstack` into `~/.local/bin/` and ensure that directory is on `PATH` (via `~/.bashrc`).

### Device Mapping (scripts/roles.conf)
Device roles are defined in `scripts/roles.conf`. Network type (WiFi or Thread) is automatically detected by introspecting the YAML file:
```
bleproxy=yamls/bleproxy.yaml
mmwave=yamls/mmwave.yaml
sendspinspeaker=yamls/sendspinspeaker.yaml
ledlightstrip=yamls/ledlightstrip.yaml
threadrouter=yamls/threadrouter.yaml
silentnotify=yamls/silentnotify.yaml
matrixdisplay=yamls/matrixdisplay.yaml
```

Format: `<role>=<yaml-path>`
- Network type determined from YAML content: `wifi:` section -> WiFi, `openthread:` section -> Thread
- Each YAML file is introspected at runtime (no need to specify variant in config)

### Usage Examples
```bash
# Update a device
iotstack update bleproxy
iotstack update threadrouter

# Update all devices listed in roles.conf
iotstack update all

# Reassign devices to different config
iotstack reassign 8dfcac 0f4df4 mmwave

# Or use direct YAML path
iotstack update yamls/custom.yaml
```

### Implementation Details
- `iotstack.sh` loads role list from `roles.conf`
- Network type auto-detected: checks for `wifi:` or `openthread:` sections in YAML
- User can pass either a device role or direct YAML path
- Internally calls `update_devices.sh` with resolved YAML paths
- All underlying features (reassign, verify, etc.) work the same way
