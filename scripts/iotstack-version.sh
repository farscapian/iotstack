#!/bin/bash
# iotstack-version.sh — project_version substitution from git tags at compile time

[[ -n "${_IOTSTACK_VERSION_LOADED:-}" ]] && return 0
_IOTSTACK_VERSION_LOADED=1

iotstack_project_version() {
  # Override for tests or unreleased builds: export IOTSTACK_PROJECT_VERSION=...
  if [[ -n "${IOTSTACK_PROJECT_VERSION:-}" ]]; then
    echo "$IOTSTACK_PROJECT_VERSION"
    return 0
  fi

  local tag root="${PROJECT_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi

  tag=$(git -C "$root" describe --tags --abbrev=0 2>/dev/null) || true
  if [[ -n "$tag" ]]; then
    echo "$tag"
    return 0
  fi

  echo "0.0.0-dev"
}

_iotstack_set_project_version_in_yaml() {
  local yaml_file="$1"
  local version="$2"

  python3 - "$yaml_file" "$version" <<'PY'
import re
import sys

path, version = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    content = f.read()

line = f'  project_version: "{version}"'
if re.search(r"^\s*project_version:", content, re.MULTILINE):
    content = re.sub(
        r"^\s*project_version:.*",
        line,
        content,
        count=1,
        flags=re.MULTILINE,
    )
else:
    content = re.sub(
        r"^(substitutions:\s*\n)",
        r"\1" + line + "\n",
        content,
        count=1,
        flags=re.MULTILINE,
    )

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
PY
}

iotstack_prepare_compile_yaml() {
  # Inject the current git tag into project_version. Prints the YAML path to compile.
  local src_yaml="$1"
  local base compile_yaml

  [[ -f "$src_yaml" ]] || return 1
  base=$(basename "$src_yaml")

  if [[ "$base" =~ ^\.iotstack-failsafe- ]]; then
    _iotstack_set_project_version_in_yaml "$src_yaml" "$(iotstack_project_version)"
    printf '%s\n' "$src_yaml"
    return 0
  fi

  compile_yaml="${TMPDIR:-/tmp}/iotstack-compile-${base}.$$"
  cp "$src_yaml" "$compile_yaml"
  _iotstack_set_project_version_in_yaml "$compile_yaml" "$(iotstack_project_version)"
  printf '%s\n' "$compile_yaml"
}

iotstack_cleanup_compile_yaml() {
  local compile_yaml="$1"
  local src_yaml="$2"
  [[ -n "$compile_yaml" && "$compile_yaml" != "$src_yaml" ]] && rm -f "$compile_yaml"
}

iotstack_yaml_cache_sha() {
  # Cache key for a source YAML: file content + current project_version (git tag).
  local yaml_file="$1"
  local file_sha version
  [[ -f "$yaml_file" ]] || return 1
  file_sha=$(sha256sum "$yaml_file" | awk '{print $1}')
  version=$(iotstack_project_version)
  echo -n "${file_sha}${version}" | sha256sum | awk '{print $1}'
}