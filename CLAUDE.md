# iotstack -- AI Development Notes (index)

ESP32 ESPHome device management. **Load topic files on demand -- do not read this entire index repeatedly.**

## Quick rules

- Branding: always lowercase `iotstack` (never IoT Stack / iotStack)
- Text: ASCII-only in docs, logs, help, and code comments
- Agents work in session clones, NOT in the canonical local repo: Grok -> `~/.grok/worktrees/mini-projects-iotstack/<session-id>/`; Claude Code -> `~/.claude/worktrees/mini-projects-iotstack/<session-id>/`; CLI runs from the canonical local repo `~/Sync/mini_projects/iotstack`
- Claude Code: NEVER edit files under the canonical local repo (`~/Sync/mini_projects/iotstack`) -- use absolute paths to your session clone only
- New Grok session: run `scripts/init_grok_session.sh`; new Claude Code session: run `scripts/init_claude_session.sh` (see `.agentstartstack/agentstartstack/workflow.md`)
- After changes: commit in session clone; human runs `nut` then `git push origin main` (or `nutup`). NEVER `git push origin` from agents (see `.agentstartstack/agentstartstack/nut.md`)
- Never `nut` or `git pull` on the canonical local repo while `iotstack` is running
- When the human runs `iotstack` on the canonical local repo: tail `~/.iotstack/logs/sessions.watch` (see `agentstartstack/workflow.md`)

## Generic guidance (.agentstartstack submodule)

| File | Load when |
|------|-----------|
| [.agentstartstack/agentstartstack/workflow.md](.agentstartstack/agentstartstack/workflow.md) | Repos, session clones, git sync |
| [.agentstartstack/agentstartstack/nut.md](.agentstartstack/agentstartstack/nut.md) | `nut` / `nutup` handoff |
| [.agentstartstack/agentstartstack/conventions.md](.agentstartstack/agentstartstack/conventions.md) | Naming, ASCII-only, output tags |
| [.agentstartstack/agentstartstack/security.md](.agentstartstack/agentstartstack/security.md) | Never print secrets (generic) |
| [.agentstartstack/agentstartstack/code-quality.md](.agentstartstack/agentstartstack/code-quality.md) | shellcheck, git hooks |
| [.agentstartstack/agentstartstack/implementation.md](.agentstartstack/agentstartstack/implementation.md) | Common shell patterns |
| [.agentstartstack/agentstartstack/testing.md](.agentstartstack/agentstartstack/testing.md) | Generic pre-handoff checks |

## Project guidance

| File | Load when |
|------|-----------|
| [agentstartstack/workflow.md](agentstartstack/workflow.md) | `sessions.watch`, live flash monitoring, tty guards |
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
| [agentstartstack/security.md](agentstartstack/security.md) | OTA passwords, `pass insert` twice |
| [agentstartstack/flash-encryption.md](agentstartstack/flash-encryption.md) | eFuses / flash encryption (TODO) |
| [agentstartstack/testing.md](agentstartstack/testing.md) | Pre-handoff device testing checklist |
| [agentstartstack/references.md](agentstartstack/references.md) | External docs and key source files |

Full catalog: [agentstartstack/README.md](agentstartstack/README.md).

Origin: `git@github.com:farscapian/iotstack.git`