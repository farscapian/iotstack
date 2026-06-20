# iotstack -- AI Development Notes (index)

ESP32 ESPHome device management. **Load topic files from `ai-guidance/` instead of reading this index repeatedly.**

## Quick rules

- Branding: always lowercase `iotstack` (never IoT Stack / iotStack)
- Text: ASCII-only in docs, logs, help, and code comments
- Agents work in session clones, NOT in Sync: Grok -> `~/.grok/worktrees/mini-projects-iotstack/<session-id>/`; Claude Code -> `~/.claude/worktrees/mini-projects-iotstack/<session-id>/`; CLI runs from `~/Sync/mini_projects/iotstack`
- Claude Code: NEVER edit files under `~/Sync/mini_projects/iotstack` -- use absolute paths to your session clone only
- New Grok session: run `scripts/init_grok_session.sh`; new Claude Code session: run `scripts/init_claude_session.sh` (session sync + agent tips; see `ai-guidance/workflow.md`)
- After changes: commit in the session clone; when human says "sync": `git push local-sync main` (NEVER `git push origin` -- human-only)
- Never `git pull` on Sync or test `/dev/ttyACM0` while the human has `iotstack` running (see `workflow.md`)
- When the human runs `iotstack` on Sync: tail `~/.iotstack/logs/sessions.watch` for new runs, then their session/serial logs (`workflow.md` § Watching live runs)

## Topic index

| File | Load when |
|------|-----------|
| [ai-guidance/conventions.md](ai-guidance/conventions.md) | Naming, ASCII-only text, CLI output tags |
| [ai-guidance/workflow.md](ai-guidance/workflow.md) | Repos, agent session clones (Grok + Claude Code), git sync, `sessions.watch` live monitoring, `iotstack ps`/`kill` |
| [ai-guidance/configuration.md](ai-guidance/configuration.md) | `~/.iotstack/.env`, compilation cache flags |
| [ai-guidance/architecture.md](ai-guidance/architecture.md) | mDNS discovery, compile cache, YAML, project version |
| [ai-guidance/features.md](ai-guidance/features.md) | Update subsets, delta OTA, reassign, verify, HA |
| [ai-guidance/cli.md](ai-guidance/cli.md) | `iotstack.sh`, `roles.conf`, command examples |
| [ai-guidance/partitions.md](ai-guidance/partitions.md) | Bootstrap/production partition sizing |
| [ai-guidance/implementation.md](ai-guidance/implementation.md) | Stdout redirect, temp files, logging paths |
| [ai-guidance/gotchas.md](ai-guidance/gotchas.md) | Bootstrap OTA, `--erase`, mDNS TXT, matrix NVS |
| [ai-guidance/pitfalls.md](ai-guidance/pitfalls.md) | Symptom -> cause -> fix lookup table |
| [ai-guidance/devices.md](ai-guidance/devices.md) | Per-role hardware notes |
| [ai-guidance/nvs-secrets.md](ai-guidance/nvs-secrets.md) | NVS namespace, WiFi/Thread from NVS, pass store |
| [ai-guidance/security.md](ai-guidance/security.md) | Never print secrets; `pass insert` twice |
| [ai-guidance/flash-encryption.md](ai-guidance/flash-encryption.md) | eFuses / flash encryption (TODO) |
| [ai-guidance/testing.md](ai-guidance/testing.md) | Pre-handoff device testing checklist |
| [ai-guidance/code-quality.md](ai-guidance/code-quality.md) | shellcheck rules and examples |
| [ai-guidance/references.md](ai-guidance/references.md) | External docs and key source files |

Full catalog and review notes: [ai-guidance/README.md](ai-guidance/README.md).