#!/usr/bin/env bash
# update_devices.sh
# Discovers ESPHome devices via mDNS and OTA-flashes those whose firmware
# differs from the current build (compared by config_hash, not project.version).
#
# Usage:
#   ./update_devices.sh [options] <yaml-file>
#
# Options:
#   --upgrade-delta     Only flash devices whose config_hash differs from the
#                       current build (default: on)
#   --no-upgrade-delta  Flash all devices regardless of running firmware
#   --verify            Compile, then check each device's config_hash; report
#                       pass/fail and exit (no flashing)
#   --dry-run           Compile and show what would be flashed, without flashing
#   --jobs <n>          Maximum concurrent flash jobs (default: 4)
#   -v, --verbose       Show compilation output in terminal (default: silent)
#   --help              Show this help

set -euo pipefail

# ── Cleanup on exit ──────────────────────────────────────────────────────────
trap 'printf "\n" 2>/dev/null; exit' EXIT

# ── Defaults ────────────────────────────────────────────────────────────────
UPGRADE_DELTA=true
VERIFY=false
DRY_RUN=false
VERBOSE=false
MAX_JOBS=4
JOBS_EXPLICIT=false
YAML_FILE=""

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[0;33m'
BLU='\033[0;34m'
DIM='\033[2m'
RST='\033[0m'

log()  { :; }
ok()   { echo -e "${GRN}[OK]${RST}    $*"; }
warn() { echo -e "${YLW}[WARN]${RST}  $*"; }
err()  { echo -e "${RED}[ERR]${RST}   $*" >&2; }
dim()  { echo -e "${DIM}$*${RST}"; }

# ── Help ────────────────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ── Argument parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade-delta)    UPGRADE_DELTA=true;  shift ;;
    --no-upgrade-delta) UPGRADE_DELTA=false; shift ;;
    --verify)           VERIFY=true;         shift ;;
    --dry-run)          DRY_RUN=true;        shift ;;
    --jobs)             MAX_JOBS="$2"; JOBS_EXPLICIT=true; shift 2 ;;
    -v|--verbose)       VERBOSE=true;        shift ;;
    --help|-h)          usage ;;
    -*)                 err "Unknown option: $1"; exit 1 ;;
    *)                  YAML_FILE="$1";      shift ;;
  esac
done

# ── Validate inputs ─────────────────────────────────────────────────────────
if [[ -z "$YAML_FILE" ]]; then
  err "No yaml file specified."
  echo "Usage: $0 [--upgrade-delta] [--no-upgrade-delta] [--verify] [--dry-run] [--jobs N] <yaml-file>"
  exit 1
fi

if [[ ! -f "$YAML_FILE" ]]; then
  err "File not found: $YAML_FILE"
  exit 1
fi

