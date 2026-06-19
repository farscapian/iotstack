#!/bin/bash
# iotstack-bootstrap.sh -- Bootstrap role helpers for iotstack scripts
#
# Centralizes bootstrap role naming: hostnames, mDNS, pass paths, YAML artifacts.
# Override the role with IOTSTACK_BOOTSTRAP_ROLE (default: bootstrap).

[[ -n "${_IOTSTACK_BOOTSTRAP_LOADED:-}" ]] && return 0
_IOTSTACK_BOOTSTRAP_LOADED=1

export IOTSTACK_BOOTSTRAP_ROLE="${IOTSTACK_BOOTSTRAP_ROLE:-bootstrap}"

iotstack_bootstrap_role() {
  printf '%s\n' "${IOTSTACK_BOOTSTRAP_ROLE}"
}

iotstack_bootstrap_hostname() {
  local mac="$1"
  printf '%s-%s\n' "$(iotstack_bootstrap_role)" "$mac"
}

iotstack_bootstrap_mdns_service() {
  local role
  role=$(iotstack_bootstrap_role)
  printf '_iotstack-%s._tcp\n' "$role"
}

iotstack_bootstrap_mdns_service_base() {
  local role
  role=$(iotstack_bootstrap_role)
  printf '_iotstack-%s\n' "$role"
}

iotstack_meta_mdns_service() {
  printf '_iotstack-meta._tcp\n'
}

iotstack_bootstrap_pass_ota_path() {
  local role
  role=$(iotstack_bootstrap_role)
  printf 'iotstack/roles/%s/ota_password\n' "$role"
}

iotstack_bootstrap_pass_ota_legacy_path() {
  printf '%s\n' "iotstack/roles/failsafe/ota_password"
}

iotstack_bootstrap_pass_ota_read() {
  # Read bootstrap role OTA base secret from pass. Auto-migrates legacy failsafe path.
  local path secret legacy
  path=$(iotstack_bootstrap_pass_ota_path)
  secret=$(pass show "$path" 2>/dev/null) || true
  [[ -n "$secret" ]] && { printf '%s' "$secret"; return 0; }

  legacy=$(iotstack_bootstrap_pass_ota_legacy_path)
  secret=$(pass show "$legacy" 2>/dev/null) || true
  [[ -z "$secret" ]] && return 1

  { echo "$secret"; echo "$secret"; } | pass insert -f "$path" >/dev/null 2>&1 \
    || return 1
  pass rm "$legacy" >/dev/null 2>&1 || true
  echo "[INFO] Migrated bootstrap OTA password: $legacy -> $path" >&2
  printf '%s' "$secret"
  return 0
}

iotstack_bootstrap_friendly_name() {
  local role first
  role=$(iotstack_bootstrap_role)
  first=$(printf '%s' "$role" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
  printf '%s Mode\n' "$first"
}

iotstack_bootstrap_template_path() {
  local yamls_dir="${YAMLS_DIR:-}"
  if [[ -z "$yamls_dir" ]]; then
    local root="${PROJECT_ROOT:-}"
    if [[ -z "$root" ]]; then
      root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    fi
    yamls_dir="${root}/yamls"
  fi
  printf '%s/bootstrap.yaml\n' "$yamls_dir"
}

iotstack_bootstrap_artifact_name() {
  local variant="$1" role
  role=$(iotstack_bootstrap_role)
  printf '.iotstack-%s-%s.yaml\n' "$role" "$variant"
}