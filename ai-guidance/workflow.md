# Development Workflow

## Canonical paths

- **Primary repo (CLI + daily use):** `~/Sync/mini_projects/iotstack` on branch `main`
- **CLI entrypoint:** `~/.local/bin/iotstack` -> symlinks to `iotstack.sh` in that repo
- **Grok/Cursor session clones:** `~/.grok/worktrees/mini-projects-iotstack/<session-id>/` (isolated full git clones for agent sessions; not linked `git worktree` entries)
- **Claude Code session clones:** `~/.claude/worktrees/mini-projects-iotstack/<session-id>/` (same isolation model; Claude Code edits here via absolute paths; VS Code stays open at Sync for human reference only)
- **Before testing fixes on Sync:** `git pull origin main` -- stale trees produce confusing output (e.g. `--erase` appearing to do nothing when the fix is not yet pulled)
- **Handoff between trees:** `origin/main` -- agents publish into it; humans pull it on Sync; new sessions session-sync from it

## Who edits where

| Role | Edit here | Why |
|------|-----------|-----|
| Grok/Cursor agent (active session) | `~/.grok/worktrees/mini-projects-iotstack/<session-id>/` | Isolated workspace; commits and publish without touching your daily tree |
| Claude Code agent (active session) | `~/.claude/worktrees/mini-projects-iotstack/<session-id>/` | Same isolation; human never edits these clones; Claude Code uses absolute paths |
| Human (manual work) | `~/Sync/mini_projects/iotstack` | Canonical repo; `~/.local/bin/iotstack` runs from here |

**Rule of thumb:** agents write their session clone; humans write Sync. Do not edit an active session clone by hand.

**Agent write access:** treat the open session clone as agent-owned for the duration of the session. No special file permissions required -- avoid parallel human edits in that directory instead.

**Human manual edits:** use Sync. Edit, test with `iotstack`, commit, `git push origin main`. Then session-sync any active agent clone so the agent sees your commits:

Grok:
```bash
~/Sync/mini_projects/iotstack/scripts/init_grok_session.sh \
  ~/.grok/worktrees/mini-projects-iotstack/<session-id>
```

Claude Code:
```bash
~/Sync/mini_projects/iotstack/scripts/init_claude_session.sh \
  ~/.claude/worktrees/mini-projects-iotstack/<session-id>
```

**Mid-session human intervention:** prefer telling the agent what to change. If you must edit git-tracked files yourself, edit Sync, push, then session-sync the agent clone -- do not patch the clone directly.

**When editing a session clone by hand is acceptable:** throwaway experiments, a session that is already finished, or running the init script (expected).

**Testing agent changes:** `iotstack` always runs from Sync. After the agent publishes, pull on Sync (or let publish do it), then test. Flashing against an unpulled Sync tree is a common source of false failures.

## AI git workflow

Authorized workflow for agent sessions (Grok/Cursor and Claude Code). Two steps: **session sync** at start, **publish** after commits.

### 1. Session sync (start of session)

Align the session clone with the canonical Sync repo. Run once per session (or after the human edits Sync and pushes).

**Grok/Cursor:** `scripts/init_grok_session.sh` -- session sync, session-goal prompt, and agent usage reminders.

```bash
cd ~/.grok/worktrees/mini-projects-iotstack/<session-id>
~/Sync/mini_projects/iotstack/scripts/init_grok_session.sh
```

**Claude Code:** `scripts/init_claude_session.sh` -- same sync + Claude Code specific reminders.

```bash
cd ~/.claude/worktrees/mini-projects-iotstack/<session-id>
~/Sync/mini_projects/iotstack/scripts/init_claude_session.sh
```

Manual equivalent (either agent type):

```bash
cd <session-clone-path>

git remote add local-sync ~/Sync/mini_projects/iotstack 2>/dev/null \
  || git remote set-url local-sync ~/Sync/mini_projects/iotstack

git fetch local-sync main
git reset --hard local-sync/main
git clean -fd
```

### 2. Sync (when human asks)

Push from the session clone to the local Sync repo. The human then reviews and pushes to origin. **Agents never push to origin.**

