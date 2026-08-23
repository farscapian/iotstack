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
- `--create-log` session artifacts (`iotstack.sh` / `scripts/create-log.sh`): everything for one session lives under `~/.iotstack/logs/<role>/<unix-timestamp>/` -- session log (`iotstack.log`), serial capture on flash (`serial.log`), and any archived YAML (`<kind>-<name>.yaml`). `<role>` is a best-effort guess at the device role from argv (falls back to the subcommand name for roleless commands like `clean`); `<unix-timestamp>` is seconds since epoch when `--create-log` was parsed. `IOTSTACK_LOG_ID` (GUID) still exists internally for the `sessions.watch` `log_id` column and same-second collision suffixes, but no longer names files directly. `sessions.watch` itself stays flat at `~/.iotstack/logs/sessions.watch` -- see `workflow.md`.
- `update_devices.sh` compilation output (independent of `--create-log`) goes to: `~/.iotstack/logs/<device>/<timestamp>.compile.log`
- Flash logs per device (`update_devices.sh`): `~/.iotstack/logs/<device>/<timestamp>-<hash>/`
- Per-device build cache: `~/.iotstack/logs/<device>.build.cache` (`esphome_version` + `config_hash`; the sole build-identity key, shared by `smart_compile` and `update_devices.sh`) -- a persistent cache, not a session log, so it stays flat and is not moved under `<role>/<timestamp>/`
- Cache invalidated whenever `config_hash` changes: any YAML / `common/` / `external_components/` edit (the latter two via the `project_version` fingerprint), a new git tag, or an ESPHome upgrade

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
