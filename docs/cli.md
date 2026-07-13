# iotstack CLI


### Overview
`iotstack.sh` is a user-friendly wrapper around `scripts/update_devices.sh`. It provides device roles (e.g., `iotstack update bleproxy`) instead of requiring full YAML paths (e.g., `scripts/update_devices.sh yamls/bleproxy.yaml`).

Users run `setup.sh` once to symlink `iotstack` into `~/.local/bin/` and ensure that directory is on `PATH` (via `~/.bashrc`).

### Device Mapping (scripts/roles.conf)
Device roles are defined in `scripts/roles.conf`. Network type (WiFi or Thread) is automatically detected by introspecting the YAML file:
```
bleproxy=yamls/bleproxy.yaml
mmwave=yamls/mmwave.yaml
sendspin=yamls/sendspin.yaml
ledlightstrip-c6-thread=yamls/ledlightstrip-c6-thread.yaml
ledlightstrip-s3-wifi=yamls/ledlightstrip-s3-wifi.yaml
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

# Restart devices: one device, a whole role, or the fleet
iotstack restart bleproxy-8dfcac
iotstack restart bleproxy
iotstack restart all

# Restart into the OTHER boot partition (production <-> bootstrap)
iotstack restart bleproxy-8dfcac --next
iotstack restart all --next
```

### Restarting devices

`iotstack restart <device>|<role>|all [--next]` reboots live devices over the
ESPHome native API. It presses buttons that every image already ships (see
`yamls/common/partition_manager_base.yaml`), so it needs no firmware change and
no USB cable -- only that the device is on the network.

| Target | Meaning |
|--------|---------|
| `bleproxy-8dfcac` | One device (`<role>-<mac>`, or `bootstrap-<mac>` when it is booted into bootstrap) |
| `bleproxy` | Every live device currently running that role |
| `all` | Every live device, across all roles |

Without `--next` the device reboots into the partition it is already running
(the `Restart` button). With `--next` it presses `Toggle Boot Partition`, which
validates the alternate slot, switches to it, and reboots itself -- so a
production device comes back on bootstrap and vice versa. If the target slot
holds no valid image the firmware logs a warning and stays put, so the press
succeeding is not proof the slot changed: confirm with `iotstack devices`.
Use `iotstack set-boot` instead when you want to name the target partition
explicitly rather than toggle.

### Session logging and live monitoring

| Command / file | Purpose |
|----------------|---------|
| `iotstack --create-log ...` | Session log `~/.iotstack/logs/iotstack-<guid>.log`; implies `-v`; serial to `iotstack-<guid>-serial.log` on flash |
| `~/.iotstack/logs/sessions.watch` | Append-only registry of every invocation (TSV) -- agents tail this for new runs |
| `iotstack ps` | List `pstree` of running sessions and detached helpers |
| `iotstack kill` | Stop all running iotstack sessions and helper process trees |

Agent workflow for watching runs: `docs/workflow.md` section Watching live iotstack runs.

### Implementation Details
- `iotstack.sh` loads role list from `roles.conf`
- Network type auto-detected: checks for `wifi:` or `openthread:` sections in YAML
- User can pass either a device role or direct YAML path
- Internally calls `update_devices.sh` with resolved YAML paths
- All underlying features (reassign, verify, etc.) work the same way
