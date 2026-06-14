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

# Base directories — allow user override via environment variable
export IOTSTACK_HOME="${IOTSTACK_HOME:-${HOME}/.iotstack}"
export SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export YAMLS_DIR="${YAMLS_DIR:-${SCRIPT_DIR}/yamls}"

# Environment file for user configuration
export ENV_FILE="${ENV_FILE:-${IOTSTACK_HOME}/.env}"

# Load user overrides from .env file if it exists
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

# Filenames and paths — allow user override
export ROLES_CONF="${ROLES_CONF:-${SCRIPT_DIR}/roles.conf}"
export COMPILATION_CACHE="${COMPILATION_CACHE:-${IOTSTACK_HOME}/compilation-cache.csv}"
export PARTITION_TABLE_CSV="${PARTITION_TABLE_CSV:-iotstack_partition_table.csv}"
export PARTITION_TABLE="${PARTITION_TABLE:-${IOTSTACK_HOME}/${PARTITION_TABLE_CSV}}"
export PARTITION_TABLE_SYMLINK="${PARTITION_TABLE_SYMLINK:-${YAMLS_DIR}/${PARTITION_TABLE_CSV}}"

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
