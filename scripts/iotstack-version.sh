#!/bin/bash
# iotstack-version.sh -- compile YAML helpers and YAML content hashing

[[ -n "${_IOTSTACK_VERSION_LOADED:-}" ]] && return 0
_IOTSTACK_VERSION_LOADED=1

iotstack_git_root() {
  local root="${PROJECT_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  printf '%s\n' "$root"
}

iotstack_git_commit_short() {
  # Short git commit at NVS provision / flash time (not baked into firmware config_hash).
  if [[ -n "${IOTSTACK_GIT_COMMIT:-}" ]]; then
    echo "$IOTSTACK_GIT_COMMIT"
    return 0
  fi
  local root commit
  root=$(iotstack_git_root)
  commit=$(git -C "$root" rev-parse --short=7 HEAD 2>/dev/null) || true
  [[ -n "$commit" ]] || commit="unknown"
  echo "$commit"
}

iotstack_git_tag() {
  # Latest git tag; falls back to "untagged" if no tags exist.
  local root tag
  root=$(iotstack_git_root)
  tag=$(git -C "$root" describe --tags --abbrev=0 2>/dev/null) || true
  [[ -n "$tag" ]] || tag="untagged"
  echo "$tag"
}

iotstack_compilation_cache_yaml_name() {
  # Stable compile-skip dedup key for a YAML path.
  # Production roles compile via yamls/.temp-compile-<role>.yaml.<pid>; dedup uses
  # the pid-less compile artifact name. Bootstrap uses .iotstack-bootstrap-* keys.
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

iotstack_source_fingerprint() {
  # Short hash of the local build inputs that ESPHome's config_hash does NOT see
  # on its own: external_components/ (C++) and common/ (!include) source files.
  # ESPHome's config_hash is a hash of the resolved YAML config only, so a change
  # to a component .cpp or a shared include would not change it. Folding this
  # fingerprint into project_version (see iotstack_prepare_compile_yaml) makes such
  # a change flow into config_hash -> a rebuild + device-hash mismatch. Empty when
  # neither dir exists (nothing to fold in).
  local yamls_dir
  yamls_dir="${YAMLS_DIR:-$(iotstack_git_root)/yamls}"
  find "${yamls_dir}/external_components" "${yamls_dir}/common" -type f \
    \( -name '*.h' -o -name '*.hpp' -o -name '*.cpp' -o -name '*.c' -o -name '*.cc' \
       -o -name '*.yaml' -o -name '*.yml' -o -name '*.py' -o -name '*.json' \) \
    -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 sha256sum 2>/dev/null \
    | sha256sum | awk '{print substr($1,1,8)}'
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

  # Inject "<git-tag>.<source-fingerprint>" into project_version on the temp copy
  # only (source YAML stays unchanged -- no dirty git state), e.g. v0.1.0.ab3523f1.
  # The tag lands in the firmware's reported version; the fingerprint (a fourth
  # dotted identifier) makes config_hash react to external_components/ + common/
  # source edits that the tag alone would miss.
  local git_tag src_fp version
  git_tag=$(iotstack_git_tag)
  src_fp=$(iotstack_source_fingerprint)
  version="$git_tag"
  [[ -n "$src_fp" ]] && version="${git_tag}.${src_fp}"
  sed -i "s/project_version: \"[^\"]*\"/project_version: \"${version}\"/" "$compile_yaml"

  printf '%s\n' "$compile_yaml"
}

iotstack_cleanup_compile_yaml() {
  local compile_yaml="$1"
  local src_yaml="$2"
  [[ -n "$compile_yaml" && "$compile_yaml" != "$src_yaml" ]] && rm -f "$compile_yaml"
}

# -- Compile skip (config_hash) -- shared by iotstack.sh and update_devices.sh --
# ESPHome's config_hash is the single build-identity key: it reflects the resolved
# YAML config plus the project_version source fingerprint (see above), so it moves
# on any YAML, package, common/, external_components/, git-tag, or component-source
# change. Compilation is skipped only when the current config_hash matches the
# built one -- there is no separate yaml-hash key.

_esphome_config_hash_hex() {
  # Parse "0xabcdef12" from esphome config-hash stdout to 8-char lowercase hex.
  local raw="${1,,}"
  raw="${raw#0x}"
  [[ "$raw" =~ ^[0-9a-f]{8}$ ]] || return 1
  echo "$raw"
}

_esphome_config_hash_for_compile_yaml() {
  # ESPHome config_hash for a prepared compile YAML.
  local compile_yaml="$1"
  local hash_raw
  [[ -f "$compile_yaml" ]] || return 1
  hash_raw=$("${ESPHOME_BIN:-esphome}" -q config-hash "$compile_yaml" 2>/dev/null | tail -1) || return 1
  _esphome_config_hash_hex "$hash_raw"
}

_current_config_hash_for_yaml() {
  # Current ESPHome config_hash for a source YAML (packages, external_components,
  # common/, and the project_version fingerprint all fold in via the compile YAML).
  local yaml_file="$1"
  local device_name="${2:-}"
  local compile_yaml hash firmware_bin
  [[ -f "$yaml_file" ]] || return 1

  # Bootstrap builds sync their partition table before hashing. Guarded so this
  # works when sourced without iotstack.sh's bootstrap helpers (update_devices.sh).
  if [[ -n "$device_name" ]] && declare -F _is_bootstrap_yaml &>/dev/null \
      && _is_bootstrap_yaml "$yaml_file"; then
    firmware_bin="${YAMLS_DIR}/.esphome/build/${device_name}/.pioenvs/${device_name}/firmware.bin"
    if [[ -f "$firmware_bin" ]] && declare -F _sync_bootstrap_partition_table_from_build &>/dev/null; then
      # Side-effect only; must not write to stdout (hash capture uses command substitution).
      _sync_bootstrap_partition_table_from_build >/dev/null
    fi
  fi

  compile_yaml=$(iotstack_prepare_compile_yaml "$yaml_file") || return 1
  hash=$(_esphome_config_hash_for_compile_yaml "$compile_yaml") || hash=""
  iotstack_cleanup_compile_yaml "$compile_yaml" "$yaml_file"
  [[ -n "$hash" ]] && echo "$hash"
}

_config_hash_from_build_dir() {
  # 8-char hex config_hash from ESPHome build_info.json.
  local build_name="$1"
  local build_info="${YAMLS_DIR}/.esphome/build/${build_name}/build_info.json"
  [[ -f "$build_info" ]] || return 1
  python3 -c "import json,sys; print(format(json.load(open(sys.argv[1]))['config_hash'], '08x'))" "$build_info"
}

_compile_skip_device_name() {
  local yaml_file="$1"
  local device_name="${2:-}"
  local resolved
  if declare -F _is_bootstrap_yaml &>/dev/null && _is_bootstrap_yaml "$yaml_file"; then
    resolved="${device_name:-$(iotstack_bootstrap_role)}"
  else
    resolved="${device_name:-$(basename "$yaml_file" .yaml)}"
    [[ "$resolved" =~ ^\.temp-compile- ]] && resolved="${resolved#.temp-compile-}"
  fi
  echo "$resolved"
}

_build_matches_config_hash() {
  # Returns 0 when an existing build matches the current esphome config-hash.
  local yaml_file="$1"
  local device_name="${2:-}"
  local resolved_device current_hash built_hash firmware_bin
  resolved_device=$(_compile_skip_device_name "$yaml_file" "$device_name")
  firmware_bin="${YAMLS_DIR}/.esphome/build/${resolved_device}/.pioenvs/${resolved_device}/firmware.bin"
  [[ -f "$firmware_bin" ]] || return 1
  current_hash=$(_current_config_hash_for_yaml "$yaml_file" "$resolved_device") || return 1
  built_hash=$(_config_hash_from_build_dir "$resolved_device" 2>/dev/null) || return 1
  [[ -n "$current_hash" && -n "$built_hash" && "$current_hash" == "$built_hash" ]]
}