```bash
# Check no iotstack command is running (pushing to Sync updates its working tree):
pgrep -af '(/iotstack\.sh|/iotstack) ' || echo "safe to sync"

# Push to Sync (local-sync remote set up during session sync step):
git push local-sync main
```

`~/Sync/mini_projects/iotstack` is configured with `receive.denyCurrentBranch = updateInstead`, so the push also updates Sync's working tree.

**Human after sync:** review in Sync, then `git push origin main` when satisfied.

**Humans editing Sync directly:** `git push origin main` from Sync, then session-sync any active agent clone.

### 3. Active `iotstack` sessions (agents -- mandatory)

Do **not** disrupt a flash, compile, update, or other long-running `iotstack` command the human started on Sync.

#### Before publish (push + pull on Sync)

Sync to Sync **if and only if** no `iotstack` command is running:

```bash
# Any match means: do NOT git push local-sync yet
pgrep -af '(/iotstack\.sh|/iotstack) ' || echo "no iotstack sessions"
```

If anything is running: commit in the session clone, tell the human sync is pending, and push local-sync only after their session finishes.

#### Before serial / device testing

Never run tests that touch `/dev/ttyACM0` (or any USB serial port the human is using) while `iotstack` is active:

```bash
pgrep -af '(/iotstack\.sh|/iotstack) '    # running iotstack?
lsof /dev/ttyACM0 2>/dev/null             # port held by another process?
```

Includes: `iotstack flash`, `iotstack tests run`, `read-nvs-secrets.sh`, `write-nvs-secrets.sh`, `esptool` on that port, and hardware test cases that flash or probe USB.

**Safe without the port:** unit checks, `bash -n`, compile-only paths, mocks, and reading logs under `~/.iotstack/logs/`.

**When in doubt:** ask the human or wait for their running command to finish.

## Watching live iotstack runs (agents)

When the human runs `iotstack` from Sync (especially `flash`, `update`, or long compiles), **watch logs proactively** — do not wait for them to paste output. Every invocation appends one line to a session registry; use that to discover new runs and tail the right log files.

### Session registry (`sessions.watch`)

| Item | Value |
|------|--------|
| Default path | `~/.iotstack/logs/sessions.watch` |
| Config override | `IOTSTACK_SESSION_WATCH` in `scripts/config.sh` |
| Written by | `create_log_watch_append()` on every `iotstack` invocation (`scripts/create-log.sh`) |
| Excludes | Nothing — all subcommands append (including `iotstack ps` / `iotstack kill`) |

**Format:** tab-separated values (TSV). First line is a `#` header when the file is created:

```
#ts    pid    log_id    session_log    serial_log    command
2026-06-20T15:29:42-05:00    737318    a3f2b891-bc07-4a9f-8bba-f9cd7a929633    /home/derek/.iotstack/logs/iotstack-a3f2b891-bc07-4a9f-8bba-f9cd7a929633.log    /home/derek/.iotstack/logs/iotstack-a3f2b891-bc07-4a9f-8bba-f9cd7a929633-serial.log    iotstack --compilation-output --create-log flash matrixdisplay /dev/ttyACM0 --erase
```

| Column | Meaning |
|--------|---------|
| `ts` | ISO timestamp when the invocation started |
| `pid` | Top-level bash PID (use with `iotstack ps` / `kill -TERM -<pgid>`) |
| `log_id` | GUID generated by `--create-log`, or `-` |
| `session_log` | Path to session log, or `-` without `--create-log` |
| `serial_log` | `iotstack-<guid>-serial.log` when `--create-log` set on flash; else `-` |
| `command` | Full quoted invocation as typed |

### Agent workflow

1. **At session start** (or when flash work is likely), note the current tail of the watch file:
   ```bash
   tail -3 ~/.iotstack/logs/sessions.watch
   ```
2. **Poll or tail** for new lines (skip `#` header rows):
   ```bash
   tail -f ~/.iotstack/logs/sessions.watch
   ```
