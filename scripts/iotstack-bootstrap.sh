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

iotstack_mdns_retry() {
  # Retry an mDNS discovery attempt until it succeeds or a budget is spent.
  #
  # A single avahi-browse -t snapshot only shows what the avahi-daemon has
  # already cached; it does not wait for a device's mDNS announcement to
  # arrive. That races freshly booted devices, ones that just reconnected to
  # WiFi, or a just-restarted avahi-daemon. Both iotstack.sh (production
  # update, by role) and update_devices.sh (--reassign, by MAC) hit this same
  # race, so the retry loop lives here once instead of twice.
  #
  # Usage: iotstack_mdns_retry <label> <logger_fn> <discover_fn> [args...]
  #   <label>       Noun phrase for the retry log line, e.g. "'bleproxy' device(s)"
  #   <logger_fn>   Name of a function to call with the retry message (info/log/etc)
  #   <discover_fn> Name of a function to call each attempt; it should populate
  #                 whatever result variable the caller cares about (a plain
  #                 global, or a local in the caller's stack frame -- bash
  #                 resolves unshadowed variable names dynamically) and return
  #                 0 once it found something, 1 otherwise.
  #   [args...]     Extra arguments forwarded to <discover_fn> verbatim.
  #
  # Retries up to 10 times, 3s apart (~30s total), matching the budget
  # confirmed necessary for --reassign in cab8088/75f66d1.
  #
  # Every <discover_fn> shells out to avahi-browse, which redirects its
  # stderr and ignores its exit code -- so on a host missing avahi-utils
  # (avahi-daemon does not pull it in), a "command not found" (exit 127)
  # is indistinguishable from a genuinely empty, not-yet-populated cache and
  # would otherwise burn the full retry budget before failing with a
  # misleading "no devices found". Fail fast with the real cause instead.
  command -v avahi-browse &>/dev/null \
    || { err "avahi-browse not found. Install it: sudo apt install avahi-utils"; exit 1; }
  local label="$1" logger_fn="$2" discover_fn="$3"
  shift 3
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    "$discover_fn" "$@" && return 0
    if (( attempt < 10 )); then
      "$logger_fn" "No ${label} in avahi cache yet (attempt ${attempt}/10); retrying..."
      sleep 3
    fi
  done
  return 1
}

iotstack_bootstrap_pass_ota_path() {
  local role
  role=$(iotstack_bootstrap_role)
  iotstack_pass_role_path "$role" ota_password
}

iotstack_bootstrap_pass_ota_legacy_role_path() {
  # Unscoped role path, from before pass paths gained an environment prefix.
  local role
  role=$(iotstack_bootstrap_role)
  iotstack_pass_role_legacy_path "$role" ota_password
}

iotstack_bootstrap_pass_ota_legacy_path() {
  # Oldest path: predates both env-scoping and the bootstrap role rename.
  printf '%s\n' "iotstack/roles/failsafe/ota_password"
}

iotstack_bootstrap_pass_ota_read() {
  # Read bootstrap role OTA base secret from pass, trying (newest to oldest):
  # env-scoped role path -> unscoped role path -> unscoped failsafe path.
  # Auto-migrates forward to the env-scoped path on a successful fallback read.
  local path secret legacy
  path=$(iotstack_bootstrap_pass_ota_path)
  secret=$(pass show "$path" 2>/dev/null) || true
  [[ -n "$secret" ]] && { printf '%s' "$secret"; return 0; }

  legacy=$(iotstack_bootstrap_pass_ota_legacy_role_path)
  secret=$(pass show "$legacy" 2>/dev/null) || true
  if [[ -z "$secret" ]]; then
    legacy=$(iotstack_bootstrap_pass_ota_legacy_path)
    secret=$(pass show "$legacy" 2>/dev/null) || true
    [[ -z "$secret" ]] && return 1
  fi

  { echo "$secret"; echo "$secret"; } | pass insert -f "$path" >/dev/null 2>&1 \
    || return 1
  pass rm "$legacy" >/dev/null 2>&1 || true
  echo "[INFO] Migrated bootstrap OTA password: $legacy -> $path" >&2
  printf '%s' "$secret"
  return 0
}

iotstack_bootstrap_pass_api_path() {
  # Role master secret from which per-device bootstrap API PSKs are derived.
  local role
  role=$(iotstack_bootstrap_role)
  iotstack_pass_role_path "$role" api_encryption_key
}

iotstack_bootstrap_pass_api_legacy_path() {
  local role
  role=$(iotstack_bootstrap_role)
  iotstack_pass_role_legacy_path "$role" api_encryption_key
}

iotstack_bootstrap_pass_api_read() {
  # Read bootstrap role API master secret from pass, auto-migrating a legacy
  # unscoped entry forward to the env-scoped path on first successful read.
  local path secret legacy
  path=$(iotstack_bootstrap_pass_api_path)
  secret=$(pass show "$path" 2>/dev/null) || true
  [[ -n "$secret" ]] && { printf '%s' "$secret"; return 0; }

  legacy=$(iotstack_bootstrap_pass_api_legacy_path)
  secret=$(pass show "$legacy" 2>/dev/null) || true
  [[ -z "$secret" ]] && return 1

  { echo "$secret"; echo "$secret"; } | pass insert -f "$path" >/dev/null 2>&1 \
    || return 1
  pass rm "$legacy" >/dev/null 2>&1 || true
  echo "[INFO] Migrated bootstrap API key: $legacy -> $path" >&2
  printf '%s' "$secret"
  return 0
}

iotstack_bootstrap_device_api_key() {
  # Per-device bootstrap API noise PSK (64 hex): sha256(role_master | mac).
  # Mirrors _derive_device_api_encryption_key for production. Returns non-zero
  # (no output) when the role master secret is absent from pass -- callers must
  # NOT fall back to a plaintext bootstrap connection.
  local mac="$1" base
  base=$(iotstack_bootstrap_pass_api_read 2>/dev/null) || return 1
  [[ -z "$base" ]] && return 1
  printf '%s' "$(echo -n "${base}|${mac}" | sha256sum | cut -c1-64)"
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