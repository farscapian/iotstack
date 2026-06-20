# Development Workflow

## Canonical paths

- **Primary repo (CLI + daily use):** `~/Sync/mini_projects/iotstack` on branch `main`
- **CLI entrypoint:** `~/.local/bin/iotstack` -> symlinks to `iotstack.sh` in that repo
- **Grok/Cursor session clones:** `~/.grok/worktrees/mini-projects-iotstack/<session-id>/` (isolated full git clones for agent sessions; not linked `git worktree` entries)
- **Before testing fixes on Sync:** `git pull origin main` -- stale trees produce confusing output (e.g. `--erase` appearing to do nothing when the fix is not yet pulled)

## AI git workflow

Authorized workflow for Grok/Cursor agent sessions. Two steps: **session sync** at start, **publish** after commits.

### 1. Session sync (start of session)

Align the Grok clone with the canonical Sync repo. Run once per session (or after you edit directly on Sync).

**Recommended:** `scripts/init_grok_session.sh` -- session sync, session-goal prompt, and agent usage reminders.

```bash
cd ~/.grok/worktrees/mini-projects-iotstack/<session-id>
~/Sync/mini_projects/iotstack/scripts/init_grok_session.sh
```

Manual equivalent:

```bash
cd ~/.grok/worktrees/mini-projects-iotstack/<session-id>

git remote add local-sync ~/Sync/mini_projects/iotstack 2>/dev/null \
  || git remote set-url local-sync ~/Sync/mini_projects/iotstack

git fetch local-sync main
git reset --hard local-sync/main
git clean -fd
```

### 2. Publish (after commits)

Push from the Grok clone, then pull into the canonical repo so `~/.local/bin/iotstack` matches:

```bash
cd ~/.grok/worktrees/mini-projects-iotstack/<session-id>
git push origin main

cd ~/Sync/mini_projects/iotstack
git pull origin main
```

**Agents:** run publish after every commit in the Grok clone unless the human says not to.

**Humans editing Sync directly:** `git push origin main` from Sync, then session sync in any active Grok clone.

## Grok session clones

Grok/Cursor agent sessions work in an isolated clone under:

```text
~/.grok/worktrees/mini-projects-iotstack/<session-id>/
```

List session directories:

```bash
ls -la ~/.grok/worktrees/mini-projects-iotstack/
```

`git worktree list` inside any clone shows only that clone (these are separate repos, not linked git worktrees). The `iotstack` CLI always runs from `~/Sync/mini_projects/iotstack`.

## Git and commit policy

**Agent default:** commit, publish (push + pull on Sync) when a task is complete -- unless the human says not to commit yet.

**Correctness bar:** device testing against real hardware remains the standard for functional validation. Commits can land before the human has flashed every edge case; note untested areas in the commit message when relevant.

**Human override:** skip or defer commit/push when the human requests it (e.g. experimental WIP).

### Commit workflow (any clone)

1. Make code changes (Grok clone or Sync)
2. Stage changes (`git add`)
3. Commit with a clear message
4. Publish (Grok clone: push then pull on Sync; Sync-only: push then session sync in active Grok clones)
5. Tag releases with annotated tags (`git tag -a vX.Y.Z`) when appropriate -- firmware picks up the tag on next compile

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