3. **On each new data line**, parse `session_log` (column 4) and `serial_log` (column 5). If either is `-`, only the other is available.
4. **Tail run logs** for milestones and errors:
   ```bash
   tail -f /home/derek/.iotstack/logs/iotstack-<guid>.log
   tail -f /home/derek/.iotstack/logs/iotstack-<guid>-serial.log   # flash with --create-log
   ```
5. **Report progress** to the human at key steps (compile skip/hit, layout flash, NVS, firmware write, bootstrap WiFi, OTA) without them pasting logs.

Quick one-shot check after noticing activity:

```bash
last=$(tail -1 ~/.iotstack/logs/sessions.watch)
# Parse session_log / serial_log from TSV (fields 4–5); then:
tail -30 "$(echo "$last" | cut -f4)"
```

### Logging flags (human side)

| Flag | Effect |
|------|--------|
| `--create-log` | Generates a GUID; session log `~/.iotstack/logs/iotstack-<guid>.log`; implies `-v` |
| `--create-log` on **flash** | Also captures device serial to `iotstack-<guid>-serial.log` (background `serial-logs.py`); paused during esptool operations |

Each `--create-log` invocation gets a fresh GUID and a new log file. Serial capture stops automatically before esptool writes and resumes after.

**Typical flash command from human:**

```bash
iotstack --compilation-output --create-log flash matrixdisplay /dev/ttyACM0 --erase
```

### Session log sources

Stamped lines include a source label — use it to see which layer failed:

| Source prefix | Origin |
|---------------|--------|
| `[iotstack.sh]` | CLI status / steps |
| `[esptool:esp32s3]` (etc.) | esptool writes during flash |
| `[write-nvs-secrets]` | NVS USB provisioning |
| `[serial:esp32s3:/dev/ttyACM0]` | Device UART/USB capture (`iotstack-<id>-serial.log`) |

Multiple `[OK] NVS ...` lines in one NVS step are **nested script + parent confirmations**, not duplicate NVS writes.

### Process inspection and cleanup

Prefer these over raw `pgrep` when diagnosing stuck runs:

```bash
iotstack ps          # pstree of each session + detached helpers (serial-logs, esptool)
iotstack kill        # stop all running iotstack sessions and helper trees (alias: iotstack ps kill)
```

`iotstack ps` excludes its own invocation. Detached **serial capture** (`serial-logs.py`) often runs in a **separate process group** from the main flash bash — `iotstack ps` lists it explicitly; `iotstack kill` stops both.

Manual fallback (root PID from `iotstack ps` or `sessions.watch`):

```bash
kill -TERM -$(ps -o pgid= -p <pid> | tr -d ' ')
pkill -TERM -f 'serial-logs.py.*ttyACM0'   # if port still busy
```

### Diagnosing flash failures (read serial + session together)

| Symptom | Likely cause | What to check |
|---------|----------------|---------------|
| Session log stops after layout flash; port busy | Old code resumed serial capture during esptool | Serial log flooded with `rst:0x3` ROM spam; `lsof /dev/ttyACM0` |
| `Bootstrap WiFi wait timed out` but serial shows **ROM loop only** (`entry 0x403c8914`, no `[nvs_secrets]`) | Bootstrap app **never booted** — not a WiFi timeout | `gotchas.md` flash-freq / `ota_data_initial` notes; session log esptool `--flash-freq` vs build `flash_args` |
| `Bootstrap WiFi wait timed out`; serial shows WiFi/`heartbeat` | Bootstrap up but slow or wrong network | `bootstrap-<mac>.local:3232`, WiFi creds in NVS |
| esptool verify failed | Transfer corruption (common on **C6 at baud > 9600**) | Session log; `esp_esptool_baud_for_chip()` |

**Safe while a run is active:** read `sessions.watch`, tail log files, `iotstack ps` (read-only). **Unsafe:** `git pull` on Sync, `iotstack kill` (unless asked), USB tests on the same `/dev/tty*`.

### Related guidance

- Serial baud for **esptool flash** (not serial monitor): `architecture.md` — C6 **9600**, S3/S2 **460800**
- Bootstrap WiFi probe: `gotchas.md` — OTA port **3232**, not a serial line
- Pitfalls table: `pitfalls.md` — stale Sync tree, `--erase` assessment, flash-freq mismatch

