# Implementation Details


### Stdout/Stderr Redirection Issue
[WARN] **Critical for User Interaction**

The script redirects stdout to a log file:
```bash
exec > >(tee -a "$COMPILE_LOG_FILE") 2>&1
```

This breaks user prompts (`read -p`):
- Prompt goes to log file instead of terminal
- User can't see it and script appears to hang
- Input from stdin is lost

**Solution:** When you need user input AFTER the logging redirect:
```bash
# Write prompt/messages to stderr (bypasses stdout redirect)
echo "Continue?" >&2

# Read from terminal directly, not from stdin
read -p "Continue? (y/n) " -n 1 -r </dev/tty

# Confirm response to stderr
echo >&2
```

This is used in the `--reassign` offline device warning and the websocket client installation prompt.

### Temporary File Handling
- Temp YAML files go to `~/.iotstack/artifacts/` (not cluttering the repo)
- Temp files are cleaned up on script exit via `trap` handler
- Pattern: `.temp-reassign-<PID>.yaml` is gitignored

### Project.name Regex Handling
The `project.name` field in YAML can be quoted or unquoted:
```yaml
project:
  name: "iotstack.${device_name}"    # quoted
  # or
  name: iotstack.${device_name}      # unquoted
```

The regex must handle both:
```bash
r'(name:\s+["\']?)([^"\'\n]*)\$\{device_name\}([^"\'\n]*["\']?)'
```
- `["\']?` matches optional quote (start)
- `[^"\'\n]*` matches characters (no quotes, no newlines)
- `["\']?` matches optional quote (end)

### Logging Strategy
- Compilation output goes to: `~/.iotstack/logs/<device>/<timestamp>.compile.log`
- Flash logs per device: `~/.iotstack/logs/<device>/<timestamp>-<hash>/`
- Per-device build cache: `~/.iotstack/logs/<device>.build.cache` (YAML SHA + ESPHome version + config_hash)
- Global compilation cache: `~/.iotstack/compilation-cache.csv` (`image_hash` column; used by `smart_compile` / flash assessment)
- Cache invalidated on YAML/common/external_components changes, new git tag, or ESPHome upgrade

### Session log ordering (`create-log.sh`)

The session log line order matters for agents tailing the file:

```
<timestamp> [iotstack.sh] [INFO] Session log: /path/to/iotstack-<guid>.log
<timestamp> [iotstack.sh] [INFO] Serial log:  /path/to/iotstack-<guid>-serial.log
<timestamp> === iotstack flash matrixdisplay /dev/ttyACM0 --erase ===
```

**How this is achieved:**
- `create_log_setup()` creates/truncates the log file but does **not** write the `===` header.
- `create_log_write_header()` writes the `===` header separately; it is called in `main()` **after** the `info "Session log: ..."` and `info "Serial log: ..."` lines.
- The serial log file is `touch`ed before its path is announced so an agent can `tail -f` it immediately.

Do not merge `create_log_write_header()` back into `create_log_setup()` -- that restores the old ordering where the header appeared before the log path lines.
