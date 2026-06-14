#!/bin/bash
# config.sh — Centralized configuration for iotstack scripts
# Source this file in all scripts to get consistent paths and filenames

# Base directories
export IOTSTACK_HOME="${HOME}/.iotstack"
export SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export YAMLS_DIR="${SCRIPT_DIR}/yamls"

# Filenames and paths
export ROLES_CONF="${SCRIPT_DIR}/roles.conf"
export COMPILATION_CACHE="${IOTSTACK_HOME}/compilation-cache.csv"
export PARTITION_TABLE_CSV="iotstack_partition_table.csv"
export PARTITION_TABLE="${IOTSTACK_HOME}/${PARTITION_TABLE_CSV}"
export PARTITION_TABLE_SYMLINK="${YAMLS_DIR}/${PARTITION_TABLE_CSV}"

# Directories
export LOGS_DIR="${IOTSTACK_HOME}/logs"
export ARTIFACTS_DIR="${IOTSTACK_HOME}/artifacts"
export PASS_STORE_DIR="${IOTSTACK_HOME}/.pass"

# Environment file for user configuration
export ENV_FILE="${IOTSTACK_HOME}/.env"

# Ensure directories exist
mkdir -p "$IOTSTACK_HOME" "$LOGS_DIR" "$ARTIFACTS_DIR" "$PASS_STORE_DIR" 2>/dev/null || true
