# Command to run shellcheck on all .sh files:


find . -name "*.sh" -type f ! -path "./.git/*" ! -path "./resources/*" -print0 | xargs -0 shellcheck -x
What each part does:

find . -name "*.sh" -type f — Find all shell files recursively
! -path "./.git/*" — Exclude .git directory
! -path "./resources/*" — Exclude resources directory
-print0 | xargs -0 — Handle filenames with spaces safely (null-terminated)
shellcheck -x — Run shellcheck with -x flag (follow sourced files)
Variations:


# Simpler: just all .sh files (may include things you don't want)
find . -name "*.sh" -type f | xargs shellcheck

# Check specific directory
find ./scripts -name "*.sh" -type f | xargs shellcheck

# Show only errors (not warnings/info)
find . -name "*.sh" -type f | xargs shellcheck -S error

# Save report to file
find . -name "*.sh" -type f | xargs shellcheck > shellcheck-report.txt 2>&1