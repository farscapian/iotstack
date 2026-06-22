# nut -- agent worktree to Sync

Human-side helper for the AI git workflow step **Sync** (agent session clone -> canonical Sync repo). Agents commit in the worktree; the human runs `nut` to land the newest commit on Sync, reviews, then `git push origin main`.

**Canonical install:** `~/.bash_aliases` (not tracked in this repo). The copy below is documentation of record -- update both repos if the function changes.

## Why "nut"

Backronym: **N**ewest commit **U**ntil **T**ransferred.

Pushes the latest commit from the matching agent worktree (Claude or Grok) into the canonical Sync tree at `~/Sync/mini_projects/<repo>`. Short to type, works for every mini-project, and intentionally a double entendre -- you are getting the newest commit out of the agent clone and into Sync before it goes anywhere else.

Retired names: `s2s`, `land`, `s2ps`, `s2is`, `push`, `nut push`.

## Usage

```bash
nut                 # infer repo from pwd (Sync tree or agent worktree)
nut iotstack        # explicit repo name, any pwd
nutup               # nut, then git push origin main
nutup iotstack      # nut for iotstack, then push
nut --help
nutup --help
```

**`nutup`** -- full human handoff: land the newest agent commit on Sync, then publish to `origin/main`. Agents never run `nutup` themselves.

**Conventions**

| Item | Path |
|------|------|
| Sync canonical | `~/Sync/mini_projects/<name>` (fallback: `~/Sync/<name>`) |
| Agent worktrees | `~/.claude/worktrees/mini-projects-<name>/*` |
| | `~/.grok/worktrees/mini-projects-<name>/*` |

Worktrees are matched by `origin` URL so repos cannot cross-contaminate. Among matches, the worktree with the newest commit on `main` wins.

## Guards (this repo)

`nut` refuses to run while long-running Sync-side tools are active (pushing updates the Sync working tree via `receive.denyCurrentBranch = updateInstead`):

| Repo | Blocks while |
|------|----------------|
| iotstack | `iotstack` / `iotstack.sh` running |
| printstack | `printstack` / `printstack.sh` running |

## Workflow

1. Agent commits in session clone
2. Human reviews (optional): `nut` lands agent commit on Sync
3. Human publishes: `git push origin main` from Sync, or combine: `nutup` (or `nutup iotstack`)

Agents never run `nut` or `nutup` unless the human explicitly asks.

See [workflow.md](workflow.md) for session sync, agent clone paths, and full git policy.

## Source (`~/.bash_aliases`)

