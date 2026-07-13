# Next steps -- handoff for the next agent

Purpose: a ready-to-paste starting prompt plus context. The test suite has been
pruned to **hardware-validated builds only**, so it is now a trusted regression
gate: green == your changes did not break a known-good build.

---

## Paste this as the first message to a new agent

```
Read CLAUDE.md (project index -- load topic files on demand, don't read them all).

Session init (in order):
1. Run: scripts/init_claude_session.sh   (aligns this clone to the canonical local
   repo; work in the clone only, never edit the canonical repo directly).
2. Check the FILESYSTEM (not `git status`) for a watch file:  ls .agentstartstack-bump
   If present, before your first commit run:
     git submodule update --init --recursive --remote .agentstartstack
     git add .agentstartstack && rm .agentstartstack-bump
   and fold the bump into that commit (.agentstartstack/agentstartstack/workflow.md sec 4).
3. Read docs/nextsteps.md (this file).

Your focus: treat tests/cases/ as a regression gate for the hardware-validated
builds. Workflow for any change you make:
  - Run `iotstack tests run` to get a green baseline (needs a C6 bleproxy device on
    USB/network; `iotstack tests ports` to check).
  - Make the change, then run `iotstack tests run` again -- it must stay green.
    A new failure means you regressed a validated build; fix before continuing.
  - Only ADD/restore a build's test cases after that build is proven on real
    hardware (the human confirms). Never assert a build works without that.

Work in the session clone, commit when a task is complete, let me run `ass sync`.
Never push to origin.
```

---

## What the suite covers now (the validated gate)

Pruned to **ESP32-C6 / bleproxy** -- the only build proven on hardware this session
(flash -> boot -> WiFi -> BLE proxy -> encrypted API, with the external u.FL antenna).
14 cases remain and they exercise exactly the flash/OTA/compile machinery recent work
touched:

- `00-06` bleproxy: serial+OTA flash, verify, update (delta/force), list, bootstrap list
- `10-14` boot-partition toggle, bootstrap-only flash, bootstrap->bleproxy reassign
- `15-16` compile cache hit/miss (build_info.json config_hash)

This gate is also the way to validate this session's still-unexercised tooling fixes:
- `00-flash-bleproxy` (serial path) should show, in `-serial.log`, the boot summary
  incl. `git_commit loaded from NVS` -> confirms the serial-capture by-id fix (581ffb7).
- Step 0 should print `iotstack git commit (HEAD): ...` (4c0a450).
- No flash should print "Matrix layout ... to NVS" for bleproxy (db69ff5).
- A stalled C6 connect should print the RESET prompt (a3aa368).

Pruned cases (mmwave reassign cycle, ledlightstrip-* , silentnotify, matrixdisplay)
are in git history; restore + update them per build as each is validated.

---

## Where things stand (validated vs not)

Validated on hardware: **bleproxy on XIAO C6** (devices 1a6374, 137284), antenna attached.

NOT validated (no tests until they are):
- `ledlightstrip-c6-thread` -- never flashed; the esp-idf + esp32_rmt_led_strip +
  Thread + SK6812 RGBW path is the biggest unknown.
- `ledlightstrip-s3-wifi` -- never flashed; also unverified 8MB S3 partitioning.
- mmwave / threadrouter / silentnotify / sendspin / matrixdisplay -- not
  flashed this session (regression risk from the shared-package + rename changes).

When the human validates one of these, that's the trigger to (re)write its cases.

---

## Carry-forward gotchas
- **External u.FL antenna REQUIRED** on any C6 built with
  `common/xiao_c6_ext_antenna.yaml` (bleproxy, threadrouter, mmwave,
  ledlightstrip-c6-thread). No pigtail -> ~-69 dBm, mDNS discovery fails, flash
  "can't find device". Onboard ceramic only if you drop that package.
- **C6 USB auto-reset is unreliable** -- on an esptool connect stall, the new prompt
  asks you to press RESET (or hold BOOT + tap RESET). A flashed C6 that "won't
  appear" is usually weak signal/mDNS, not a dead board -- confirm with
  `picocom -b 115200 /dev/ttyACM0` (you'll see boot + WiFi RSSI).

---

## Smaller follow-ups (lower priority)
- `ass sync all` didn't flag this clone with `.agentstartstack-bump` -- check that its
  `agent_session_clones_list` path pattern covers `~/.claude/worktrees/...`.
- IP-override for flash/update (`IOTSTACK_OTA_HOST`) -- deferred; `.local`/mDNS is
  baked into `_iotstack_tcp_open`, the avahi-browse discovery, and `esphome upload`.