## End-to-end (quick reference)

**Start a Grok session**
1. Open the session folder in Cursor/Grok
2. Run `scripts/init_grok_session.sh` (session sync + goal prompt + agent tips)
3. Paste the suggested first message into the agent (task + 1-3 `ai-guidance/` files to read)

**Start a Claude Code session**
1. Create a session clone: `git clone git@github.com:farscapian/iotstack.git ~/.claude/worktrees/mini-projects-iotstack/<session-id>`
2. Run `scripts/init_claude_session.sh` from the clone (session sync + agent tips)
3. VS Code stays open at Sync for your reference; Claude Code edits the clone via absolute paths

**During any agent session**
- Agent edits and commits only in the session clone; never in Sync
- Human does not edit the session clone by hand; use Sync for manual work (push + session-sync to refresh the agent)
- When the human runs `iotstack` on Sync, watch `~/.iotstack/logs/sessions.watch` and tail the run's session/serial logs (see [Watching live iotstack runs](#watching-live-iotstack-runs-agents))

**After agent work**
- Agent syncs to Sync on request: `git push local-sync main` (never to origin)
- Human reviews in `~/Sync/mini_projects/iotstack`, then `git push origin main` when satisfied
- Human continues on Sync for CLI, flash, and follow-up edits

**Human-only work (no agent)**
- Edit, commit, and push from Sync only
- Next agent session picks up your commits via `init_grok_session.sh` or `init_claude_session.sh`

## Agent session clones

Both Grok and Claude Code use full git clones, not linked `git worktree` entries (`git worktree list` shows only the current clone).

Grok session directories:
```bash
ls -la ~/.grok/worktrees/mini-projects-iotstack/
```

Claude Code session directories:
```bash
ls -la ~/.claude/worktrees/mini-projects-iotstack/
```

Create a new Claude Code session clone:
```bash
git clone git@github.com:farscapian/iotstack.git ~/.claude/worktrees/mini-projects-iotstack/<session-id>
~/Sync/mini_projects/iotstack/scripts/init_claude_session.sh \
  ~/.claude/worktrees/mini-projects-iotstack/<session-id>
```

## Git and commit policy

**Agent default:** commit when a task is complete. Sync to Sync (`git push local-sync main`) only when the human asks, and only when no `iotstack` command is running (see [Active iotstack sessions](#3-active-iotstack-sessions-agents----mandatory)). Never push to origin -- that is human-only.

**Correctness bar:** device testing against real hardware remains the standard for functional validation. Commits can land before the human has flashed every edge case; note untested areas in the commit message when relevant.

**Human override:** skip or defer commit/push when the human requests it (e.g. experimental WIP).

### Commit workflow

**Agent (Grok or Claude Code session clone)**
1. Make code changes in the session clone (never in Sync)
2. `git add` and commit
3. When human says "sync": `git push local-sync main` (never `git push origin`)
4. Human reviews in Sync, then `git push origin main` when satisfied
5. Tag releases with annotated tags (`git tag -a vX.Y.Z`) when appropriate -- firmware picks up the tag on next compile

**Human (Sync repo)**
1. Make code changes on Sync
2. `git add`, commit, `git push origin main`
3. Session-sync any active agent clone before resuming agent work:
   - Grok: `init_grok_session.sh`
   - Claude Code: `init_claude_session.sh`

## Research FIRST, then debug

**When encountering a persistent problem, do targeted internet research BEFORE systematic debugging.**

Example: Baud rate issues with ESP32 flash corruption
- [FAIL] Bad: Try 460800 -> 115200 -> 57600 (3+ hours of testing)
- [OK] Good: Research "ESP32 firmware corruption baud rate" -> find 9600 standard (5 minutes)

**When to research:**
- Problem seems common or straightforward (baud rates, timeouts, memory issues)
- Embedded systems problem (existing best practices likely exist)
- Multiple attempts are failing with similar symptoms
- Problem affects reliability/stability (not just convenience)

**When systematic debugging is still appropriate:**
- Cutting-edge/novel problems without community precedent
- Edge cases specific to this project's architecture
- After research has identified the likely cause (then test to confirm)