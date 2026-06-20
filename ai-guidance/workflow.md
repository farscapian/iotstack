# Development Workflow

## Canonical paths

- **Primary repo (CLI + daily use):** `~/Sync/mini_projects/iotstack` on branch `main`
- **CLI entrypoint:** `~/.local/bin/iotstack` -> symlinks to `iotstack.sh` in that repo
- **Grok/Cursor session clones:** `~/.grok/worktrees/mini-projects-iotstack/<session-id>/` (isolated full git clones for agent sessions; not linked `git worktree` entries)
- **Before testing fixes on Sync:** `git pull origin main` -- stale trees produce confusing output (e.g. `--erase` appearing to do nothing when the fix is not yet pulled)
- **Handoff between trees:** `origin/main` -- agents publish into it; humans pull it on Sync; new sessions session-sync from it

## Who edits where

| Role | Edit here | Why |
|------|-----------|-----|
| Grok/Cursor agent (active session) | `~/.grok/worktrees/mini-projects-iotstack/<session-id>/` | Isolated workspace; commits and publish without touching your daily tree |
| Human (manual work) | `~/Sync/mini_projects/iotstack` | Canonical repo; `~/.local/bin/iotstack` runs from here |

**Rule of thumb:** agents write the Grok session clone; humans write Sync. Do not edit the active Grok clone by hand during an agent session.

**Agent write access:** treat the open session clone as agent-owned for the duration of the session. No special file permissions required -- avoid parallel human edits in that directory instead.

**Human manual edits:** use Sync. Edit, test with `iotstack`, commit, `git push origin main`. Then session-sync any active Grok clone so the agent sees your commits:

```bash
~/Sync/mini_projects/iotstack/scripts/init_grok_session.sh \
  ~/.grok/worktrees/mini-projects-iotstack/<session-id>
```

**Mid-session human intervention:** prefer telling the agent what to change. If you must edit git-tracked files yourself, edit Sync, push, then session-sync the Grok clone -- do not patch the Grok clone directly.

**When editing the Grok clone by hand is acceptable:** throwaway experiments, a session that is already finished, or running `init_grok_session.sh` (expected).

**Testing agent changes:** `iotstack` always runs from Sync. After the agent publishes, pull on Sync (or let publish do it), then test. Flashing against an unpulled Sync tree is a common source of false failures.

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

## End-to-end (quick reference)

**Start a Grok session**
1. Open the session folder in Cursor/Grok
2. Run `scripts/init_grok_session.sh` (session sync + goal prompt + agent tips)
3. Paste the suggested first message into the agent (task + 1-3 `ai-guidance/` files to read)

**During the session**
- Agent edits and commits only in the Grok session clone
- Human does not edit that clone by hand; use Sync for manual work (push + session-sync to refresh the agent)

**After agent work**
- Agent publishes (push from Grok clone, pull on Sync)
- Human continues on Sync for CLI, flash, and follow-up edits

**Human-only work (no agent)**
- Edit, commit, and push from Sync only
- Next agent session picks up your commits via `init_grok_session.sh`

## Grok session clones

Session directories:

```bash
ls -la ~/.grok/worktrees/mini-projects-iotstack/
```

These are separate full git clones, not linked `git worktree` entries (`git worktree list` shows only the current clone).

## Git and commit policy

**Agent default:** commit, publish (push + pull on Sync) when a task is complete -- unless the human says not to commit yet.

**Correctness bar:** device testing against real hardware remains the standard for functional validation. Commits can land before the human has flashed every edge case; note untested areas in the commit message when relevant.

**Human override:** skip or defer commit/push when the human requests it (e.g. experimental WIP).

### Commit workflow

**Agent (Grok session clone)**
1. Make code changes in the session clone
2. `git add` and commit
3. Publish: `git push origin main`, then `git pull origin main` on Sync
4. Tag releases with annotated tags (`git tag -a vX.Y.Z`) when appropriate -- firmware picks up the tag on next compile

**Human (Sync repo)**
1. Make code changes on Sync
2. `git add`, commit, `git push origin main`
3. Session-sync any active Grok clone (`init_grok_session.sh`) before resuming agent work there

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