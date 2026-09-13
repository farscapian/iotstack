#!/bin/bash
# flash-lock.sh -- Serialize concurrent 'iotstack flash' invocations
#
# Each chip variant's bootstrap build now lives in its own persistent dir
# (esphome.build_path in yamls/bootstrap.yaml, keyed by chip_variant) instead
# of one shared dir swapped in/out by rename, so two concurrent flashes for
# different variants no longer race over the build tree itself.
#
# What remains shared: ~/.iotstack/artifacts/iotstack_partition_table.csv
# (PARTITION_TABLE) is a single global file, re-synced from whichever
# variant's bootstrap compile finishes most recently
# (_sync_bootstrap_partition_table_from_build in iotstack.sh), and every
# flash step that resolves an NVS/bootstrap/production offset
# (write-nvs-secrets.sh, verify-flash.sh, flash_partition_offset in
# flash-compare.sh) reads it. Bootstrap firmware size -- and so partition
# offsets -- can differ across variants (esp-idf vs arduino framework,
# different flash sizes), so two concurrent flashes of different variants
# could overwrite this shared file mid-flight and hand a later step in the
# other invocation an offset that does not match what is actually on that
# device -- silent NVS corruption, not just a wrong-chip esptool error.
#
# Every 'iotstack flash' invocation holds one exclusive flock for its full
# compile+serial+OTA lifetime, so only one is ever reading/writing that
# shared partition-table file at a time. This matches the existing rule that
# multiple serial ttys within a single invocation are flashed one at a time,
# never in parallel -- see docs/help/iotstack-flash.txt.

[[ -n "${_IOTSTACK_FLASH_LOCK_LOADED:-}" ]] && return 0
_IOTSTACK_FLASH_LOCK_LOADED=1

IOTSTACK_FLASH_LOCK_FILE="${IOTSTACK_HOME}/flash.lock"
IOTSTACK_FLASH_LOCK_INFO_FILE="${IOTSTACK_HOME}/flash.lock.info"

_flash_lock_release() {
  [[ -n "${_IOTSTACK_FLASH_LOCK_FD:-}" ]] || return 0
  rm -f "$IOTSTACK_FLASH_LOCK_INFO_FILE" 2>/dev/null || true
  flock -u "$_IOTSTACK_FLASH_LOCK_FD" 2>/dev/null || true
  exec {_IOTSTACK_FLASH_LOCK_FD}>&- 2>/dev/null || true
  _IOTSTACK_FLASH_LOCK_FD=""
}

# Acquire the whole-machine flash lock, blocking (with one status line) if
# another 'iotstack flash' is already holding it. Usage:
#   flash_lock_acquire <label>   # label e.g. "matrixdisplay" or "bootstrap"
flash_lock_acquire() {
  local label="${1:-flash}"
  mkdir -p "$IOTSTACK_HOME"

  exec {_IOTSTACK_FLASH_LOCK_FD}>"$IOTSTACK_FLASH_LOCK_FILE"
  export _IOTSTACK_FLASH_LOCK_FD

  if ! flock -n "$_IOTSTACK_FLASH_LOCK_FD"; then
    local holder=""
    holder=$(cat "$IOTSTACK_FLASH_LOCK_INFO_FILE" 2>/dev/null || true)
    if [[ -n "$holder" ]]; then
      info "Waiting for another iotstack flash to finish (${holder}) -- the partition table is shared and can only be updated by one flash at a time"
    else
      info "Waiting for another iotstack flash to finish -- the partition table is shared and can only be updated by one flash at a time"
    fi
    flock "$_IOTSTACK_FLASH_LOCK_FD"
  fi

  printf '%s, pid %s, started %s\n' "$label" "$$" "$(date '+%H:%M:%S')" > "$IOTSTACK_FLASH_LOCK_INFO_FILE"

  # Chain onto any existing EXIT trap (same pattern as create-log.sh / bootstrap-yaml.sh).
  local prior_cmd=""
  if trap -p EXIT 2>/dev/null | grep -q .; then
    prior_cmd=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")
  fi
  if [[ -n "$prior_cmd" ]]; then
    # shellcheck disable=SC2064
    trap "_flash_lock_release; eval \"\$_FLASH_LOCK_PRIOR_EXIT\"" EXIT
    export _FLASH_LOCK_PRIOR_EXIT="$prior_cmd"
  else
    trap '_flash_lock_release' EXIT
  fi
}
