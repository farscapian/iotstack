# Configuration


### Environment File Configuration

Environment variables are stored in `~/.iotstack/environments/default.env` and
loaded automatically on every `iotstack` invocation. All environment files
(the default `default.env` plus any `-env=<file>` alternates) live together
under `~/.iotstack/environments/`.

**Setup:**
```bash
# View available options
cat docs/.env.example

# Create default configuration (done automatically by setup.sh)
cp docs/.env.example ~/.iotstack/environments/default.env

# Edit to customize
nano ~/.iotstack/environments/default.env
```

**Using Multiple Configurations:**
```bash
# Create alternate configuration
cp docs/.env.example ~/.iotstack/environments/pangolin.env
# Edit pangolin.env with specific settings

# Use alternate config for a command
iotstack -env=pangolin.env flash bleproxy /dev/ttyACM0

# Or combine with other flags
iotstack -v -env=debug.env update bleproxy
```

**Pass store scoping:** each `.env` file gets its own namespace in the pass
store, derived from the `.env` filename (`default.env` -> `default`,
`pangolin.env` -> `pangolin`) -- e.g. `iotstack/default/roles/bleproxy/ota_password` vs.
`iotstack/pangolin/roles/bleproxy/ota_password`. WiFi, Home Assistant, and
per-role secrets are never shared between environments; see
[secrets.md](secrets.md).

**OTBR:** `iotstack otbr ...` reads the same environment file for its own
settings (OTBR_HOSTNAME, snap channels, MQTT, etc. -- see `docs/.env.example`)
and the same pass store for network secrets
(`iotstack/<env>/common/{wifi_ssid,wifi_password,thread_tlv}`). There is no
separate otbr env file or `--env-file` flag.
