#!/bin/bash
# config.sh -- Centralized configuration for iotstack scripts
# Source this file in all scripts to get consistent paths and filenames
#
# Users can override any variable by:
# 1. Setting environment variables before sourcing this file
# 2. Creating ~/.iotstack/.env with custom values
#
# Examples:
#   export IOTSTACK_HOME=/custom/path
#   export LOGS_DIR=/var/log/iotstack
#   iotstack update bleproxy

# Resolve project layout from THIS file's location. config.sh lives in
# scripts/, so the project root is its parent directory. Project-relative
# paths derive from PROJECT_ROOT (not the caller's SCRIPT_DIR) so they are
# correct no matter which script sources this file.
_CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPTS_DIR="${SCRIPTS_DIR:-$_CONFIG_DIR}"
export PROJECT_ROOT="${PROJECT_ROOT:-$(cd "${_CONFIG_DIR}/.." && pwd)}"
# SCRIPT_DIR retained for backward compatibility (== project root)
export SCRIPT_DIR="${SCRIPT_DIR:-$PROJECT_ROOT}"

# Base directories -- allow user override via environment variable
export IOTSTACK_HOME="${IOTSTACK_HOME:-${HOME}/.iotstack}"
export YAMLS_DIR="${YAMLS_DIR:-${PROJECT_ROOT}/yamls}"
export TESTS_DIR="${TESTS_DIR:-${PROJECT_ROOT}/tests}"

# Environment file for user configuration
export ENV_FILE="${ENV_FILE:-${IOTSTACK_HOME}/.env}"

# Load user overrides from .env file if it exists
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Filenames and paths -- allow user override
export ROLES_CONF="${ROLES_CONF:-${SCRIPTS_DIR}/roles.conf}"
export UPDATE_SCRIPT="${UPDATE_SCRIPT:-${SCRIPTS_DIR}/update_devices.sh}"
# Directories -- allow user override (ARTIFACTS_DIR before PARTITION_TABLE)
export LOGS_DIR="${LOGS_DIR:-${IOTSTACK_HOME}/logs}"
# Append-only registry of iotstack invocations (tail -f to detect new runs).
export IOTSTACK_SESSION_WATCH="${IOTSTACK_SESSION_WATCH:-${LOGS_DIR}/sessions.watch}"
export ARTIFACTS_DIR="${ARTIFACTS_DIR:-${IOTSTACK_HOME}/artifacts}"
export PASS_STORE_DIR="${PASS_STORE_DIR:-${IOTSTACK_HOME}/.pass}"
export GNUPG_HOME="${GNUPG_HOME:-${IOTSTACK_HOME}/.gnupg}"
# Point gpg and pass at iotstack's isolated stores so users need not export these
# in their shell rc. GNUPG_HOME/PASS_STORE_DIR above already honor .env overrides.
export GNUPGHOME="$GNUPG_HOME"
export PASSWORD_STORE_DIR="$PASS_STORE_DIR"

export PARTITION_TABLE_CSV="${PARTITION_TABLE_CSV:-iotstack_partition_table.csv}"
export PARTITION_TABLE="${PARTITION_TABLE:-${ARTIFACTS_DIR}/${PARTITION_TABLE_CSV}}"
export PARTITION_TABLE_SYMLINK="${PARTITION_TABLE_SYMLINK:-${YAMLS_DIR}/${PARTITION_TABLE_CSV}}"

