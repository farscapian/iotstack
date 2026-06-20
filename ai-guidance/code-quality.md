# Code Quality


### ShellCheck: Shell Script Validation

**All shell scripts must pass shellcheck with NO warnings**, including stylistic recommendations.

**Command to validate all scripts:**
```bash
find . -name "*.sh" -type f ! -path "./.git/*" ! -path "./resources/*" -print0 | xargs -0 shellcheck -x
```

**When to run:**
- Before committing any shell script changes
- When adding new .sh files
- Periodically as part of code review

**Key rules we follow:**

| Code | Rule | Why |
|------|------|-----|
| SC2155 | Declare and assign separately | Separates variable declaration from command substitution to prevent masking exit codes |
| SC2004 | Remove $() from arithmetic | Arithmetic expansion doesn't need command substitution syntax |
| SC2059 | Don't use variables in printf format string | Format strings should be literal; use arguments for data |
| SC2064 | Use single quotes in trap | Prevents variable expansion when trap is SET (should expand only when triggered) |
| SC2034 | Remove unused variables | Reduces noise and makes intent clearer |
| SC2038 | Use find with -print0 / xargs -0 | Handles filenames with spaces and special characters safely |
| SC2259 | Avoid redirecting piped output | Redirects in pipes override earlier redirections unexpectedly |
| SC2015 | Avoid A && B \|\| C patterns | Can silently fail if B exits with error; use if/then instead |

**Examples of fixed patterns:**

```bash
# SC2155: Declare and assign separately
# [FAIL] WRONG
local_var=$(command) && echo "ok"

# [OK] CORRECT
local_var=$(command)
echo "ok"

# SC2004: Remove $() from arithmetic
# [FAIL] WRONG
result=$(($(echo "5") + 3))

# [OK] CORRECT
result=$((5 + 3))

# SC2059: Use literal format string
# [FAIL] WRONG
printf "$message_template" "$arg"

# [OK] CORRECT
printf '%s\n' "$message_template"
# or with literal format:
printf 'Value: %s\n' "$arg"

# SC2064: Single quotes in trap
# [FAIL] WRONG
trap "cleanup $temp_file" EXIT

# [OK] CORRECT
trap 'cleanup "$temp_file"' EXIT
# Explanation: Single quotes prevent $temp_file expansion at trap SET time,
# allowing it to expand at trap TRIGGER time with the actual value
```

See [references.md](references.md) for ShellCheck links.
