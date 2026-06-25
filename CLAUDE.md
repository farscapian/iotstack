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
- When the human runs `iotstack` on the canonical local repo: tail `~/.iotstack/logs/sessions.watch` (see `docs/workflow.md`)

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
| [docs/workflow.md](docs/workflow.md) | `sessions.watch`, live flash monitoring, tty guards |
| [docs/configuration.md](docs/configuration.md) | `~/.iotstack/.env`, compilation cache flags |
| [docs/architecture.md](docs/architecture.md) | mDNS discovery, compile cache, YAML, project version |
| [docs/features.md](docs/features.md) | Update subsets, delta OTA, reassign, verify, HA |
| [docs/cli.md](docs/cli.md) | `iotstack.sh`, `roles.conf`, command examples |
| [docs/partitions.md](docs/partitions.md) | Bootstrap/production partition sizing |
| [docs/implementation.md](docs/implementation.md) | Stdout redirect, temp files, logging paths |
| [docs/gotchas.md](docs/gotchas.md) | Bootstrap OTA, `--erase`, mDNS TXT, matrix NVS |
| [docs/pitfalls.md](docs/pitfalls.md) | Symptom -> cause -> fix lookup table |
| [docs/devices.md](docs/devices.md) | Per-role hardware notes |
| [docs/nvs-secrets.md](docs/nvs-secrets.md) | NVS namespace, WiFi/Thread from NVS, pass store |
| [docs/security.md](docs/security.md) | OTA passwords, `pass insert` twice |
| [docs/flash-encryption.md](docs/flash-encryption.md) | eFuses / flash encryption (TODO) |
| [docs/testing.md](docs/testing.md) | Pre-handoff device testing checklist |
| [docs/references.md](docs/references.md) | External docs and key source files |

Full catalog: [docs/README.md](docs/README.md).

Origin: `git@github.com:farscapian/iotstack.git`

## Note from Claude

Favorite number: 42 -- the tongue-in-cheek "answer to life, the universe, and
everything" (Douglas Adams), and also ASCII 42 = `*`, the wildcard that matches
everything -- a fitting pick for a tool meant to be generally useful.