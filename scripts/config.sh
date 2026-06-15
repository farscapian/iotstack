#!/bin/bash
# config.sh — Centralized configuration for iotstack scripts
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

# Base directories — allow user override via environment variable
export IOTSTACK_HOME="${IOTSTACK_HOME:-${HOME}/.iotstack}"
export YAMLS_DIR="${YAMLS_DIR:-${PROJECT_ROOT}/yamls}"

# Environment file for user configuration
export ENV_FILE="${ENV_FILE:-${IOTSTACK_HOME}/.env}"

# Load user overrides from .env file if it exists
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Filenames and paths — allow user override
export ROLES_CONF="${ROLES_CONF:-${SCRIPTS_DIR}/roles.conf}"
export UPDATE_SCRIPT="${UPDATE_SCRIPT:-${SCRIPTS_DIR}/update_devices.sh}"
export COMPILATION_CACHE="${COMPILATION_CACHE:-${IOTSTACK_HOME}/compilation-cache.csv}"
export PARTITION_TABLE_CSV="${PARTITION_TABLE_CSV:-iotstack_partition_table.csv}"
export PARTITION_TABLE="${PARTITION_TABLE:-${IOTSTACK_HOME}/${PARTITION_TABLE_CSV}}"
export PARTITION_TABLE_SYMLINK="${PARTITION_TABLE_SYMLINK:-${YAMLS_DIR}/${PARTITION_TABLE_CSV}}"

# Partition layout (2-partition scheme: permanent failsafe ota_0 + production
# ota_1). All OTA updates run from failsafe, so production (ota_1) is always the
# OTA target and failsafe is never overwritten. Production absorbs all flash
# left after the (fixed-size) failsafe partition — so these adapt to the board:
# on 4MB flash production is ~2.8MB; on 8MB it is ~6.8MB.
export IOTSTACK_FLASH_SIZE="${IOTSTACK_FLASH_SIZE:-0x400000}"        # total flash (4MB default)
export IOTSTACK_APP_OFFSET="${IOTSTACK_APP_OFFSET:-0x30000}"         # first app partition offset
export IOTSTACK_FAILSAFE_PART_SIZE="${IOTSTACK_FAILSAFE_PART_SIZE:-0x100000}"  # failsafe (ota_0) size (1MB)

# Directories — allow user override
export LOGS_DIR="${LOGS_DIR:-${IOTSTACK_HOME}/logs}"
export ARTIFACTS_DIR="${ARTIFACTS_DIR:-${IOTSTACK_HOME}/artifacts}"
export PASS_STORE_DIR="${PASS_STORE_DIR:-${IOTSTACK_HOME}/.pass}"
export GNUPG_HOME="${GNUPG_HOME:-${IOTSTACK_HOME}/.gnupg}"

# ESPHome build directories (for verification scripts)
export ESPHOME_BUILD_DIR="${ESPHOME_BUILD_DIR:-${YAMLS_DIR}/.esphome/build}"

# Build behavior flags — allow user override via environment variable or .env file
export CLEAN_BUILD_DIRECTORY="${CLEAN_BUILD_DIRECTORY:-0}"

# Ensure directories exist
mkdir -p "$IOTSTACK_HOME" "$LOGS_DIR" "$ARTIFACTS_DIR" "$PASS_STORE_DIR" 2>/dev/null || true