# Partition layout (2-partition scheme: permanent bootstrap ota_0 + production
# ota_1). All OTA updates run from bootstrap, so production (ota_1) is always the
# OTA target and bootstrap is never overwritten. Production absorbs all flash
# left after the (fixed-size) bootstrap partition -- so these adapt to the board:
# on 4MB flash production is ~2.8MB; on 8MB it is ~6.8MB.
export IOTSTACK_FLASH_SIZE="${IOTSTACK_FLASH_SIZE:-0x400000}"        # total flash (4MB default)
export IOTSTACK_APP_OFFSET="${IOTSTACK_APP_OFFSET:-0x30000}"         # first app partition offset
# Bootstrap (ota_0) is sized dynamically to the compiled bootstrap firmware plus
# IOTSTACK_BOOTSTRAP_MARGIN (rounded up to 64KB); production (ota_1) gets the
# rest. IOTSTACK_BOOTSTRAP_PART_SIZE is the fallback/initial size used for the
# first compile pass and if the firmware can't be measured.
export IOTSTACK_BOOTSTRAP_PART_SIZE="${IOTSTACK_BOOTSTRAP_PART_SIZE:-0xe0000}"   # tuned for current bootstrap (~800KB + margin)
export IOTSTACK_BOOTSTRAP_PART_SIZE_GENEROUS="${IOTSTACK_BOOTSTRAP_PART_SIZE_GENEROUS:-0x180000}"  # pass-1 fallback if tight table fails
export IOTSTACK_BOOTSTRAP_MARGIN="${IOTSTACK_BOOTSTRAP_MARGIN:-0x10000}"         # headroom above firmware (64KB)

# Redirect ESPHome's own data dir (build cache, fonts, per-device storage
# json) through the existing yamls/.iotstack symlink instead of letting it
# default to yamls/.esphome -- keeps ESPHome's output under the centralized
# iotstack home without a second dedicated symlink. ESPHome reads this env
# var itself (see esphome.core.EsphomeCore.data_dir), so exporting it here is
# enough for every `esphome` invocation in this codebase to pick it up.
export ESPHOME_DATA_DIR="${ESPHOME_DATA_DIR:-${YAMLS_DIR}/.iotstack/.esphome}"
export ESPHOME_BUILD_DIR="${ESPHOME_BUILD_DIR:-${ESPHOME_DATA_DIR}/build}"

# setup.sh installs esphome into an isolated venv, not a symlinked binary, so
# `esphome` on PATH depends on the user's shell rc sourcing the venv. Fall back
# to the known venv location so iotstack.sh's bare `esphome` calls (compile,
# logs, matter commission) work even when the interactive shell's PATH doesn't
# already resolve it.
ESPHOME_VENV_BIN="${HOME}/.local/esphome/venv/bin"
if [[ -x "${ESPHOME_VENV_BIN}/esphome" ]] && ! command -v esphome &>/dev/null; then
  export PATH="${ESPHOME_VENV_BIN}:${PATH}"
fi

# Build behavior flags -- allow user override via environment variable or .env file
export CLEAN_BUILD_DIRECTORY="${CLEAN_BUILD_DIRECTORY:-0}"

# Auto-register production ESPHome devices in Home Assistant after flash/update.
# 0 (default): skip HA config-flow registration
# 1: complete ESPHome discovery via WebSocket + device api_encryption_key from pass
export PERFORM_HA_DEVICE_REGISTRATION="${PERFORM_HA_DEVICE_REGISTRATION:-0}"

# websocat buffer for Home Assistant WebSocket replies. A message larger than the
# buffer (default 65536) is emitted as several newline-separated chunks, which
# splits a JSON string mid-value and makes jq fail on the whole reply -- a device
# registry of a few hundred devices already exceeds 64KB.
export IOTSTACK_WEBSOCAT_BUFFER_BYTES="${IOTSTACK_WEBSOCAT_BUFFER_BYTES:-16777216}"

# Ensure directories exist
mkdir -p "$IOTSTACK_HOME" "$LOGS_DIR" "$ARTIFACTS_DIR" "$PASS_STORE_DIR" 2>/dev/null || true

# shellcheck source=scripts/iotstack-version.sh
source "${SCRIPTS_DIR}/iotstack-version.sh"

# shellcheck source=scripts/iotstack-bootstrap.sh
source "${SCRIPTS_DIR}/iotstack-bootstrap.sh"

# Stub partition table artifact + yamls/ symlink (generated tables live in artifacts/)
# shellcheck source=scripts/partition-table.sh
source "${SCRIPTS_DIR}/partition-table.sh"
ensure_partition_table_artifact
