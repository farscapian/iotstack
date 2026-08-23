# Configuration


### Environment File Configuration

Environment variables are stored in `~/.iotstack/.env` and loaded automatically on every `iotstack` invocation.

**Setup:**
```bash
# View available options
cat docs/.env.example

# Create default configuration (done automatically by setup.sh)
cp docs/.env.example ~/.iotstack/.env

# Edit to customize
nano ~/.iotstack/.env
```

**Using Multiple Configurations:**
```bash
# Create alternate configuration
cp ~/.iotstack/.env.example ~/.iotstack/pangolin.env
# Edit pangolin.env with specific settings

# Use alternate config for a command
iotstack -env=pangolin.env flash bleproxy /dev/ttyACM0

# Or combine with other flags
iotstack -v -env=debug.env update bleproxy
```

**Pass store scoping:** each `.env` file gets its own namespace in the pass
store, derived from the `.env` filename (`.env` -> `default`, `pangolin.env` ->
`pangolin`) -- e.g. `iotstack/default/roles/bleproxy/ota_password` vs.
`iotstack/pangolin/roles/bleproxy/ota_password`. WiFi, Home Assistant, and
per-role secrets are never shared between environments; see
[secrets.md](secrets.md).
