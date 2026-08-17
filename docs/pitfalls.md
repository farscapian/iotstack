# Common Pitfalls


| Issue | Root Cause | Solution |
|-------|-----------|----------|
| Prompt doesn't appear, script hangs | User input code runs after stdout redirect | Use `>&2` for messages, `</dev/tty` for input |
| `grep: invalid option -- '$'` | Pattern starts with dash (e.g., `-19b164$`) | Use `grep -- ` to stop option processing |
| Device discovery finds wrong devices | Filtering by device_name in reassign mode | In reassign mode, discover `_iotstack-bootstrap._tcp`, filter by MAC suffix |
| Entity updates affect wrong integrations | Not checking platform field | Always filter: `if platform != 'esphome': continue` |
| `iotstack verify` prints nothing / exits immediately | `log()` returned 1 under `set -e` when not verbose | `log()` always returns 0; use `info()` for required output |
| `--erase` says it will reflash but exits early | Assessment ignored `FLASH_ERASE` on mDNS hash match | Honor `FLASH_ERASE` in all match branches; pull latest `main` |
| `iotstack update ... --erase` or `update_devices.sh --erase` errors out | `--erase` was removed from both; it is USB-only, valid only for `iotstack flash` | Use `iotstack flash <role> <tty> --erase` for a full USB erase and reinstall |
| OTA fails immediately, no error in session log, flash log dir empty | `FIRMWARE_BIN` in `update_devices.sh` used relative `yamls/` path; resolves incorrectly when CWD != project root | Fixed: uses `${YAMLS_DIR}` (absolute). If you see this again, check `FIRMWARE_BIN` assignment. |
| OTA success shows `hash: unknown` | Bootstrap host missing TXT (old firmware) or avahi browse miss | Reflash bootstrap so `_iotstack-bootstrap._tcp` carries `config_hash`; `_resolve_build_config_hash` fallback |
| Slow bootstrap USB assess (~60s) | mDNS fast path skipped (device offline or old bootstrap without TXT) | Ensure bootstrap on WiFi; reflash bootstrap once to pick up mDNS TXT records |
| Literal `\033[0;32m` in compile spinner | `printf` + single-quoted color vars | Use `$'\033[...]'` or `[INFO]` lines only |
| `--horizontal-panel-count=2` ignored when firmware current | Layout is NVS, not config_hash | Bootstrap NVS update path even when firmware matches |
| Stale CLI behavior after fixes | Testing against unpulled `main` | `git pull origin main` on `~/Sync/mini_projects/iotstack` (or Grok clone behind Sync) |
| ROM boot loop after USB flash (`entry 0x403c8914`, no app logs) | esptool flash params mismatched build `flash_args` (was hardcoded 40m) | Fixed: `esp_esptool_flash_params_for_build()`; re-flash with `--erase` on stale devices |
| ROM boot loop, `rst:0xc`, `Saved PC` in app IRAM (~0x4037xxxx), no USB output | ESP32-S3 N16R8: OPI PSRAM shares MSPI clock; bootstrap built without `psram:` causes MSPI timing crash ~1s after first boot | Add `psram:` to bootstrap.yaml (handled by `bootstrap_render_yaml()` for esp32s3 only); recompile and re-flash with `--erase` |
| Agent misses human's flash run | Not watching `sessions.watch` | Tail `~/.iotstack/logs/sessions.watch`; parse session/serial log paths -- `workflow.md` |
| Hung flash holds `/dev/ttyACM0` | Detached `serial-logs.py` in separate session | `iotstack ps` then `iotstack kill` |
| Multiple `[OK] NVS` lines in session log | Nested `write-nvs-secrets.sh` + parent `iotstack.sh` messages | One NVS write; see session log sources in `workflow.md` |
| NVS write fails: `.espressif/python_env/idf.../python3: No such file or directory` | `write-nvs-secrets.sh` used to hardcode the ESP-IDF toolchain's own venv, which only exists after a real (non-cached) ESP-IDF compile has run `idf_tools.py` -- and that needs internet | Fixed: uses the esphome venv (`~/.local/esphome/venv`) instead, which `setup.sh` now also installs `esp-idf-nvs-partition-gen` into; works fully offline. If you still hit this, rerun `setup.sh` |
