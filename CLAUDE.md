# iotstack -- AI Development Notes (index)

ESP32 ESPHome device management. **Load topic files from `ai-guidance/` instead of reading this index repeatedly.**

## Quick rules

- Branding: always lowercase `iotstack` (never IoT Stack / iotStack)
- Text: ASCII-only in docs, logs, help, and code comments
- Agents work in `~/.grok/worktrees/mini-projects-iotstack/<session-id>/`; CLI runs from `~/Sync/mini_projects/iotstack`
- New Grok session: run `scripts/init_grok_session.sh` (session sync + agent tips; see `ai-guidance/workflow.md`)
- After changes: commit in Grok clone, then publish (`git push origin main`, `git pull origin main` on Sync)

## Topic index

| File | Load when |
|------|-----------|
| [ai-guidance/conventions.md](ai-guidance/conventions.md) | Naming, ASCII-only text, CLI output tags |
| [ai-guidance/workflow.md](ai-guidance/workflow.md) | Repos, Grok clones, git sync, commit/push policy |
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