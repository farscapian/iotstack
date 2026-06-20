#!/bin/bash
# iotstack-version.sh -- compile YAML helpers and YAML content hashing

[[ -n "${_IOTSTACK_VERSION_LOADED:-}" ]] && return 0
_IOTSTACK_VERSION_LOADED=1

iotstack_compilation_cache_yaml_name() {
  # Stable compilation-cache.csv key for a YAML path.
  # Production roles compile via yamls/.temp-compile-<role>.yaml.<pid>; cache rows
  # use the pid-less compile artifact name. Bootstrap uses .iotstack-bootstrap-* rows.
  local yaml_file="$1"
  local base

  [[ -n "$yaml_file" ]] || return 1
  base=$(basename "$yaml_file")

  if [[ "$base" =~ ^\.temp-compile-(\.iotstack-.+\.yaml)(\.[0-9]+)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$base" =~ ^(\.temp-compile-.+\.yaml)\.[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$base" =~ ^\.iotstack- ]] || [[ "$base" =~ ^\.temp-compile- ]]; then
    echo "$base"
    return 0
  fi
  echo ".temp-compile-${base}"
}

iotstack_prepare_compile_yaml() {
  # Copy source YAML to a temp compile artifact (so rendered .iotstack-* files stay untouched).
  # Prints YAML path to compile.
  local src_yaml="$1"
  local base compile_yaml

  [[ -f "$src_yaml" ]] || return 1
  base=$(basename "$src_yaml")

  # Must live under yamls/ (same dir as source) so !include common/... resolves.
  compile_yaml="$(cd "$(dirname "$src_yaml")" && pwd)/.temp-compile-${base}.$$"
  cp "$src_yaml" "$compile_yaml"
  printf '%s\n' "$compile_yaml"
}

iotstack_cleanup_compile_yaml() {
  local compile_yaml="$1"
  local src_yaml="$2"
  [[ -n "$compile_yaml" && "$compile_yaml" != "$src_yaml" ]] && rm -f "$compile_yaml"
}

iotstack_yaml_cache_sha() {
  # SHA256 of the source YAML file (update_devices.sh per-device build cache key).
  local yaml_file="$1"
  [[ -f "$yaml_file" ]] || return 1
  sha256sum "$yaml_file" | awk '{print $1}'
}