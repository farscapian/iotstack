# Next steps -- handoff for the next agent

Purpose: a ready-to-paste starting prompt plus context so a fresh agent can pick up
where the last session (LED-strip migration + C6 flash-tooling fixes) left off.

---

## Paste this as the first message to a new agent

```
Read CLAUDE.md (project index -- load topic files on demand, don't read them all).

Session init (do this first, in order):
1. cd to this session clone and run: scripts/init_claude_session.sh
   (aligns the clone to the canonical local repo; never edit ~/Sync... directly).
2. Check the FILESYSTEM (not `git status`) for a watch file:  ls .agentstartstack-bump
   If it exists, before your first commit run:
     git submodule update --init --recursive --remote .agentstartstack
     git add .agentstartstack && rm .agentstartstack-bump
   and fold the bump into that commit (see .agentstartstack/agentstartstack/workflow.md sec 4).
3. Read agentstartstack/nextsteps.md (this file) for status + the task list.

Then start on "Recommended focus" below. Work in the session clone only, commit when a
task is complete, and let me run `nut` -- never push to origin.
```

---

## Where things stand (as of commit 874e89b)

Last session migrated the LED strip to the XIAO ESP32-C6/S3 and hardened the C6
serial-flash tooling. Roles now (see `scripts/roles.conf`):

`bleproxy`, `mmwave`, `sendspinspeaker`, `ledlightstrip-c6-thread`,
`ledlightstrip-s3-wifi`, `threadrouter`, `silentnotify`, `matrixdisplay`

Naming convention: roles with multiple builds use `<role>-<chip>-<network>`
(e.g. `ledlightstrip-c6-thread`, `ledlightstrip-s3-wifi`). Single-build roles stay
unqualified; chip/network are introspected from the YAML.

### Validated on hardware this session
- `bleproxy` on XIAO C6 (devices `1a6374`, `137284`): flash -> boot -> WiFi -> BLE
  proxy -> encrypted API all green, **with the external u.FL antenna attached**.

### NOT yet validated on hardware (the real work)
- **`ledlightstrip-c6-thread`** (Thread) -- never flashed. The whole esp-idf +
  `esp32_rmt_led_strip` + Thread + SK6812 RGBW path is unproven.
- **`ledlightstrip-s3-wifi`** (S3/WiFi) -- never flashed. Also: 8MB S3 partitioning
  via `partition_manager` is unconfirmed (only 4MB C6 and 16MB S3-devkit are proven).
- **Flash-tooling fixes from this session, not yet exercised in their target case:**
  - `581ffb7` serial-capture by-id -- needs a serial flash (`--erase`) on a
    re-enumerating C6 to confirm the serial log now captures boot output.
  - `a3aa368` RST prompt -- needs an esptool connect stall to confirm it fires.
  - `db69ff5` matrix-layout NVS gating -- flash a non-matrix role and confirm NO
    "Matrix layout ... to NVS" lines; flash `matrixdisplay --panel-count=2` and
    confirm the change actually applies.
  - `4c0a450` preflight git-commit line -- confirm "iotstack git commit (HEAD): ..."
    prints in Step 0.
- mmwave / threadrouter / silentnotify / sendspinspeaker / matrixdisplay -- not
  flashed this session (regression risk from the shared-package / rename changes).

### Known hardware/tooling gotchas (carry forward)
- **External u.FL antenna is REQUIRED** on any C6 built with
  `common/xiao_c6_ext_antenna.yaml` (bleproxy, threadrouter, mmwave,
  ledlightstrip-c6-thread). No pigtail -> ~-69 dBm / mDNS discovery fails / flash
  can't find the device. Onboard ceramic is fine only if you drop that package.
- **C6 USB auto-reset is unreliable** -- esptool's `default-reset` may not enter
  download mode; when it stalls, the new prompt asks you to press RESET (or
  hold BOOT + tap RESET). A flashed C6 that "won't appear" is usually weak
  signal/mDNS, not a dead board -- confirm with `picocom -b 115200 /dev/ttyACM0`.

---

## Recommended focus (my call): validate first, then automate

You asked whether to do more flashing or invest in the test suite. **Are we there
yet on test automation? Close, but no** -- the `tests/cases/` suite is solid for the
C6/WiFi roles, but: it's hardware-in-the-loop (needs devices on the bench, not CI),
`ledlightstrip-c6-thread` has **zero** coverage (all ledstrip cases are `-s3-wifi`),
and none of this session's tooling fixes are asserted. So the two ideas aren't an
either/or -- do the flashing **through** the test suite so it produces durable
coverage. Concretely:

### Phase 1 -- smoke-validate the unproven builds (fast feedback)
1. `iotstack flash ledlightstrip-c6-thread /dev/ttyACM0` (u.FL attached). Confirm it
   compiles (esp-idf + esp32_rmt_led_strip + openthread), boots, joins Thread, and the
   SK6812 strip actually lights / runs effects. This is the single biggest unknown.
2. `iotstack flash ledlightstrip-s3-wifi /dev/ttyACM0` on a XIAO S3. Watch the 8MB
   partition build; confirm WiFi + strip.
3. `iotstack flash bleproxy /dev/ttyACM0 --erase` -- this exercises the serial path:
   confirm (a) Step 0 prints the git commit, (b) the `-serial.log` now contains the
   boot summary incl. `git_commit loaded from NVS` (validates 581ffb7), and (c) NO
   matrix-layout lines (validates db69ff5).
4. Quick regression pass: flash one of mmwave / threadrouter to be sure the shared
   `xiao_c6_ext_antenna.yaml` package didn't break them.

### Phase 2 -- turn the validation into regression coverage
5. Add a `*-flash-ledlightstrip-c6-thread` test case (Thread role -- mirror the
   `-s3-wifi` cases; note Thread OTA quirks / `--jobs 1`).
6. Add assertions for this session's fixes: e.g. a check that a non-matrix flash log
   has no "Matrix layout" line; that the serial log is non-empty after a serial flash.
7. Then `iotstack tests ports` + `iotstack tests run` for an end-to-end pass; iterate.

Rationale: a large volume of unvalidated change landed this session (role migration,
shared packages, four tooling fixes). Proving it on hardware is the highest-value next
move, and routing that through the test cases means the next migration won't silently
regress these roles.

---

## Smaller follow-ups (lower priority)
- `nutupyall` did not flag this clone with `.agentstartstack-bump` -- check that its
  `_nutupyall_session_clones` path pattern covers `~/.claude/worktrees/...` so future
  in-flight bumps get flagged automatically.
- IP-override for flash/update (`IOTSTACK_OTA_HOST`) -- deferred; only worth it as a
  marginal-signal safety net since the antenna fixed discovery. The `.local`/mDNS
  assumption is baked into `_iotstack_tcp_open`, the `avahi-browse` discovery, and the
  `esphome upload --device` target.
- Clean same-board antenna A/B RSSI number was never captured (onboard vs u.FL on one
  board) -- nice-to-have confirmation, not blocking.
