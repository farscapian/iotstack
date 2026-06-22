# iotstack -- AI Development Notes (index)

ESP32 ESPHome device management. **Load topic files from `agentstartstack/` instead of reading this index repeatedly.**

## Quick rules

- Branding: always lowercase `iotstack` (never IoT Stack / iotStack)
- Text: ASCII-only in docs, logs, help, and code comments
- Agents work in session clones, NOT in Sync: Grok -> `~/.grok/worktrees/mini-projects-iotstack/<session-id>/`; Claude Code -> `~/.claude/worktrees/mini-projects-iotstack/<session-id>/`; CLI runs from `~/Sync/mini_projects/iotstack`
- Claude Code: NEVER edit files under `~/Sync/mini_projects/iotstack` -- use absolute paths to your session clone only
- New Grok session: run `scripts/init_grok_session.sh`; new Claude Code session: run `scripts/init_claude_session.sh` (session sync + agent tips; see `agentstartstack/workflow.md`)
- After changes: commit in session clone; human runs `nut` then `git push origin main` (or `nutup`). NEVER `git push origin` from agents (see `agentstartstack/nut.md`)
- Never `git pull` on Sync or test `/dev/ttyACM0` while the human has `iotstack` running (see `workflow.md`)
- When the human runs `iotstack` on Sync: tail `~/.iotstack/logs/sessions.watch` for new runs, then their session/serial logs (`workflow.md` § Watching live runs)

## Topic index

| File | Load when |
|------|-----------|
| [agentstartstack/conventions.md](agentstartstack/conventions.md) | Naming, ASCII-only text, CLI output tags |
| [agentstartstack/workflow.md](agentstartstack/workflow.md) | Repos, agent session clones (Grok + Claude Code), git sync, `sessions.watch` live monitoring, `iotstack ps`/`kill` |
| [agentstartstack/nut.md](agentstartstack/nut.md) | `nut` command -- Newest commit Until Transferred (human Sync handoff) |
| [agentstartstack/configuration.md](agentstartstack/configuration.md) | `~/.iotstack/.env`, compilation cache flags |
| [agentstartstack/architecture.md](agentstartstack/architecture.md) | mDNS discovery, compile cache, YAML, project version |
| [agentstartstack/features.md](agentstartstack/features.md) | Update subsets, delta OTA, reassign, verify, HA |
| [agentstartstack/cli.md](agentstartstack/cli.md) | `iotstack.sh`, `roles.conf`, command examples |
| [agentstartstack/partitions.md](agentstartstack/partitions.md) | Bootstrap/production partition sizing |
| [agentstartstack/implementation.md](agentstartstack/implementation.md) | Stdout redirect, temp files, logging paths |
| [agentstartstack/gotchas.md](agentstartstack/gotchas.md) | Bootstrap OTA, `--erase`, mDNS TXT, matrix NVS |
| [agentstartstack/pitfalls.md](agentstartstack/pitfalls.md) | Symptom -> cause -> fix lookup table |
| [agentstartstack/devices.md](agentstartstack/devices.md) | Per-role hardware notes |
| [agentstartstack/nvs-secrets.md](agentstartstack/nvs-secrets.md) | NVS namespace, WiFi/Thread from NVS, pass store |
| [agentstartstack/security.md](agentstartstack/security.md) | Never print secrets; `pass insert` twice |
| [agentstartstack/flash-encryption.md](agentstartstack/flash-encryption.md) | eFuses / flash encryption (TODO) |
| [agentstartstack/testing.md](agentstartstack/testing.md) | Pre-handoff device testing checklist |
| [agentstartstack/code-quality.md](agentstartstack/code-quality.md) | shellcheck rules and examples |
| [agentstartstack/references.md](agentstartstack/references.md) | External docs and key source files |

Full catalog and review notes: [agentstartstack/README.md](agentstartstack/README.md).