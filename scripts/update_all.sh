#!/usr/bin/env bash
# update_all.sh
# Runs update_devices.sh for every ESPHome device config found in this
# directory. Any flags passed to this script are forwarded to each run.
#
# Usage:
#   ./update_all.sh [options] [update_devices.sh options]
#
# Options:
#   --wifi    Update only WiFi devices (wifi/ directory)
#   --thread  Update only Thread devices (thread/ directory)
#
# Examples:
#   ./update_all.sh                    # update all device types
#   ./update_all.sh --wifi             # update only WiFi devices
#   ./update_all.sh --thread --dry-run # preview Thread flashes
#   ./update_all.sh --flash-anyway # force-flash everything

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPDATE_SCRIPT="${SCRIPT_DIR}/update_devices.sh"
FILTER_DIR=""  # Optional: "wifi" or "thread"

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLU='\033[0;34m'
DIM='\033[2m'
RST='\033[0m'

log()  { echo -e "${BLU}[INFO]${RST}  $*"; }
ok()   { echo -e "${GRN}[OK]${RST}    $*"; }
warn() { echo -e "${YLW}[WARN]${RST}  $*"; }
err()  { echo -e "${RED}[ERR]${RST}   $*" >&2; }

# ── Parse update_all.sh-specific options ─────────────────────────────────────
FORWARDED_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wifi)   FILTER_DIR="wifi"; shift ;;
    --thread) FILTER_DIR="thread"; shift ;;
    *)        FORWARDED_ARGS+=("$1"); shift ;;
  esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [[ ! -x "$UPDATE_SCRIPT" ]]; then
  err "update_devices.sh not found or not executable at: ${UPDATE_SCRIPT}"
  exit 1
fi

# ── Discover device configs ──────────────────────────────────────────────────
# Any yaml with a top-level 'esphome:' key is a device config.
# Searches the project root and subdirectories (e.g., wifi/, thread/).
# If --wifi or --thread is specified, only configs in that directory are found.
YAMLS=()
if [[ -n "$FILTER_DIR" ]]; then
  # Filter to specific directory
  while IFS= read -r f; do
    YAMLS+=("$f")
  done < <(find "$SCRIPT_DIR/$FILTER_DIR" -maxdepth 1 -name "*.yaml" -type f -print0 | xargs -0 grep -l "^esphome:" 2>/dev/null | sort)
else
  # All configs in project
  while IFS= read -r f; do
    YAMLS+=("$f")
  done < <(find "$SCRIPT_DIR" -maxdepth 2 -name "*.yaml" -type f -print0 | xargs -0 grep -l "^esphome:" 2>/dev/null | sort)
fi

if [[ ${#YAMLS[@]} -eq 0 ]]; then
  warn "No device configs found in ${SCRIPT_DIR}"
  exit 0
fi

log "Found ${#YAMLS[@]} device config(s)"
[[ -n "$FILTER_DIR" ]] && log "Filter: --$FILTER_DIR"
for y in "${YAMLS[@]}"; do
  echo -e "  ${DIM}$(basename "$y")${RST}"
done
echo

# ── Run update_devices.sh for each config ────────────────────────────────────
PASS=()
FAIL=()

for YAML in "${YAMLS[@]}"; do
  name=$(basename "$YAML")
  echo -e "${DIM}════════════════════════════════════════════════════════${RST}"
  log "Starting: ${name}"
  echo -e "${DIM}════════════════════════════════════════════════════════${RST}"
  echo

  if "$UPDATE_SCRIPT" "${FORWARDED_ARGS[@]}" "$YAML"; then
    PASS+=("$name")
  else
    FAIL+=("$name")
  fi
  echo
done

# ── Final summary ────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════"
echo " UPDATE ALL — COMPLETE"
echo "────────────────────────────────────────────────────────"
for y in "${PASS[@]}"; do
  ok "$y"
done
for y in "${FAIL[@]}"; do
  echo -e "${RED}[FAIL]${RST}  $y" >&2
done
echo "════════════════════════════════════════════════════════"

if [[ ${#FAIL[@]} -gt 0 ]]; then
  exit 1
fi
