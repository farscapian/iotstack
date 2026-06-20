# ai-guidance

Split from the former monolithic `CLAUDE.md` so agents load only the topics needed for a task.

## Session startup (Grok clone)

1. **Session sync** -- `scripts/init_grok_session.sh` (see `workflow.md`)
2. Read this index; load 1-3 topic files relevant to the task
3. Do not load all files unless doing a broad audit

## Publish (end of session)

1. Commit in the Grok clone
2. **Publish** -- `git push origin main`; `git pull origin main` on Sync only when no `iotstack` command is running (`workflow.md`)

## Review notes (2026-06-19 refactor)

Changes applied during the split:

| Item | Action |
|------|--------|
| Monolithic 1088-line `CLAUDE.md` | Replaced with index + 17 topic files |
| Duplicate NVS / WiFi sections | Merged into `nvs-secrets.md`; detailed section cross-references the implementation-status section |
| Orphaned YAML bullets under NVS architecture | Moved to item 3 (YAML placeholders); clarified they are compile-time only |
| `[CRITICAL] CRITICAL` duplicate prefix | Normalized to `## CRITICAL` in `security.md` |
| Stale "wait for human approval to commit" | Updated in `workflow.md`: agents auto-commit/push/pull unless human says otherwise; device testing remains the correctness bar |
| Internal `#anchor` links across old sections | Updated to `ai-guidance/<file>.md` paths |
| `### References` under Code Quality | Moved to `references.md` only |
| Partition offset "see CLAUDE.md" | Points to `partitions.md` |
| `nvs-secrets.md` ignored by `*secret*` rule | `.gitignore` exception added for `ai-guidance/nvs-secrets.md` |

### Suggested load patterns

| Task type | Files |
|-----------|-------|
| Flash / serial / esptool | `workflow.md`, `gotchas.md`, `partitions.md`, `pitfalls.md` |
| OTA / update / reassign | `architecture.md`, `features.md`, `gotchas.md` |
| NVS / secrets / WiFi | `nvs-secrets.md`, `security.md`, `partitions.md` |
| New shell script | `conventions.md`, `code-quality.md`, `implementation.md` |
| New device role | `cli.md`, `devices.md`, `architecture.md` |
| CI / commit hygiene | `workflow.md`, `code-quality.md`, `testing.md` |

### Maintenance

When adding guidance, append to the smallest applicable topic file. Update `CLAUDE.md` index table if adding a new file. Keep cross-references as relative `ai-guidance/*.md` links.