```bash
#!/bin/bash

# Retired names -- clear if still loaded in this shell.
unset -f land s2s s2ps s2is push 2>/dev/null

# nut / nutup -- Newest commit Until Transferred
#
# Usage:
#   nut              # agent worktree -> Sync
#   nutup            # nut, then git push origin main
#   nutup iotstack   # explicit repo + push

_nut_sync_root() {
  local repo_name="$1"

  if [[ -d "${HOME}/Sync/mini_projects/${repo_name}/.git" ]]; then
    printf '%s/Sync/mini_projects/%s\n' "$HOME" "$repo_name"
    return 0
  fi
  if [[ -d "${HOME}/Sync/${repo_name}/.git" ]]; then
    printf '%s/Sync/%s\n' "$HOME" "$repo_name"
    return 0
  fi

  return 1
}

# Resolve Sync target from an agent worktree path.
_nut_sync_target_from_worktree() {
  local wt="$1" parent_base

  if git -C "$wt" remote get-url local-sync &>/dev/null 2>&1; then
    readlink -f "$(git -C "$wt" remote get-url local-sync)"
    return 0
  fi

  parent_base=$(basename "$(dirname "$wt")")
  if [[ "$parent_base" =~ ^mini-projects-(.+)$ ]]; then
    _nut_sync_root "${BASH_REMATCH[1]}"
    return $?
  fi

  return 1
}

# Block while long-running repo tools are active on Sync.
_nut_guard_active_sessions() {
  local sync_target="$1"

  case "$sync_target" in
    */mini_projects/iotstack|*/Sync/iotstack)
      if pgrep -af '(/iotstack\.sh|/iotstack) ' >/dev/null 2>&1; then
        echo "nut: iotstack is running -- wait for it to finish" >&2
        return 1
      fi
      ;;
    */mini_projects/printstack|*/Sync/printstack)
      if pgrep -af 'printstack\.sh|printstack (flash|refresh)' >/dev/null 2>&1; then
        echo "nut: printstack is running -- wait for it to finish" >&2
        return 1
      fi
      ;;
  esac

  return 0
}

_nut_push() {
  local sync_target="$1"
  local origin_target best_dir="" best_time=0 candidate t origin_wt commit repo_name

  sync_target=$(readlink -f "$sync_target")
  [[ -d "${sync_target}/.git" ]] || {
    echo "nut: not a git repo: $sync_target" >&2
    return 1
  }

  _nut_guard_active_sessions "$sync_target" || return 1

  origin_target=$(git -C "$sync_target" remote get-url origin 2>/dev/null) || {
    echo "nut: Sync repo has no origin remote: $sync_target" >&2
    return 1
  }

  repo_name=$(basename "$sync_target")

  for candidate in \
      "${HOME}/.claude/worktrees/mini-projects-${repo_name}/"*/ \
      "${HOME}/.grok/worktrees/mini-projects-${repo_name}/"*/; do
    [[ -d "${candidate}.git" ]] || continue
    candidate=$(readlink -f "$candidate")

    origin_wt=$(git -C "$candidate" remote get-url origin 2>/dev/null) || continue
    [[ "$origin_wt" == "$origin_target" ]] || continue

    t=$(git -C "$candidate" log -1 --format=%ct 2>/dev/null) || continue
    if [[ "$t" -gt "$best_time" ]]; then
      best_time=$t
      best_dir=$candidate
    fi
  done

  if [[ -z "$best_dir" ]]; then
    echo "nut: no agent worktree for ${repo_name}" >&2
    return 1
  fi

  if git -C "$best_dir" remote get-url local-sync >/dev/null 2>&1; then
    git -C "$best_dir" remote set-url local-sync "$sync_target"
  else
    git -C "$best_dir" remote add local-sync "$sync_target"
  fi

  commit=$(git -C "$best_dir" log -1 --oneline)
  echo "nut: ${commit}"
  echo "nut: ${best_dir} -> ${sync_target}"
  git -C "$best_dir" push local-sync main
}

_nut_resolve_sync_target() {
  local repo_arg="${1:-}"
  local here sync_target

  if [[ -n "$repo_arg" ]]; then
    sync_target=$(_nut_sync_root "$repo_arg") || {
      echo "nut: no Sync repo found for: ${repo_arg}" >&2
      return 1
    }
  else
    here=$(git rev-parse --show-toplevel 2>/dev/null) || {
      echo "nut: not in a git repo (try: nut <name>)" >&2
      return 1
    }
    here=$(readlink -f "$here")

    if [[ "$here" == *"/.grok/worktrees/"* || "$here" == *"/.claude/worktrees/"* ]]; then
      sync_target=$(_nut_sync_target_from_worktree "$here") || {
        echo "nut: cannot resolve Sync target from: $here" >&2
        return 1
      }
    else
      sync_target="$here"
    fi
  fi

  printf '%s\n' "$(readlink -f "$sync_target")"
}

nut()
{
  local repo_arg="${1:-}"

  if [[ "$repo_arg" == "-h" || "$repo_arg" == "--help" ]]; then
    cat <<'EOF'
nut -- Newest commit Until Transferred

Push the latest agent-worktree commit to the canonical Sync repo.

  nut                 infer repo from pwd
  nut <name>          e.g. nut printstack, nut iotstack
  nutup               nut, then git push origin main
  nutup <name>        nut for <name>, then push

Sync root:   ~/Sync/mini_projects/<name>  (or ~/Sync/<name>)
Worktrees:   ~/.claude/worktrees/mini-projects-<name>/*
             ~/.grok/worktrees/mini-projects-<name>/*
EOF
    return 0
  fi

  local sync_target
  sync_target=$(_nut_resolve_sync_target "$repo_arg") || return 1
  _nut_push "$sync_target"
}

nutup()
{
  local repo_arg="${1:-}"

  if [[ "$repo_arg" == "-h" || "$repo_arg" == "--help" ]]; then
    cat <<'EOF'
nutup -- nut, then git push origin main

  nutup               infer repo from pwd
  nutup <name>        e.g. nutup printstack, nutup iotstack
EOF
    return 0
  fi

  local sync_target
  sync_target=$(_nut_resolve_sync_target "$repo_arg") || return 1
  _nut_push "$sync_target" || return 1
  echo "nutup: ${sync_target} -> origin main"
  git -C "$sync_target" push origin main
}
```