if ! [[ "$MAX_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  err "--jobs must be a positive integer."
  exit 1
fi

# ── Disable parallelism for Thread devices ──────────────────────────────────
# Thread OTA is slow; parallelism causes contention on the mesh rather than
# speeding up flashing. Force --jobs 1 unless explicitly overridden by user.
if [[ "$YAML_FILE" == *"/thread/"* || "$YAML_FILE" == "thread-"* ]]; then
  if [[ "$JOBS_EXPLICIT" == false ]]; then
    MAX_JOBS=1
  fi
fi

# ── Logging ──────────────────────────────────────────────────────────────────
YAML_NAME="$(basename "${YAML_FILE%.yaml}")"
BASE_LOG_DIR="${HOME}/.ancapistan/esphome/logs"
LOG_ROOT="${BASE_LOG_DIR}/${YAML_NAME}"
RUN_TS="$(date '+%Y%m%d_%H%M%S')"
COMPILE_LOG_FILE="${LOG_ROOT}/${RUN_TS}.compile.log"
FLASH_LOG_DIR=""  # Set after compilation succeeds and hash is known
mkdir -p "$LOG_ROOT"

# Log compilation separately, don't tee to stdout (using spinner)
exec > >(tee -a "$COMPILE_LOG_FILE") 2>&1
echo "── $(date '+%Y-%m-%d %H:%M:%S') Compilation started ──────────────────────"

# Once hash is known, create flash log directory and open it for OTA logs
setup_flash_logs() {
  local hash="$1"
  [[ -z "$hash" ]] && return
  FLASH_LOG_DIR="${LOG_ROOT}/${RUN_TS}-${hash}"
  mkdir -p "$FLASH_LOG_DIR"
}

# ── Parse substitutions ──────────────────────────────────────────────────────
declare -A SUBS
while IFS= read -r line; do
  key=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
  val=$(echo "$line" | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '"')
  [[ -n "$key" ]] && SUBS["$key"]="$val"
done < <(awk '/^substitutions:/{found=1; next} found && /^[^ \t]/{exit} found{print}' "$YAML_FILE" \
  | grep -v '^\s*$')

resolve_subs() {
  local s="$1"
  for k in "${!SUBS[@]}"; do
    s="${s//\$\{$k\}/${SUBS[$k]}}"
  done
  echo "$s"
}

# ── Resolve esphome binary ───────────────────────────────────────────────────
ESPHOME_BIN="${HOME}/.local/esphome/venv/bin/esphome"

if [[ ! -x "$ESPHOME_BIN" ]]; then
  ESPHOME_BIN=$(command -v esphome 2>/dev/null || true)
fi

if [[ -z "$ESPHOME_BIN" ]]; then
  err "esphome not found. Expected ${HOME}/.local/esphome/venv/bin/esphome or on PATH."
  exit 1
fi

log "Using esphome: ${ESPHOME_BIN}"

# ── Parse yaml project info (display only) ──────────────────────────────────
EXPECTED_PROJECT=$(awk '/^\s+project:/{found=1; next} found && /name:/{print; found=0}' "$YAML_FILE" \
  | sed 's/.*name:[[:space:]]*//' | tr -d '"')
EXPECTED_PROJECT=$(resolve_subs "$EXPECTED_PROJECT")
EXPECTED_VERSION=$(awk '/^\s+project:/{found=1; next} found && /version:/{print; found=0}' "$YAML_FILE" \
  | sed 's/.*version:[[:space:]]*//' | tr -d '"')
EXPECTED_VERSION=$(resolve_subs "$EXPECTED_VERSION")

[[ -n "$EXPECTED_PROJECT" ]] && log "Project : ${EXPECTED_PROJECT}"
[[ -n "$EXPECTED_VERSION" ]] && log "Version : ${EXPECTED_VERSION}"

# ── Discover devices ─────────────────────────────────────────────────────────
BASE_NAME=$(awk '/^esphome:/{found=1; next} found && /^\s+name:/{print; found=0}' "$YAML_FILE" \
  | sed 's/.*name:[[:space:]]*//' | tr -d '"')
BASE_NAME=$(resolve_subs "$BASE_NAME")

# Extract device_id from project name (format: "namespace.device_id") for transition support
# Allows matching both old devices (using device_id) and new devices (using BASE_NAME)
DEVICE_ID=""
if [[ -n "$EXPECTED_PROJECT" && "$EXPECTED_PROJECT" == *"."* ]]; then
  DEVICE_ID=$(echo "$EXPECTED_PROJECT" | cut -d. -f2)
fi

if [[ -z "$BASE_NAME" ]]; then
  err "Could not parse esphome.name from $YAML_FILE."
  exit 1
fi

log "Discovering ${BASE_NAME}-* devices via mDNS..."

RAW=$(avahi-browse -t -r _esphomelib._tcp 2>/dev/null || true)

# Match on both BASE_NAME (current esphome.name) and DEVICE_ID (project-based legacy name)
# This allows seamless transition when renaming esphome.name
GREP_PATTERN="^${BASE_NAME}-"
if [[ -n "$DEVICE_ID" && "$DEVICE_ID" != "$BASE_NAME" ]]; then
  GREP_PATTERN="^(${BASE_NAME}|${DEVICE_ID})-"
fi

HOSTNAMES=$(echo "$RAW" \
  | grep "^= " \
  | awk '{print $4}' \
  | grep -E "$GREP_PATTERN" \
  | sort -u)

if [[ -z "$HOSTNAMES" ]]; then
  warn "No ${BASE_NAME}-* devices found on the network."
  exit 0
fi

DEVICE_COUNT=$(echo "$HOSTNAMES" | wc -l | tr -d ' ')
log "Found ${DEVICE_COUNT} device(s):"
echo "$HOSTNAMES" | while read -r h; do dim "  $h"; done
echo

# ── Parse config_hash and project_version from mDNS TXT records ─────────────
# config_hash is the primary comparison key; project_version is the fallback.
declare -A DEVICE_HASHES
declare -A DEVICE_VERSIONS
while IFS=: read -r type host val; do
  [[ "$type" == hash ]] && DEVICE_HASHES["$host"]="$val"
  [[ "$type" == ver  ]] && DEVICE_VERSIONS["$host"]="$val"
done < <(awk '
  /^= / { host = $4 }
  /txt =/ {
    n = split($0, parts, "\"")
    for (i = 1; i <= n; i++) {
      if (parts[i] ~ /^config_hash=/) {
        split(parts[i], kv, "=")
        print "hash:" host ":" kv[2]
      }
      if (parts[i] ~ /^project_version=/) {
        split(parts[i], kv, "=")
        print "ver:" host ":" kv[2]
      }
    }
  }
' <<< "$RAW")

# ── Home Assistant registry check ───────────────────────────────────────────
# Runs immediately after discovery so it always prints, even when no devices
# need flashing. Reads ha_url + ha_token from secrets.yaml (at project root).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="${SCRIPT_DIR}/secrets.yaml"
HA_URL=""
HA_TOKEN=""

if [[ -f "$SECRETS_FILE" ]]; then
  HA_URL=$(grep   '^ha_url:'   "$SECRETS_FILE" | sed 's/[^:]*:[[:space:]]*//' | tr -d '"'"'")
  HA_TOKEN=$(grep '^ha_token:' "$SECRETS_FILE" | sed 's/[^:]*:[[:space:]]*//' | tr -d '"'"'")
fi

if [[ -z "$HA_URL" || -z "$HA_TOKEN" ]]; then
  dim "(HA registry check skipped — add ha_url + ha_token to secrets.yaml to enable)"
else
  log "Querying Home Assistant: ${HA_URL}..."
  HA_DEVICE_LIST=$(
    HA_URL="$HA_URL" HA_TOKEN="$HA_TOKEN" BASE_NAME="$BASE_NAME" \
    python3 - <<'PYEOF'
import urllib.request, json, re, os, sys

url        = os.environ['HA_URL'].rstrip('/') + '/api/states'
token      = os.environ['HA_TOKEN']
base_name  = os.environ['BASE_NAME']
base_slug  = base_name.replace('-', '_')

req = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}'})
try:
    with urllib.request.urlopen(req, timeout=5) as r:
        states = json.load(r)
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)

pattern = re.compile(
    r'\.' + re.escape(base_slug) + r'_([0-9a-f]{6})(?:_|$)'
)
devices = set()
for s in states:
    m = pattern.search(s['entity_id'])
    if m:
        devices.add(base_name + '-' + m.group(1))

for d in sorted(devices):
    print(d)
PYEOF
  ) || { warn "Home Assistant query failed — skipping registry check."; HA_DEVICE_LIST=""; }

  echo
  echo "════════════════════════════════════════════════════════"
  if [[ -z "$HA_DEVICE_LIST" ]]; then
    printf " %-22s  %s\n" "HA registered" "0 device(s)"
    printf " %-22s  %s\n" "Seen on network" "$(echo "$HOSTNAMES" | wc -l | tr -d ' ') device(s)"
    echo "════════════════════════════════════════════════════════"
    ok "No devices of this type registered in HA yet."
  else
    HA_COUNT=$(echo "$HA_DEVICE_LIST" | wc -l | tr -d ' ')
    MDNS_COUNT=$(echo "$HOSTNAMES"    | wc -l | tr -d ' ')

    OFFLINE=()
    while IFS= read -r ha_dev; do
      echo "$HOSTNAMES" | grep -qxF "$ha_dev" || OFFLINE+=("$ha_dev")
    done <<< "$HA_DEVICE_LIST"

    printf " %-22s  %s\n" "HA registered" "${HA_COUNT} device(s)"
    printf " %-22s  %s\n" "Seen on network" "${MDNS_COUNT} device(s)"
    echo "════════════════════════════════════════════════════════"
    if [[ ${#OFFLINE[@]} -gt 0 ]]; then
      warn "Registered in HA but not found on network (${#OFFLINE[@]}):"
      for d in "${OFFLINE[@]}"; do
        dim "    ${d}"
      done
    else
      ok "All ${HA_COUNT} Home Assistant-registered device(s) accounted for."
    fi
  fi
  echo
fi

# ── Compile (with SHA256 cache to skip unnecessary builds) ───────────────────
# Cache key: SHA256 of the YAML file + ESPHome version.
# If both match a prior successful build, skip compilation and reuse the
# stored config_hash. Invalidated by any YAML edit or ESPHome upgrade.
CACHE_FILE="${BASE_LOG_DIR}/${YAML_NAME}.build.cache"

YAML_SHA256=$(sha256sum "$YAML_FILE" | awk '{print $1}')
ESPHOME_VERSION=$("$ESPHOME_BIN" version 2>/dev/null | grep -o '[0-9][0-9]*\.[0-9.]*' | head -1)

CACHED_YAML_SHA256=$(grep '^yaml_sha256='     "$CACHE_FILE" 2>/dev/null | cut -d= -f2 || true)
CACHED_ESPHOME_VER=$(grep '^esphome_version=' "$CACHE_FILE" 2>/dev/null | cut -d= -f2 || true)
CACHED_CONFIG_HASH=$(grep '^config_hash='     "$CACHE_FILE" 2>/dev/null | cut -d= -f2 || true)

NEW_CONFIG_HASH=""
COMPILED=false

if [[ "$UPGRADE_DELTA" == true || "$VERIFY" == true ]]; then
  if [[ -n "$CACHED_CONFIG_HASH" \
     && "$CACHED_YAML_SHA256" == "$YAML_SHA256" \
     && "$CACHED_ESPHOME_VER" == "$ESPHOME_VERSION" ]]; then
    log "YAML unchanged, ESPHome ${ESPHOME_VERSION} — skipping compilation."
    log "Cached config_hash: ${CACHED_CONFIG_HASH}"
    NEW_CONFIG_HASH="$CACHED_CONFIG_HASH"
    COMPILED=true
    setup_flash_logs "$NEW_CONFIG_HASH"
    echo
  else
    if [[ "$VERBOSE" == true ]]; then
      # Verbose mode: show all output
      ok "Compiling firmware (ESPHome ${ESPHOME_VERSION})..."
      COMPILE_LOG=$(mktemp)
      trap 'rm -f "$COMPILE_LOG"' EXIT
      if "$ESPHOME_BIN" compile "$YAML_FILE" 2>&1 | tee "$COMPILE_LOG"; then
        NEW_CONFIG_HASH=$(grep -o 'config_hash=0x[0-9a-f]*' "$COMPILE_LOG" \
          | tail -1 | sed 's/config_hash=0x//')
        COMPILED=true
        # Persist cache for next run
        printf 'yaml_sha256=%s\nesphome_version=%s\nconfig_hash=%s\n' \
          "$YAML_SHA256" "$ESPHOME_VERSION" "$NEW_CONFIG_HASH" > "$CACHE_FILE"
        setup_flash_logs "$NEW_CONFIG_HASH"
        [[ -n "$NEW_CONFIG_HASH" ]] && ok "Build config_hash: ${NEW_CONFIG_HASH}"
      else
        err "Compilation failed — aborting."
        exit 1
      fi
    else
      # Silent mode: compile with output to log file only
      printf "  ⚙ Compiling firmware (ESPHome ${ESPHOME_VERSION})..." >&2
      COMPILE_LOG=$(mktemp)
      trap 'rm -f "$COMPILE_LOG"' EXIT

      if "$ESPHOME_BIN" compile "$YAML_FILE" >> "$COMPILE_LOG" 2>&1; then
        NEW_CONFIG_HASH=$(grep -o 'config_hash=0x[0-9a-f]*' "$COMPILE_LOG" \
          | tail -1 | sed 's/config_hash=0x//')
        COMPILED=true
        printf " ${GRN}✓${RST}\n" >&2
        # Persist cache for next run
        printf 'yaml_sha256=%s\nesphome_version=%s\nconfig_hash=%s\n' \
          "$YAML_SHA256" "$ESPHOME_VERSION" "$NEW_CONFIG_HASH" > "$CACHE_FILE"
        setup_flash_logs "$NEW_CONFIG_HASH"
        [[ -n "$NEW_CONFIG_HASH" ]] && ok "Build config_hash: ${NEW_CONFIG_HASH}"
      else
        printf " ${RED}✗${RST}\n" >&2
        err "Compilation failed — see log: $LOG_FILE"
        exit 1
      fi
    fi
    echo
  fi
fi

# ── Per-device triage ────────────────────────────────────────────────────────
FLASH_LIST=()
SKIP_LIST=()
OK_LIST=()
FAIL_LIST=()
VERIFY_OK_LIST=()
VERIFY_FAIL_LIST=()
VERIFY_UNKNOWN_LIST=()

while IFS= read -r HOSTNAME; do
  DEVICE_HASH="${DEVICE_HASHES[$HOSTNAME]:-}"
  RUNNING_VERSION="${DEVICE_VERSIONS[$HOSTNAME]:-}"

  if [[ "$VERIFY" == true ]]; then
    if [[ -n "$NEW_CONFIG_HASH" && -n "$DEVICE_HASH" ]]; then
      if [[ "$DEVICE_HASH" == "$NEW_CONFIG_HASH" ]]; then
        ok "${HOSTNAME}: hash ${DEVICE_HASH} ✓"
        VERIFY_OK_LIST+=("$HOSTNAME")
      else
        err "${HOSTNAME}: hash ${DEVICE_HASH} ≠ ${NEW_CONFIG_HASH}"
        VERIFY_FAIL_LIST+=("$HOSTNAME")
      fi
    elif [[ -n "$RUNNING_VERSION" && -n "$EXPECTED_VERSION" ]]; then
      if [[ "$RUNNING_VERSION" == "$EXPECTED_VERSION" ]]; then
        ok "${HOSTNAME}: version ${RUNNING_VERSION} ✓  (no hash available)"
        VERIFY_OK_LIST+=("$HOSTNAME")
      else
        err "${HOSTNAME}: version ${RUNNING_VERSION} ≠ ${EXPECTED_VERSION}  (no hash available)"
        VERIFY_FAIL_LIST+=("$HOSTNAME")
      fi
    else
      warn "${HOSTNAME}: no hash or version in mDNS TXT"
      VERIFY_UNKNOWN_LIST+=("$HOSTNAME")
    fi
    continue
  fi

  if [[ "$UPGRADE_DELTA" == false ]]; then
    FLASH_LIST+=("$HOSTNAME")
    continue
  fi

  # Primary: config_hash comparison
  if [[ -n "$NEW_CONFIG_HASH" && -n "$DEVICE_HASH" ]]; then
    if [[ "$DEVICE_HASH" == "$NEW_CONFIG_HASH" ]]; then
      ok "${HOSTNAME}: hash ${DEVICE_HASH} matches — skipping."
      SKIP_LIST+=("$HOSTNAME")
    else
      warn "${HOSTNAME}: hash ${DEVICE_HASH} → ${NEW_CONFIG_HASH} — will flash."
      FLASH_LIST+=("$HOSTNAME")
    fi
  # Fallback: project_version comparison (devices without config_hash in TXT)
  elif [[ -n "$RUNNING_VERSION" && -n "$EXPECTED_VERSION" ]]; then
    if [[ "$RUNNING_VERSION" == "$EXPECTED_VERSION" ]]; then
      ok "${HOSTNAME}: version ${RUNNING_VERSION} matches — skipping."
      SKIP_LIST+=("$HOSTNAME")
    else
      warn "${HOSTNAME}: version ${RUNNING_VERSION} → ${EXPECTED_VERSION} — will flash."
      FLASH_LIST+=("$HOSTNAME")
    fi
  else
    warn "${HOSTNAME}: no hash or version info — will flash."
    FLASH_LIST+=("$HOSTNAME")
  fi

done <<< "$HOSTNAMES"

# ── Verify report ────────────────────────────────────────────────────────────
if [[ "$VERIFY" == true ]]; then
  echo
  echo "────────────────────────────────────────"
  [[ -n "$NEW_CONFIG_HASH" ]] && log "Expected hash    : ${NEW_CONFIG_HASH}"
  [[ -n "$EXPECTED_VERSION" ]] && log "Expected version : ${EXPECTED_VERSION}"
  [[ ${#VERIFY_OK_LIST[@]}      -gt 0 ]] && ok  "Matched  : ${VERIFY_OK_LIST[*]}"
  [[ ${#VERIFY_FAIL_LIST[@]}    -gt 0 ]] && err "Mismatch : ${VERIFY_FAIL_LIST[*]}"
  [[ ${#VERIFY_UNKNOWN_LIST[@]} -gt 0 ]] && warn "Unknown  : ${VERIFY_UNKNOWN_LIST[*]}"
  if [[ ${#VERIFY_FAIL_LIST[@]} -gt 0 || ${#VERIFY_UNKNOWN_LIST[@]} -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

# ── OTA flash plan ───────────────────────────────────────────────────────────
if [[ ${#FLASH_LIST[@]} -eq 0 ]]; then
  if [[ ${#OK_LIST[@]} -eq 0 && ${#FAIL_LIST[@]} -eq 0 ]]; then
    ok "All devices are up to date. Nothing to do."
    exit 0
  fi
  # USB was flashed; skip OTA and fall through to final report
else
  echo
  for h in "${FLASH_LIST[@]}"; do dim "  → $h (OTA)"; done

  if [[ "$DRY_RUN" == true ]]; then
    echo
    warn "Dry run — no OTA devices will be flashed."
    exit 0
  fi
  echo
fi

echo

# ── Compile (only if not already done above) ─────────────────────────────────
if [[ "$COMPILED" == false ]]; then
  if [[ "$VERBOSE" == true ]]; then
    ok "Compiling firmware..."
    COMPILE_LOG=$(mktemp)
    trap 'rm -f "$COMPILE_LOG"' EXIT
    if ! "$ESPHOME_BIN" compile "$YAML_FILE" 2>&1 | tee "$COMPILE_LOG"; then
      err "Compilation failed — aborting."
      exit 1
    fi
  else
    printf "  ⚙ Compiling firmware..." >&2
    COMPILE_LOG=$(mktemp)
    trap 'rm -f "$COMPILE_LOG"' EXIT

    if "$ESPHOME_BIN" compile "$YAML_FILE" >> "$COMPILE_LOG" 2>&1; then
      printf " ${GRN}✓${RST}\n" >&2
    else
      printf " ${RED}✗${RST}\n" >&2
      err "Compilation failed — see log: $LOG_FILE"
      exit 1
    fi
  fi
  echo
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ── USB serial flash ─────────────────────────────────────────────────────────
# If /dev/ttyACM0 exists, flash it first via serial before starting OTA.
# Always flashes regardless of --upgrade-delta (plugged in = intentional).
USB_DEVICE="/dev/ttyACM0"
USB_LOG=""
[[ -n "$FLASH_LOG_DIR" ]] && USB_LOG="${FLASH_LOG_DIR}/ttyACM0.log"

if [[ -c "$USB_DEVICE" ]]; then
  if [[ "$DRY_RUN" == true ]]; then
    warn "USB device at ${USB_DEVICE} detected — would flash (dry run, skipping)."
  else
    warn "USB device at ${USB_DEVICE} — flashing via serial..."
    echo
    if [[ -n "$USB_LOG" ]]; then
      "$ESPHOME_BIN" run "$YAML_FILE" --device "$USB_DEVICE" --no-logs >> "$USB_LOG" 2>&1 && USBOK=true || USBOK=false
    else
      "$ESPHOME_BIN" run "$YAML_FILE" --device "$USB_DEVICE" --no-logs && USBOK=true || USBOK=false
    fi

    if [[ "$USBOK" == true ]]; then
      ok "ttyACM0: flash successful."
      OK_LIST+=("ttyACM0")
    else
      err "ttyACM0: flash FAILED."
      FAIL_LIST+=("ttyACM0")
    fi
    echo
  fi
fi

# ── Parallel flash ───────────────────────────────────────────────────────────

log "Flashing ${#FLASH_LIST[@]} device(s) (max ${MAX_JOBS} parallel)..."
echo

slot_count=0

for HOSTNAME in "${FLASH_LIST[@]}"; do
  while [[ $slot_count -ge $MAX_JOBS ]]; do
    wait -n 2>/dev/null || true
    slot_count=$((slot_count - 1))
  done

  FQDN="${HOSTNAME}.local"
  dim "  started → ${HOSTNAME}"
  (
    if "$ESPHOME_BIN" run "$YAML_FILE" --device "$FQDN" --no-logs; then
      echo ok > "$WORK_DIR/${HOSTNAME}.result"
    else
      echo fail > "$WORK_DIR/${HOSTNAME}.result"
    fi
  ) > "$WORK_DIR/${HOSTNAME}.log" 2>&1 &

  slot_count=$((slot_count + 1))
done

# ── Background progress monitor ──────────────────────────────────────────────
# Polls each device's log file every 4s and prints a one-line status summary.
# ESPHome OTA logs progress as e.g. "OTA in progress: 25%" — captured by the
# percentage regex. Thread OTA is slower so this is especially useful there.
(
  elapsed=0
  while true; do
    sleep 4
    elapsed=$((elapsed + 4))
    parts=()
    for hostname in "${FLASH_LIST[@]}"; do
      result_f="${WORK_DIR}/${hostname}.result"
      log_f="${WORK_DIR}/${hostname}.log"
      if [[ -f "$result_f" ]]; then
        if [[ "$(cat "$result_f")" == ok ]]; then
          parts+=("${GRN}✓${RST} ${hostname}")
        else
          parts+=("${RED}✗${RST} ${hostname}")
        fi
      elif [[ -f "$log_f" ]]; then
        pct=$(grep -oE '[0-9]+(\.[0-9]+)? ?%' "$log_f" 2>/dev/null \
              | tr -d ' ' | tail -1)
        if [[ -n "$pct" ]]; then
          parts+=("${BLU}↑${RST} ${hostname} ${pct}")
        else
          parts+=("${DIM}… ${hostname}${RST}")
        fi
      else
        parts+=("${DIM}… ${hostname} (queued)${RST}")
      fi
    done
    line=""
    for part in "${parts[@]}"; do
      [[ -n "$line" ]] && line+="   "
      line+="$part"
    done
    echo -e "${DIM}  [${elapsed}s]${RST}  ${line}"
  done
) &
MONITOR_PID=$!

wait 2>/dev/null || true
kill "$MONITOR_PID" 2>/dev/null || true
wait "$MONITOR_PID" 2>/dev/null || true

# ── Print per-device logs and collect failures ───────────────────────────────
echo
for HOSTNAME in "${FLASH_LIST[@]}"; do
  dim "── ${HOSTNAME} ──────────────────────────────────────"
  cat "$WORK_DIR/${HOSTNAME}.log" 2>/dev/null || true
  if [[ "$(cat "$WORK_DIR/${HOSTNAME}.result" 2>/dev/null)" == ok ]]; then
    ok "${HOSTNAME}: flash successful."
    OK_LIST+=("$HOSTNAME")
  else
    err "${HOSTNAME}: flash FAILED."
    FAIL_LIST+=("$HOSTNAME")
  fi
  echo
done

# ── Copy OTA logs to persistent log directory ───────────────────────────────
if [[ -n "$FLASH_LOG_DIR" ]]; then
  for hostname in "${OK_LIST[@]}" "${FAIL_LIST[@]}"; do
    [[ "$hostname" == "ttyACM0" ]] && continue
    [[ -f "$WORK_DIR/${hostname}.log" ]] && cp "$WORK_DIR/${hostname}.log" "$FLASH_LOG_DIR/${hostname}.log" 2>/dev/null || true
  done
fi

# ── Final report ─────────────────────────────────────────────────────────────
total=$(( ${#OK_LIST[@]} + ${#FAIL_LIST[@]} + ${#SKIP_LIST[@]} ))
echo
echo "════════════════════════════════════════════════════════"
printf " %-6s  %-30s  %s\n" "RESULT" "DEVICE" "HASH / VERSION"
echo "────────────────────────────────────────────────────────"
for h in "${SKIP_LIST[@]}"; do
  info="${DEVICE_HASHES[$h]:-${DEVICE_VERSIONS[$h]:-?}}"
  printf " ${DIM}%-6s  %-30s  %s${RST}\n" "–" "$h" "$info"
done
for h in "${OK_LIST[@]}"; do
  if [[ "$h" == "ttyACM0" ]]; then
    info="USB serial"
  else
    info="${DEVICE_HASHES[$h]:+${DEVICE_HASHES[$h]} → ${NEW_CONFIG_HASH}}"
    info="${info:-flashed}"
  fi
  printf " ${GRN}%-6s${RST}  %-30s  %s\n" "✓" "$h" "$info"
done
for h in "${FAIL_LIST[@]}"; do
  printf " ${RED}%-6s${RST}  %-30s\n" "✗" "$h"
done
echo "════════════════════════════════════════════════════════"
printf " %d device(s): " "$total"
[[ ${#OK_LIST[@]}   -gt 0 ]] && printf "${GRN}%d flashed${RST}  "  "${#OK_LIST[@]}"
[[ ${#SKIP_LIST[@]} -gt 0 ]] && printf "${DIM}%d skipped${RST}  " "${#SKIP_LIST[@]}"
[[ ${#FAIL_LIST[@]} -gt 0 ]] && printf "${RED}%d FAILED${RST}"    "${#FAIL_LIST[@]}"
echo
echo "════════════════════════════════════════════════════════"

if [[ ${#FAIL_LIST[@]} -gt 0 ]]; then
  exit 1
fi
