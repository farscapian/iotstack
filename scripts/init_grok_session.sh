#!/bin/bash
# init_grok_session.sh -- Grok session sync (AI git workflow step 1) and agent tips
#
# Usage:
#   scripts/init_grok_session.sh [session-clone-path]
#
# Run from inside a Grok session clone, or pass the clone path as the first argument.
# Sync source: ~/Sync/mini_projects/iotstack (override with IOTSTACK_SYNC_REPO).

set -euo pipefail

SYNC_REPO="${IOTSTACK_SYNC_REPO:-${HOME}/Sync/mini_projects/iotstack}"
GROK_PARENT="${IOTSTACK_GROK_WORKTREES:-${HOME}/.grok/worktrees/mini-projects-iotstack}"

info() { printf '[INFO] %s\n' "$*"; }
ok()   { printf '[OK]   %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERR]  %s\n' "$*" >&2; exit 1; }

# OSC 8 terminal hyperlink (Cursor, VS Code, iTerm2, etc.)
print_hyperlink() {
  local url="$1"
  local label="${2:-$url}"
  printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$url" "$label"
}

usage() {
  cat <<'EOF'
Usage: init_grok_session.sh [session-clone-path]

Session sync for the authorized AI git workflow: aligns a Grok/Cursor session
clone with the canonical Sync repo and prints reminders for efficient agent use.

Examples:
  cd ~/.grok/worktrees/mini-projects-iotstack/<session-id>
  /home/derek/Sync/mini_projects/iotstack/scripts/init_grok_session.sh

  init_grok_session.sh ~/.grok/worktrees/mini-projects-iotstack/<session-id>
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

resolve_repo_root() {
  local arg="${1:-}"
  if [[ -n "$arg" ]]; then
    [[ -d "$arg" ]] || err "Session path not found: $arg"
    (cd "$arg" && pwd)
    return 0
  fi
  git rev-parse --show-toplevel 2>/dev/null || true
}

REPO_ROOT="$(resolve_repo_root "${1:-}")"
[[ -n "$REPO_ROOT" ]] || err "Not inside a git repo. Pass the session clone path as an argument."

SYNC_REPO="$(cd "$SYNC_REPO" 2>/dev/null && pwd)" || err "Sync repo not found: $SYNC_REPO"
[[ -d "${SYNC_REPO}/.git" ]] || err "Sync path is not a git repo: $SYNC_REPO"

if [[ "$(readlink -f "$REPO_ROOT")" == "$(readlink -f "$SYNC_REPO")" ]]; then
  warn "Current directory is the Sync canonical repo, not a Grok session clone."
  warn "Init is intended for ~/.grok/worktrees/mini-projects-iotstack/<session-id>/"
  read -r -p "Continue anyway? [y/N] " confirm </dev/tty
  [[ "${confirm,,}" == "y" || "${confirm,,}" == "yes" ]] || exit 0
fi

cd "$REPO_ROOT"
git rev-parse --is-inside-work-tree &>/dev/null || err "Not a git work tree: $REPO_ROOT"

info "Session clone: $REPO_ROOT"
info "Sync source:   $SYNC_REPO"
echo ""

info "Session sync: fetching local-sync/main and resetting..."
if git remote get-url local-sync &>/dev/null; then
  git remote set-url local-sync "$SYNC_REPO"
else
  git remote add local-sync "$SYNC_REPO"
fi

git fetch local-sync main
git reset --hard local-sync/main
git clean -fd

COMMIT="$(git log -1 --oneline)"
BRANCH="$(git branch --show-current)"
WORKFLOW_MD="${REPO_ROOT}/agentstartstack/workflow.md"
WORKFLOW_FILE_URL="file://${WORKFLOW_MD}"

ok "Synced to ${BRANCH} @ ${COMMIT}"
printf '[INFO] Workflow guide: '
print_hyperlink "$WORKFLOW_FILE_URL" "agentstartstack/workflow.md"
printf '\n'
echo ""

# -- Agent usage reminder -------------------------------------------------------

cat <<'EOF'
================================================================================
Using Grok / Cursor agents efficiently (iotstack)
================================================================================

AI GIT WORKFLOW (authorized)
  1. Session sync  -- init_grok_session.sh once per session (you just ran this)
  2. Sync          -- when human says "sync": git push local-sync main
                      (pushes to ~/Sync/mini_projects/iotstack, NOT to origin)
                      Human reviews and pushes to origin -- NEVER the agent

FIRST MESSAGE (copy/paste template below)
  - Say you ran init_grok_session.sh (session sync complete).
  - State your task in one sentence.
  - Name 1-3 agentstartstack files to read (not all of them, not old monolithic text).

WHAT TO READ (pick 1-3 by task type)
  Flash / serial / TTY     -> workflow.md, gotchas.md, pitfalls.md
  OTA / update / reassign  -> architecture.md, features.md, gotchas.md
  NVS / secrets / WiFi     -> nvs-secrets.md, security.md
  New shell script         -> conventions.md, code-quality.md
  New device role          -> cli.md, devices.md, architecture.md
  Docs / workflow only     -> workflow.md, agentstartstack/README.md

  CLAUDE.md is an index only. Do not ask the agent to "read all of CLAUDE.md".

TOKEN TIPS
  - Session sync once per session (this script), not before every task.
  - Give concrete errors, ports, roles, and file paths up front.
  - Let the agent read source files after guidance, not the whole repo.
  - End of session: commit, then sync to Sync on request (git push local-sync main).
    Human reviews and pushes to origin when satisfied.

WATCHING LIVE RUNS (when human flashes from Sync)
  - Registry: ~/.iotstack/logs/sessions.watch (one TSV line per iotstack invocation)
  - On new line: tail session_log + serial_log columns; see workflow.md § Watching live runs
  - Typical logs: ~/.iotstack/logs/iotstack-<guid>.log and iotstack-<guid>-serial.log
  - Stuck run: iotstack ps  |  stop all: iotstack kill  (do not kill unless asked)

DO NOT
  - Start a session without session sync (stale clone -> wrong fixes).
  - Push to origin (git push origin main) -- HUMAN ONLY, never an AI agent.
  - Load nvs-secrets.md for unrelated flash bugs (large file).
  - Re-explain the AI git workflow every time (see agentstartstack/workflow.md).
  - git push local-sync while any iotstack command is running (pgrep -af 'iotstack').
  - Run USB/serial tests on /dev/ttyACM0 while iotstack is active on that port.
  - Wait for the human to paste flash logs if sessions.watch / log files are available.

WHEN HUMAN SAYS "sync"
  nut iotstack    # or: nut (from Sync pwd) -- see agentstartstack/nut.md
  # Human reviews changes in ~/Sync/mini_projects/iotstack, then pushes to origin.

================================================================================
Suggested first message to paste into the agent:
================================================================================
EOF

cat <<EOF
New session. init_grok_session.sh complete (session sync) -- on main at ${COMMIT}.

Task: <your task in one sentence>
Read: agentstartstack/workflow.md, agentstartstack/<pick-one-or-two-more>.md
Constraints: <device, /dev/tty*, role, files not to touch>
EOF

echo ""
info "Grok session directories: ${GROK_PARENT}/"
info "Canonical CLI repo:       ${SYNC_REPO}/"
printf '[INFO] Full workflow:            '
print_hyperlink "$WORKFLOW_FILE_URL" "agentstartstack/workflow.md"
printf '\n'