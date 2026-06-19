#!/usr/bin/env bash
# Run ShellCheck on staged .sh files (git pre-commit helper).
set -euo pipefail

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "pre-commit: shellcheck is required but not installed." >&2
  echo "Install: sudo apt install shellcheck   (Debian/Ubuntu)" >&2
  exit 1
fi

root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "pre-commit: not inside a git repository." >&2
  exit 1
}
cd "$root"

mapfile -t files < <(
  git diff --cached --name-only --diff-filter=ACM | grep -E '\.sh$' || true
)

if [[ ${#files[@]} -eq 0 ]]; then
  exit 0
fi

existing=()
for f in "${files[@]}"; do
  [[ -f "$f" ]] && existing+=("$f")
done

if [[ ${#existing[@]} -eq 0 ]]; then
  exit 0
fi

echo "shellcheck (pre-commit): ${#existing[@]} staged script(s)..."
# -S error: gate commits on hard failures; run full shellcheck -x manually for warnings.
shellcheck -x -S error "${existing[@]}"