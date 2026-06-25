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

### DISABLE_COMPILATION_CACHE
**Purpose:** Force recompilation of firmware regardless of cache state

**Values:**
- `0` (default): Use compilation cache for faster builds
- `1`: Always recompile, ignore cache

**Usage:**
```bash
# Option 1: Set in ~/.iotstack/.env (persistent for all commands)
echo "DISABLE_COMPILATION_CACHE=1" >> ~/.iotstack/.env

# Option 2: Use alternate config file
iotstack -env=debug.env flash bleproxy /dev/ttyACM0

# Option 3: Set for single command
DISABLE_COMPILATION_CACHE=1 iotstack flash bleproxy /dev/ttyACM0
```

**Examples:**
```bash
# Create debug configuration with caching disabled
cp ~/.iotstack/.env.example ~/.iotstack/debug.env
sed -i 's/DISABLE_COMPILATION_CACHE=0/DISABLE_COMPILATION_CACHE=1/' ~/.iotstack/debug.env

# Use it
iotstack -env=debug.env update bleproxy

# Revert to default
iotstack update bleproxy  # Uses ~/.iotstack/.env
```
