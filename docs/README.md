# iotstack project docs

Project-specific agent guidance. Generic workflow, `ask`, conventions, and security live in the **.agentstack** submodule.

## Session startup

1. Run `scripts/init_grok_session.sh` or `scripts/init_claude_session.sh`
2. Read root `CLAUDE.md`; load 1-3 files from this directory for the task

## Suggested load patterns

| Task type | Files |
|-----------|-------|
| Flash / serial / TTY | `workflow.md`, `gotchas.md`, `pitfalls.md` |
| Human started a flash / watch logs | `workflow.md` (sessions.watch) |
| OTA / update / reassign | `architecture.md`, `features.md`, `gotchas.md` |
| Auto-fallback / rollback to bootstrap | `boot-fallback.md`, `partitions.md`, `gotchas.md` |
| NVS / secrets / WiFi | `nvs-secrets.md`, `security.md` |
| New shell script | `.agentstack/docs/conventions.md`, `code-quality.md`, `implementation.md` |
| New device role | `cli.md`, `devices.md`, `architecture.md` |
| CI / commit hygiene | `.agentstack/docs/workflow.md`, `code-quality.md`, `testing.md` |
| Human local-sync handoff | `.agentstack/docs/ask.md`, `workflow.md` |

Append to the smallest applicable file. Update `CLAUDE.md` when adding a new file.