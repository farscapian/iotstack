# Conventions

## Naming

**Always use lowercase "iotstack"** -- never "IoT Stack" or "iotStack". Examples:
- OK: `iotstack update bleproxy`
- OK: `iotstack devices`
- BAD: ~~IoT Stack~~, ~~iotStack~~, ~~IOTSTACK~~

This applies in code comments, documentation, help text, and all user-facing messages.

## ASCII-only text

**All documents, logging output, code comments, and help text must be ASCII-only.**

- No Unicode symbols: checkmarks, arrows, emoji, box-drawing, em dashes, etc.
- Use `--` instead of em dash, `->` instead of arrow, `[OK]`/`[FAIL]` instead of checkmarks
- Section dividers in shell comments: `# -- Title --` not box-drawing characters
- ANSI color escape bytes in `$'\033[...]'` variables are OK for terminal coloring; message text itself stays ASCII
- Maintenance script: `scripts/ascii-only-sanitize.py` (character substitution only; preserves indentation)
- Run check: `python3 scripts/ascii-only-sanitize.py .` (exit 0 = all scanned text files ASCII)

## CLI output

Runtime script output uses plain ASCII status tags:

- `[INFO]`, `[OK]`, `[WARN]`, `[ERR]`, `[FAIL]`
- Use `matches`, `!=`, `...` instead of decorative characters
- Compile progress: `info "Compiling firmware..."` -- no animated compile spinners
- `iotstack.sh` uses `$'\033[...]'` only for tag colors in `echo -e`, never Unicode in message text
