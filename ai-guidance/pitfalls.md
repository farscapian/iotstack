# Common Pitfalls


| Issue | Root Cause | Solution |
|-------|-----------|----------|
| Prompt doesn't appear, script hangs | User input code runs after stdout redirect | Use `>&2` for messages, `</dev/tty` for input |
| `grep: invalid option -- '$'` | Pattern starts with dash (e.g., `-19b164$`) | Use `grep -- ` to stop option processing |
| Device discovery finds wrong devices | Filtering by device_name in reassign mode | In reassign mode, discover `_iotstack-bootstrap._tcp`, filter by MAC suffix |
| Entity updates affect wrong integrations | Not checking platform field | Always filter: `if platform != 'esphome': continue` |
| `iotstack verify` prints nothing / exits immediately | `log()` returned 1 under `set -e` when not verbose | `log()` always returns 0; use `info()` for required output |
| `--erase` says it will reflash but exits early | Assessment ignored `FLASH_ERASE` on mDNS hash match | Honor `FLASH_ERASE` in all match branches; pull latest `main` |
| OTA success shows `hash: unknown` | Bootstrap host missing TXT (old firmware) or avahi browse miss | Reflash bootstrap so `_iotstack-bootstrap._tcp` carries `config_hash`; `_resolve_build_config_hash` fallback |
| Slow bootstrap USB assess (~60s) | mDNS fast path skipped (device offline or old bootstrap without TXT) | Ensure bootstrap on WiFi; reflash bootstrap once to pick up mDNS TXT records |
| Literal `\033[0;32m` in compile spinner | `printf` + single-quoted color vars | Use `$'\033[...]'` or `[INFO]` lines only |
| `--panel-count=2` ignored when firmware current | Layout is NVS, not config_hash | Bootstrap NVS update path even when firmware matches |
| Stale CLI behavior after fixes | Testing against unpulled `main` | `git pull origin main` on `~/Sync/mini_projects/iotstack` (or Grok clone behind Sync) |
| ROM boot loop after USB flash (`entry 0x403c8914`, no app logs) | esptool `--flash-freq 40m` vs build `80m` in `flash_args` | Match build flash params; see `gotchas.md` |
| Agent misses human's flash run | Not watching `sessions.watch` | Tail `~/.iotstack/logs/sessions.watch`; parse session/serial log paths — `workflow.md` |
| Hung flash holds `/dev/ttyACM0` | Detached `serial-logs.py` in separate session | `iotstack ps` then `iotstack kill` |
| Multiple `[OK] NVS` lines in session log | Nested `write-nvs-secrets.sh` + parent `iotstack.sh` messages | One NVS write; see session log sources in `workflow.md` |
