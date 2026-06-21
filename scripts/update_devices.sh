#!/bin/bash
# update_devices.sh
# Discovers ESPHome devices via mDNS and OTA-flashes those whose firmware
# differs from the current build (compared by config_hash, not project.version).
#
# Usage:
#   ./update_devices.sh [options] <yaml-file>
#   ./update_devices.sh --reassign <MAC1> [MAC2 ...] <target-yaml>
#
# Options:
#   --upgrade-delta        Only flash devices whose config_hash differs from the
#                          current build (default: on)
#   --verify               Compile, then check each device's config_hash; report
#                          pass/fail and exit (no flashing, no changes to HA)
#   --force-update-entities Recreate entity IDs for all devices, even if no
#                          flashing occurs (useful after device renames)
#   --dry-run              Compile and show what would be flashed, without flashing
#   --reassign <MACs...>   Flash specific devices to a different configuration.
#                          Specify devices by MAC suffix and target YAML.
#   --jobs <n>             Maximum concurrent flash jobs (default: 4)
#   -v, --verbose          Show compilation output in terminal (default: silent)
#   --help                 Show this help


set -euo pipefail

_UPDATE_DEVICES_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${_UPDATE_DEVICES_SCRIPT_DIR}/config.sh"
# shellcheck source=scripts/bootstrap-yaml.sh
source "${_UPDATE_DEVICES_SCRIPT_DIR}/bootstrap-yaml.sh"

# -- Cleanup on exit ----------------------------------------------------------
WORK_DIR=""
COMPILE_YAML=""
COMPILE_LOG=""

cleanup() {
  # Kill all background jobs (OTA uploads)
  jobs -p | xargs -r kill 2>/dev/null || true
  iotstack_cleanup_generated_yamls
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
  if [[ -n "${COMPILE_LOG}" && -f "${COMPILE_LOG}" ]]; then
    rm -f "${COMPILE_LOG}"
  fi
  if [[ -n "${ORIGINAL_YAML_FILE:-}" ]]; then
    iotstack_cleanup_compile_yaml "${COMPILE_YAML:-}" "$ORIGINAL_YAML_FILE"
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT

# -- Defaults ----------------------------------------------------------------
UPGRADE_DELTA=true
VERIFY=false
DRY_RUN=false
VERBOSE=false
COMPILATION_OUTPUT=false
FORCE_UPDATE_ENTITIES=false
MAX_JOBS=4
JOBS_EXPLICIT=false
YAML_FILE=""
OTA_PASSWORD=""
REASSIGN_MODE=false
HA_FINALIZE_HOSTNAME=""
declare -a REASSIGN_MACS=()
REASSIGN_YAML=""

# -- Colours -----------------------------------------------------------------
RED=$'\033[0;31m'
GRN=$'\033[0;32m'
YLW=$'\033[0;33m'
BLU=$'\033[0;34m'
DIM=$'\033[2m'
RST=$'\033[0m'

info() { echo -e "${BLU}[INFO]${RST}  $*"; }
log()  { if [[ "$VERBOSE" == true ]]; then info "$@"; fi; return 0; }
ok()   { echo -e "${GRN}[OK]${RST}    $*"; }
warn() { echo -e "${YLW}[WARN]${RST}  $*"; }
err()  { echo -e "${RED}[ERR]${RST}   $*" >&2; }
dim()  { echo -e "${DIM}$*${RST}"; }

_config_hash_from_build_info() {
  local build_name="$1"
  local build_info="${YAMLS_DIR}/.esphome/build/${build_name}/build_info.json"
  [[ -f "$build_info" ]] || return 1
  python3 -c "import json,sys; print(format(json.load(open(sys.argv[1]))['config_hash'], '08x'))" "$build_info"
}

_resolve_build_config_hash() {
  # Authoritative build config_hash when compile is skipped (cache hit).
  local build_name="$1"
  local cached_hash="${2:-}"
  local hash

  hash=$(_config_hash_from_build_info "$build_name" 2>/dev/null) || true
  [[ -n "$hash" ]] && { echo "$hash"; return 0; }
  [[ -n "$cached_hash" ]] && echo "$cached_hash"
}

_sync_build_cache_config_hash() {
  local resolved_hash="$1"
  [[ -n "$resolved_hash" && "$resolved_hash" != "$CACHED_CONFIG_HASH" ]] || return 0
  mkdir -p "$(dirname "$CACHE_FILE")"
  printf 'yaml_sha256=%s\nesphome_version=%s\nconfig_hash=%s\n' \
    "$YAML_SHA256" "$ESPHOME_VERSION" "$resolved_hash" > "$CACHE_FILE"
}

_compile_log_banner() {
  # Written when esphome compile actually starts (not at script startup).
  local banner="-- $(date '+%Y-%m-%d %H:%M:%S') Compiling $(basename "$YAML_FILE") --"
  echo "$banner" >> "$COMPILE_LOG_FILE"
  if [[ "$VERBOSE" == true ]]; then echo "$banner"; fi
}

# -- Ensure websocket-client library is installed ----------------------------
ensure_websocket_client() {
  if python3 -c "import websocket" 2>/dev/null; then
    return 0
  fi

  echo >&2
  warn "python3-websocket library is required for entity ID recreation" >&2
  echo "Without it, entity IDs won't be updated when devices are renamed." >&2
  echo >&2

  read -p "Install python3-websocket now? (y/n) " -n 1 -r </dev/tty
  echo >&2
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    warn "Skipping entity ID recreation" >&2
    return 1
  fi

  if sudo apt-get update -qq && sudo apt-get install -y python3-websocket >/dev/null 2>&1; then
    ok "python3-websocket installed successfully" >&2
    return 0
  else
    err "Failed to install python3-websocket"
    warn "You can install manually: sudo apt-get install python3-websocket" >&2
    return 1
  fi
}

# -- Report discovered ESPHome config flows via WebSocket API ----------------
# Home Assistant exposes discovery flows over WebSocket (config_entries/flow/progress).
# Completing a config flow step is not available via the public WebSocket API, so this
# function only detects pending ESPHome discoveries and reports them.
auto_configure_discovered_esphome() {
  local ha_url="$1"
  local ha_token="$2"
  local api_key="$3"

  if [[ -z "$ha_url" || -z "$ha_token" || -z "$api_key" ]]; then
    return 0
  fi

  local ha_ws_script="${_UPDATE_DEVICES_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}/ha_websocket.py"
  [[ -f "$ha_ws_script" ]] || return 0

  python3 - "$ha_url" "$ha_token" "$ha_ws_script" <<'PYEOF'
import json
import subprocess
import sys

ha_url = sys.argv[1].rstrip("/")
token = sys.argv[2]
ha_ws_script = sys.argv[3]


def ws_query(msg_type: str, data: dict | None = None):
    cmd = [
        sys.executable,
        ha_ws_script,
        "--ha-url",
        ha_url,
        "--ha-token",
        token,
        "query",
        "--type",
        msg_type,
        "--data",
        json.dumps(data or {}),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


flows = ws_query("config_entries/flow/progress")
if not flows:
    sys.exit(0)

for flow in flows:
    if flow.get("handler") != "esphome":
        continue
    title = flow.get("context", {}).get("title") or flow.get("flow_id", "unknown")
    print(f"Discovered ESPHome device pending in Home Assistant: {title}")
    print("  Complete in HA: Settings -> Devices & Services -> Discovered")

sys.exit(0)
PYEOF
}

# -- Create temporary YAML with device_new_name injected ---------------------
create_temp_yaml_with_device_id() {
  local orig_yaml="$1"
  local device_id_value="$2"
  local temp_yaml="$3"

  python3 - "$orig_yaml" "$device_id_value" "$temp_yaml" <<'PYTHONEOF'
import sys, re

orig_yaml = sys.argv[1]
device_new_name = sys.argv[2]
temp_yaml = sys.argv[3]

with open(orig_yaml, 'r') as f:
    content = f.read()

# Check if substitutions section exists and add device_new_name
if re.search(r'^substitutions:', content, re.MULTILINE):
    # Find the substitutions section and add device_new_name to it
    content = re.sub(
        r'^(substitutions:)(.*?)(?=^[a-z])',
        lambda m: m.group(1) + m.group(2) + f'  device_new_name: "{device_new_name}"\n',
        content,
        flags=re.MULTILINE | re.DOTALL,
        count=1
    )
else:
    # Create substitutions section before esphome
    content = re.sub(
        r'^(esphome:)',
        f'substitutions:\n  device_new_name: "{device_new_name}"\n\n\\1',
        content,
        flags=re.MULTILINE,
        count=1
    )

# Replace project.name to use device_new_name instead of device_name
# Match: name: "iotstack.${device_name}" or name: iotstack.${device_name}
content = re.sub(
    r'(name:\s+["\']?)([^"\'\n]*)\$\{device_name\}([^"\'\n]*["\']?)',
    lambda m: f'{m.group(1)}{m.group(2)}${{device_new_name}}{m.group(3)}',
    content
)

with open(temp_yaml, 'w') as f:
    f.write(content)
PYTHONEOF
}

# -- Create upload-only YAML with OTA client config ----------------------------
# Production firmware must not include an OTA server (compiled from ORIGINAL_YAML_FILE).
# esphome upload still requires ota: in the config it reads -- this temp file is
# used only for the upload command, never for compilation.
create_ota_upload_yaml() {
  local orig_yaml="$1"
  local ota_password="${2:-}"
  local temp_yaml="$3"

  python3 - "$orig_yaml" "$ota_password" "$temp_yaml" <<'PYTHONEOF'
import sys, re

orig_yaml = sys.argv[1]
ota_password = sys.argv[2]
temp_yaml = sys.argv[3]

with open(orig_yaml, 'r') as f:
    content = f.read()

if re.search(r'^ota:', content, re.MULTILINE):
    with open(temp_yaml, 'w') as f:
        f.write(content)
    sys.exit(0)

if ota_password:
    ota_block = (
        '\nota:\n'
        '  - platform: esphome\n'
        f'    password: "{ota_password}"\n'
    )
else:
    ota_block = '\nota:\n  - platform: esphome\n'

with open(temp_yaml, 'w') as f:
    f.write(content + ota_block)
PYTHONEOF
}

# -- Update YAML device_name substitution -------------------------------------
update_yaml_device_name() {
  local yaml_file="$1"
  local new_device_name="$2"

  if grep -q 'device_name:' "$yaml_file"; then
    sed -i "s/device_name: .*/device_name: \"$new_device_name\"/" "$yaml_file"
  else
    sed -i "/^substitutions:/a\\  device_name: \"$new_device_name\"" "$yaml_file"
  fi
}

# -- Post-production HA: entity IDs + consistency (production hostname only) -
run_ha_production_finalize() {
  local yaml_file="$1"
  local prod_hostname="$2"

  _UPDATE_DEVICES_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/ensure-integration-secrets.sh
  source "${_UPDATE_DEVICES_SCRIPT_DIR}/ensure-integration-secrets.sh"
  load_ha_credentials_optional || true

  if [[ -z "$HA_URL" || -z "$HA_TOKEN" ]]; then
    return 0
  fi

  recreate_entity_ids "$HA_URL" "$HA_TOKEN" "$prod_hostname"

  local consistency_output
  consistency_output=$(verify_entity_id_consistency "$HA_URL" "$HA_TOKEN" "$yaml_file" "$prod_hostname" 2>&1)
  if [[ -n "$consistency_output" ]]; then
    if echo "$consistency_output" | grep -q "WARNING"; then
      echo "$consistency_output"
    else
      ok "Entity ID consistency: All entity IDs match device names"
    fi
  fi
}

# -- Verify entity ID consistency with device name ------------------------------
verify_entity_id_consistency() {
  local ha_url="$1"
  local ha_token="$2"
  local yaml_file="$3"
  local hostnames="$4"  # space-separated list of device hostnames
  local entity_slug

  if [[ -z "$ha_url" || -z "$ha_token" || -z "$hostnames" || -z "$yaml_file" ]]; then
    return 0
  fi

  local entity_slug friendly_name
  entity_slug=$(yaml_entity_slug_from_file "$yaml_file") || return 0
  friendly_name=$(yaml_friendly_name_from_file "$yaml_file") || friendly_name="$entity_slug"

  HA_URL="$ha_url" HA_TOKEN="$ha_token" ENTITY_SLUG="$entity_slug" \
    FRIENDLY_NAME="$friendly_name" HOSTNAMES="$hostnames" python3 - <<'VERIFYEOF'
import json, os, sys, ssl, re
try:
    import websocket
except ImportError:
    # Skip if websocket not available (check will be skipped silently)
    sys.exit(0)

ha_url = os.environ['HA_URL'].rstrip('/')
token = os.environ['HA_TOKEN']
entity_slug = os.environ['ENTITY_SLUG']
friendly_name = os.environ.get('FRIENDLY_NAME', entity_slug)
hostnames = os.environ['HOSTNAMES'].strip().split()

# Extract MAC suffixes
mac_suffixes = {}
for hostname in hostnames:
    m = re.search(r'([0-9a-f]{6})$', hostname, re.IGNORECASE)
    if m:
        mac = m.group(1).lower()
        mac_suffixes[mac] = hostname

if not mac_suffixes:
    sys.exit(0)

# Connect to WebSocket
ws_url = ha_url.replace('http://', 'ws://').replace('https://', 'wss://') + '/api/websocket'
import warnings
warnings.filterwarnings('ignore')

try:
    ws = websocket.create_connection(
        ws_url,
        sslopt={"cert_reqs": ssl.CERT_NONE},
        timeout=10
    )
except Exception:
    sys.exit(0)

msg_id = 1

# Authenticate
try:
    init_msg = json.loads(ws.recv())
    if init_msg.get('type') != 'auth_required':
        ws.close()
        sys.exit(0)
    ws.send(json.dumps({'type': 'auth', 'access_token': token}))
    auth_result = json.loads(ws.recv())
    if auth_result.get('type') != 'auth_ok':
        ws.close()
        sys.exit(0)
except Exception:
    ws.close()
    sys.exit(0)

# Get entity registry
try:
    msg_id += 1
    ws.send(json.dumps({'id': msg_id, 'type': 'config/entity_registry/list'}))
    entities_msg = json.loads(ws.recv())
    if not entities_msg.get('success'):
        ws.close()
        sys.exit(0)
    all_entities = entities_msg.get('result', [])
except Exception:
    ws.close()
    sys.exit(0)

ws.close()

# Check entity ID consistency (only ESPHome entities)
base_slug = entity_slug.replace('-', '_')
inconsistent = []

for entity in all_entities:
    entity_id = entity.get('entity_id', '').lower()
    platform = entity.get('platform', '').lower()

    # Only check ESPHome entities
    if platform != 'esphome':
        continue

    # Check if entity belongs to any of our devices
    for mac, hostname in mac_suffixes.items():
        if mac not in entity_id:
            continue

        # Entity belongs to this device - check if device name is correct
        if base_slug not in entity_id:
            inconsistent.append({
                'entity_id': entity_id,
                'device': hostname,
                'mac': mac
            })
        break

if inconsistent:
    print('WARNING: Entity ID inconsistencies detected:', file=sys.stderr)
    for item in inconsistent:
        print(
            f"  {item['entity_id']} (should contain '{base_slug}', "
            f"from friendly_name '{friendly_name}', device {item['device']})",
            file=sys.stderr,
        )
    sys.exit(0)

print('All entity IDs are consistent with device names.')
VERIFYEOF
}

# -- Recreate entity IDs for renamed devices --------------------------------
recreate_entity_ids() {
  local ha_url="$1"
  local ha_token="$2"
  local hostnames="$3"  # space-separated list of device hostnames

  if [[ -z "$ha_url" || -z "$ha_token" || -z "$hostnames" ]]; then
    return 0
  fi

  # Check if websocket library is available
  if ! ensure_websocket_client; then
    return 0
  fi

  ok "Updating device names and entity IDs..."

  HA_URL="$ha_url" HA_TOKEN="$ha_token" HOSTNAMES="$hostnames" python3 - <<'PYEOF'
import json, os, sys, ssl, re, websocket

ha_url = os.environ['HA_URL'].rstrip('/')
token = os.environ['HA_TOKEN']
hostnames = os.environ['HOSTNAMES'].strip().split()

# Extract MAC suffixes from hostnames
mac_suffixes = set()
for hostname in hostnames:
    m = re.search(r'([0-9a-f]{6})$', hostname, re.IGNORECASE)
    if m:
        mac_suffixes.add(m.group(1).lower())

if not mac_suffixes:
    sys.exit(0)

# Convert HTTP(S) URL to WS(S) URL
ws_url = ha_url.replace('http://', 'ws://').replace('https://', 'wss://') + '/api/websocket'

import warnings
warnings.filterwarnings('ignore')

try:
    ws = websocket.create_connection(
        ws_url,
        sslopt={"cert_reqs": ssl.CERT_NONE},
        timeout=10
    )
except Exception as e:
    print(f'ERROR: Failed to connect to HA WebSocket: {e}', file=sys.stderr)
    sys.exit(1)

msg_id = 1

# Authenticate
try:
    init_msg = json.loads(ws.recv())
    if init_msg.get('type') != 'auth_required':
        sys.exit(1)

    ws.send(json.dumps({'type': 'auth', 'access_token': token}))
    auth_result = json.loads(ws.recv())

    if auth_result.get('type') != 'auth_ok':
        sys.exit(1)
except Exception as e:
    print(f'ERROR: Authentication failed: {e}', file=sys.stderr)
    sys.exit(1)

# Get entity registry list
try:
    msg_id += 1
    ws.send(json.dumps({
        'id': msg_id,
        'type': 'config/entity_registry/list'
    }))

    entities_msg = json.loads(ws.recv())
    if not entities_msg.get('success'):
        sys.exit(1)

    all_entities = entities_msg.get('result', [])
except Exception as e:
    print(f'ERROR: Failed to list entities: {e}', file=sys.stderr)
    ws.close()
    sys.exit(1)

# Get device registry to match MACs and update device names
try:
    msg_id += 1
    ws.send(json.dumps({
        'id': msg_id,
        'type': 'config/device_registry/list'
    }))

    devices_msg = json.loads(ws.recv())
    if not devices_msg.get('success'):
        ws.close()
        sys.exit(0)

    all_devices = devices_msg.get('result', [])
except Exception:
    ws.close()
    sys.exit(0)

# Build hostname map from hostname list
hostname_map = {}
for hostname in hostnames:
    m = re.search(r'([0-9a-f]{6})$', hostname, re.IGNORECASE)
    if m:
        mac = m.group(1).lower()
        hostname_map[mac] = hostname

# Find and update devices by MAC, extracting new names from hostnames
updated_devices = []
for device in all_devices:
    device_id = device.get('id')
    if not device_id:
        continue

    # Check if device has a MAC identifier matching our devices
    identifiers = device.get('identifiers', [])
    for identifier_set in identifiers:
        if not isinstance(identifier_set, (list, tuple)):
            continue
        for identifier in identifier_set:
            if not isinstance(identifier, str):
                continue
            # Check if this identifier contains a MAC we're looking for
            for mac, hostname in hostname_map.items():
                if mac in identifier.lower():
                    # Extract new device name from hostname (e.g., "c6-wifi-mmwave" from "c6-wifi-mmwave-199f38")
                    # Keep only the part before the last dash followed by MAC
                    new_name = hostname.rsplit('-', 1)[0] if '-' in hostname else hostname
                    updated_devices.append((device_id, hostname, new_name))
                    break

# Update device names in registry (this triggers HA to regenerate entity IDs)
for device_id, hostname, new_name in updated_devices:
    try:
        msg_id += 1
        ws.send(json.dumps({
            'id': msg_id,
            'type': 'config/device_registry/update',
            'device_id': device_id,
            'name_by_user': new_name
        }))

        result = json.loads(ws.recv())
        if result.get('success'):
            print(f'Updated device: {hostname} -> {new_name}')
    except Exception:
        pass

# Find entities for entity ID updates
entity_ids_to_update = []
for entity in all_entities:
    entity_id = entity.get('entity_id', '').lower()
    platform = entity.get('platform', '').lower()

    # Skip entities that don't belong to ESPHome
    if platform != 'esphome':
        continue

    for mac in mac_suffixes:
        if mac in entity_id:
            entity_ids_to_update.append(entity.get('entity_id'))
            break

if not entity_ids_to_update:
    ws.close()
    sys.exit(0)

# Get automatic entity IDs for these entities
try:
    msg_id += 1
    ws.send(json.dumps({
        'id': msg_id,
        'type': 'config/entity_registry/get_automatic_entity_ids',
        'entity_ids': entity_ids_to_update
    }))

    auto_ids_msg = json.loads(ws.recv())
    if not auto_ids_msg.get('success'):
        print(f'WARNING: Failed to get automatic entity IDs', file=sys.stderr)
        ws.close()
        sys.exit(0)

    id_mapping = auto_ids_msg.get('result', {})
except Exception as e:
    print(f'WARNING: Failed to get automatic entity IDs: {e}', file=sys.stderr)
    ws.close()
    sys.exit(0)

# Update entity IDs if they changed
updated_count = 0
for old_id, new_id in id_mapping.items():
    if old_id == new_id or not new_id:
        continue

    try:
        msg_id += 1
        ws.send(json.dumps({
            'id': msg_id,
            'type': 'config/entity_registry/update',
            'entity_id': old_id,
            'new_entity_id': new_id
        }))

        result = json.loads(ws.recv())
        if result.get('success'):
            print(f'Recreated: {old_id} -> {new_id}')
            updated_count += 1
        else:
            print(f'WARNING: Failed to update {old_id}: {result.get("error")}', file=sys.stderr)
    except Exception as e:
        print(f'WARNING: Error updating {old_id}: {e}', file=sys.stderr)

ws.close()
if updated_count > 0:
    print(f'Successfully recreated {updated_count} entity ID(s).')
PYEOF
}

# -- Help --------------------------------------------------------------------
usage() {
  grep '^#' "$0" | head -20 | sed 's/^# \{0,1\}//'
  exit 0
}

# -- Argument parsing --------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade-delta)         UPGRADE_DELTA=true;  shift ;;
    --erase)          err "--erase is not valid for update_devices.sh; use 'iotstack flash' for USB erase"; exit 1 ;;
    --verify)                VERIFY=true;         shift ;;
    --force-update-entities) FORCE_UPDATE_ENTITIES=true; shift ;;
    --dry-run)               DRY_RUN=true;        shift ;;
    --jobs)                  MAX_JOBS="$2"; JOBS_EXPLICIT=true; shift 2 ;;
    --ota-password)          OTA_PASSWORD="$2";   shift 2 ;;
    --ha-finalize)           HA_FINALIZE_HOSTNAME="$2"; shift 2 ;;
    --reassign)
      REASSIGN_MODE=true
      shift
      # Collect MAC suffixes and target YAML until we hit a flag
      while [[ $# -gt 0 ]] && [[ "$1" != --* ]]; do
        if [[ "$1" == */* ]]; then
          # This is a YAML path
          REASSIGN_YAML="$1"
        else
          # This is a MAC suffix
          REASSIGN_MACS+=("$1")
        fi
        shift
      done
      ;;
    -v|--verbose)            VERBOSE=true;        shift ;;
    --compilation-output)    COMPILATION_OUTPUT=true; shift ;;
    --help|-h)               usage ;;
    -*)                      err "Unknown option: $1"; exit 1 ;;
    *)                       YAML_FILE="$1";      shift ;;
  esac
done

# -- Validate inputs ---------------------------------------------------------
if [[ "$REASSIGN_MODE" == true ]]; then
  if [[ -z "$REASSIGN_YAML" ]] || [[ ${#REASSIGN_MACS[@]} -eq 0 ]]; then
    err "--reassign requires: <MAC1> [MAC2 ...] <yaml-file>"
    exit 1
  fi
  YAML_FILE="$REASSIGN_YAML"
else
  if [[ -z "$YAML_FILE" ]]; then
    err "No yaml file specified."
    echo "Usage: $0 [--upgrade-delta] [--verify] [--dry-run] [--jobs N] <yaml-file>"
    exit 1
  fi
fi

if [[ ! -f "$YAML_FILE" ]]; then
  err "File not found: $YAML_FILE"
  exit 1
fi

# Standalone: entity-ID work after device has booted production (not bootstrap).
if [[ -n "$HA_FINALIZE_HOSTNAME" ]]; then
  run_ha_production_finalize "$YAML_FILE" "$HA_FINALIZE_HOSTNAME"
  exit 0
fi

# -- Handle custom OTA password for authentication -------------------------
# If user provided a custom OTA password, create a temporary YAML with it
# The OTA password is used to authenticate the OTA upload from the current device
# IMPORTANT: Save original YAML name for caching (before temp file creation)
ORIGINAL_YAML_FILE="$YAML_FILE"
COMPILE_YAML=$(iotstack_prepare_compile_yaml "$ORIGINAL_YAML_FILE")
YAML_FILE="$COMPILE_YAML"

# All secrets must come from NVS at runtime -- !secret references in YAML are
# forbidden. Catch them early so the build never silently embeds credentials.
if grep -qE 'password:[[:space:]]+!secret[[:space:]]+\S' "$YAML_FILE"; then
  err "$(basename "$YAML_FILE") contains '!secret' password references.
All secrets must be stored in NVS (via write-nvs-secrets.sh), not in YAML files.
Remove the 'password: !secret ...' line(s) and re-run."
fi

# Production firmware must not expose an OTA server -- updates run from bootstrap only.
_yaml_is_bootstrap() {
  local yaml_file="$1"
  [[ "$(basename "$yaml_file")" == "bootstrap.yaml" ]] && return 0
  grep -qE "^[[:space:]]*device_role:[[:space:]]*\"?$(iotstack_bootstrap_role)\"?[[:space:]]*$" "$yaml_file" 2>/dev/null
}

UPLOAD_YAML=""
OTA_UPLOAD_TEMP=""

if ! _yaml_is_bootstrap "$YAML_FILE"; then
  if grep -qE '^ota:' "$YAML_FILE"; then
    err "$(basename "$YAML_FILE") must not include 'ota:' -- OTA is bootstrap-only.
Remove the ota: section from this production YAML."
  fi
  if grep -qE 'platform:[[:space:]]+factory_reset' "$YAML_FILE"; then
    err "$(basename "$YAML_FILE") must not include a factory_reset button -- physical reset is handled by boot_button.yaml.
Remove the factory_reset button from this production YAML."
  fi
fi

if grep -qE '^safe_mode:' "$YAML_FILE"; then
  err "$(basename "$YAML_FILE") must not include 'safe_mode:' -- boot-loop recovery is handled by partition_manager.
Remove the safe_mode: section from this YAML."
fi

if _yaml_is_bootstrap "$YAML_FILE"; then
  if grep -qE 'partition_manager\.yaml|partition_manager_production\.yaml' "$YAML_FILE"; then
    err "$(basename "$YAML_FILE") must use partition_manager_bootstrap.yaml -- switch_to_bootstrap is production-only."
  fi
else
  if grep -qE 'partition_manager_bootstrap\.yaml' "$YAML_FILE"; then
    err "$(basename "$YAML_FILE") must use partition_manager.yaml -- production requires switch_to_bootstrap API."
  fi
fi

if ! [[ "$MAX_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  err "--jobs must be a positive integer."
  exit 1
fi

# -- Disable parallelism for Thread devices ----------------------------------
# Thread OTA is slow; parallelism causes contention on the mesh rather than
# speeding up flashing. Force --jobs 1 unless explicitly overridden by user.
if [[ "$YAML_FILE" == *"/thread/"* || "$YAML_FILE" == "thread-"* ]]; then
  if [[ "$JOBS_EXPLICIT" == false ]]; then
    MAX_JOBS=1
  fi
fi

# -- Logging ------------------------------------------------------------------
# Use original YAML file for cache key (before any temp file creation)
# This ensures cache is consistent across reassign runs with different OTA passwords
YAML_NAME="$(basename "${ORIGINAL_YAML_FILE%.yaml}")"
BASE_LOG_DIR="${HOME}/.iotstack/logs"
LOG_ROOT="${BASE_LOG_DIR}/${YAML_NAME}"
RUN_TS="$(date '+%Y%m%d_%H%M%S')"
COMPILE_LOG_FILE="${LOG_ROOT}/${RUN_TS}.compile.log"
FLASH_LOG_DIR=""  # Set after compilation succeeds and hash is known
mkdir -p "$LOG_ROOT"

# Non-verbose: capture stdout/stderr to the per-run compile log (spinner stays on stderr).
if [[ "$VERBOSE" != true ]]; then
  exec > >(tee -a "$COMPILE_LOG_FILE") 2>&1
fi

# Once hash is known, create flash log directory and open it for OTA logs
setup_flash_logs() {
  local hash="$1"
  [[ -z "$hash" ]] && return
  FLASH_LOG_DIR="${LOG_ROOT}/${RUN_TS}-${hash}"
  mkdir -p "$FLASH_LOG_DIR"
}

# -- Parse substitutions ------------------------------------------------------
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

# -- Resolve esphome binary ---------------------------------------------------
ESPHOME_BIN="${HOME}/.local/esphome/venv/bin/esphome"

if [[ ! -x "$ESPHOME_BIN" ]]; then
  ESPHOME_BIN=$(command -v esphome 2>/dev/null || true)
fi

if [[ -z "$ESPHOME_BIN" ]]; then
  err "esphome not found. Expected ${HOME}/.local/esphome/venv/bin/esphome or on PATH."
  exit 1
fi

log "Using esphome: ${ESPHOME_BIN}"

# -- Parse yaml project info (display only) ----------------------------------
EXPECTED_PROJECT=$(awk '/^\s+project:/{found=1; next} found && /name:/{print; found=0}' "$YAML_FILE" \
  | sed 's/.*name:[[:space:]]*//' | tr -d '"')
EXPECTED_PROJECT=$(resolve_subs "$EXPECTED_PROJECT")
EXPECTED_VERSION=$(awk '/^\s+project:/{found=1; next} found && /version:/{print; found=0}' "$YAML_FILE" \
  | sed 's/.*version:[[:space:]]*//' | tr -d '"')
EXPECTED_VERSION=$(resolve_subs "$EXPECTED_VERSION")

if [[ -n "$EXPECTED_PROJECT" ]]; then log "Project : ${EXPECTED_PROJECT}"; fi
if [[ -n "$EXPECTED_VERSION" ]]; then log "Version : ${EXPECTED_VERSION}"; fi

# -- Discover devices ---------------------------------------------------------
BASE_NAME=$(awk '/^esphome:/{found=1; next} found && /^\s+name:/{print; found=0}' "$YAML_FILE" \
  | sed 's/.*name:[[:space:]]*//' | tr -d '"')
BASE_NAME=$(resolve_subs "$BASE_NAME")

if [[ -z "$BASE_NAME" ]]; then
  err "Could not parse esphome.name from $YAML_FILE."
  exit 1
fi

if [[ "$REASSIGN_MODE" == true ]]; then
  info "Discovering devices to reassign: ${REASSIGN_MACS[*]}"
elif [[ "$VERIFY" == true ]]; then
  info "Discovering ${BASE_NAME}-* devices via mDNS..."
else
  log "Discovering ${BASE_NAME}-* devices via mDNS..."
fi

if [[ "$REASSIGN_MODE" == true ]]; then
  # Reassign always OTA's from bootstrap, which advertises "$(iotstack_bootstrap_mdns_service)" only.
  # Dry-run may run before the device has been switched to bootstrap, so also scan
  # production mDNS to allow compile/plan when the device is still on production.
  if [[ "$DRY_RUN" == true ]]; then
    _mdns_prod_raw=$(mktemp)
    _mdns_boot_raw=$(mktemp)
    avahi-browse -t -r _esphomelib._tcp 2>/dev/null >"$_mdns_prod_raw" &
    _mdns_prod_pid=$!
    avahi-browse -t -r "$(iotstack_bootstrap_mdns_service)" 2>/dev/null >"$_mdns_boot_raw" &
    _mdns_boot_pid=$!
    wait "$_mdns_prod_pid" || true
    wait "$_mdns_boot_pid" || true
    RAW=$(cat "$_mdns_prod_raw" "$_mdns_boot_raw")
    rm -f "$_mdns_prod_raw" "$_mdns_boot_raw"
  else
    RAW=$(avahi-browse -t -r "$(iotstack_bootstrap_mdns_service)" 2>/dev/null || true)
  fi
else
  RAW=$(avahi-browse -t -r _esphomelib._tcp 2>/dev/null || true)
fi

# Extract device hostnames from mDNS
if [[ "$REASSIGN_MODE" == true ]]; then
  # In reassign mode, discover ALL devices then filter by MAC suffix
  ALL_DEVICES=$(echo "$RAW" \
    | grep "^= " \
    | awk '{print $4}' \
    | sort -u || true)

  HOSTNAMES=""
  for mac in "${REASSIGN_MACS[@]}"; do
    # Match devices ending with the MAC suffix (strip special chars, just use the MAC)
    matching=$(echo "$ALL_DEVICES" | grep "${mac}" || true)
    if [[ -n "$matching" ]]; then
      HOSTNAMES+="$matching"$'\n'
    fi
  done
  HOSTNAMES=$(echo "$HOSTNAMES" | sed '/^$/d' | sort -u)
else
  # Normal mode: Match by device_name to avoid cross-config flashing
  HOSTNAMES=$(echo "$RAW" \
    | grep "^= " \
    | awk '{print $4}' \
    | grep "^${BASE_NAME}-" \
    | sort -u || true)
fi

if [[ -z "$HOSTNAMES" ]]; then
  if [[ "$REASSIGN_MODE" == true ]]; then
    warn "No devices found with MAC suffixes: ${REASSIGN_MACS[*]}"
    exit 1
  elif [[ "$VERIFY" == true ]]; then
    warn "No ${BASE_NAME}-* devices found on the network -- nothing to verify."
    exit 1
  else
    warn "No ${BASE_NAME}-* devices found on the network."
    exit 0
  fi
fi

# In reassign mode, check if all requested MACs were found
if [[ "$REASSIGN_MODE" == true ]]; then
  declare -a FOUND_MACS=()
  for hostname in $HOSTNAMES; do
    mac=$(echo "$hostname" | grep -oE '[0-9a-f]{6}$')
    [[ -n "$mac" ]] && FOUND_MACS+=("$mac")
  done

  declare -a MISSING_MACS=()
  for mac in "${REASSIGN_MACS[@]}"; do
    if [[ ! " ${FOUND_MACS[*]} " == *" ${mac} "* ]]; then
      MISSING_MACS+=("$mac")
    fi
  done

  if [[ ${#MISSING_MACS[@]} -gt 0 ]]; then
    echo >&2
    warn "WARNING: The following devices are offline or not found:" >&2
    for mac in "${MISSING_MACS[@]}"; do
      echo "  - ${mac}" >&2
    done
    warn "Proceeding with ${#FOUND_MACS[@]} device(s)..."
    echo >&2
  fi
fi

DEVICE_COUNT=$(echo "$HOSTNAMES" | wc -l | tr -d ' ')
info "Found ${DEVICE_COUNT} device(s) on network: $(echo "$HOSTNAMES" | paste -sd', ' -)"

# -- Parse config_hash and project_version from mDNS TXT records -------------
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

# -- Home Assistant registry check -------------------------------------------
# Runs immediately after discovery so it always prints, even when no devices.
# Skipped in --reassign mode: the device is still on bootstrap; HA is handled
# after production boot via iotstack.sh -> --ha-finalize <prod-hostname>.
HA_URL=""
HA_TOKEN=""

if [[ "$REASSIGN_MODE" != true ]]; then
# Home Assistant credentials come from the pass store (the secrets.yaml file
# this used to read was retired in favor of pass). Best-effort: if pass/HA is
# not configured, HA_URL/HA_TOKEN stay empty and the HA registry check below is
# simply skipped.
_UPDATE_DEVICES_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ensure-integration-secrets.sh
source "${_UPDATE_DEVICES_SCRIPT_DIR}/ensure-integration-secrets.sh"
load_ha_credentials_optional || true

if [[ -n "$HA_URL" && -n "$HA_TOKEN" ]]; then
  log "Querying Home Assistant: ${HA_URL}..."
  HA_DEVICE_LIST=$(
    HA_URL="$HA_URL" HA_TOKEN="$HA_TOKEN" HOSTNAMES="$HOSTNAMES" \
    python3 - <<'PYEOF'
import json, os, sys, ssl, re
try:
    import websocket
except ImportError:
    sys.exit(0)

ha_url = os.environ['HA_URL'].rstrip('/')
token = os.environ['HA_TOKEN']
mdns_devices = os.environ['HOSTNAMES'].strip().split('\n')

# Connect to WebSocket
ws_url = ha_url.replace('http://', 'ws://').replace('https://', 'wss://') + '/api/websocket'
import warnings
warnings.filterwarnings('ignore')

try:
    ws = websocket.create_connection(
        ws_url,
        sslopt={"cert_reqs": ssl.CERT_NONE},
        timeout=10
    )
except Exception as e:
    sys.exit(0)

msg_id = 1

# Authenticate
try:
    init_msg = json.loads(ws.recv())
    if init_msg.get('type') != 'auth_required':
        ws.close()
        sys.exit(0)
    ws.send(json.dumps({'type': 'auth', 'access_token': token}))
    auth_result = json.loads(ws.recv())
    if auth_result.get('type') != 'auth_ok':
        ws.close()
        sys.exit(0)
except Exception:
    ws.close()
    sys.exit(0)

# Get entity registry
try:
    msg_id += 1
    ws.send(json.dumps({'id': msg_id, 'type': 'config/entity_registry/list'}))
    entities_msg = json.loads(ws.recv())
    if not entities_msg.get('success'):
        ws.close()
        sys.exit(0)
    all_entities = entities_msg.get('result', [])
except Exception:
    ws.close()
    sys.exit(0)

ws.close()

# Extract MAC suffixes from mDNS devices (last 6 hex chars, e.g., c6-wifi-bleproxy-0f4df4 -> 0f4df4)
mac_to_device = {}
for dev in mdns_devices:
    m = re.search(r'([0-9a-f]{6})$', dev, re.IGNORECASE)
    if m:
        mac = m.group(1).lower()
        mac_to_device[mac] = dev

# Find ESPHome entities whose IDs contain any of these MAC suffixes
registered_devices = set()
for entity in all_entities:
    entity_id = entity.get('entity_id', '').lower()
    platform = entity.get('platform', '').lower()

    # Only check ESPHome entities
    if platform != 'esphome':
        continue

    for mac, device in mac_to_device.items():
        if mac in entity_id:
            registered_devices.add(device)
            break

for d in sorted(registered_devices):
    print(d)
PYEOF
  ) || { warn "Home Assistant query failed -- skipping registry check."; HA_DEVICE_LIST=""; }

  echo
  echo "========================================================"
  if [[ -z "$HA_DEVICE_LIST" ]]; then
    printf " %-22s  %s\n" "HA registered" "0 device(s)"
    printf " %-22s  %s\n" "Seen on network" "$(echo "$HOSTNAMES" | wc -l | tr -d ' ') device(s)"
    echo "========================================================"
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
    echo "========================================================"
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
fi

# -- Compile (with SHA256 cache to skip unnecessary builds) -------------------
# Cache key: SHA256 of the ORIGINAL YAML file + ESPHome version.
# If both match a prior successful build, skip compilation and reuse the
# stored config_hash. Invalidated by any YAML edit or ESPHome upgrade.
# Uses ORIGINAL_YAML_FILE to ignore temp file changes (OTA password embedding)
CACHE_FILE="${BASE_LOG_DIR}/${YAML_NAME}.build.cache"

YAML_SHA256=$(iotstack_yaml_cache_sha "$ORIGINAL_YAML_FILE")
ESPHOME_VERSION=$("$ESPHOME_BIN" version 2>/dev/null | grep -o '[0-9][0-9]*\.[0-9.]*' | head -1)

CACHED_YAML_SHA256=$(grep '^yaml_sha256='     "$CACHE_FILE" 2>/dev/null | cut -d= -f2 || true)
CACHED_ESPHOME_VER=$(grep '^esphome_version=' "$CACHE_FILE" 2>/dev/null | cut -d= -f2 || true)
CACHED_CONFIG_HASH=$(grep '^config_hash='     "$CACHE_FILE" 2>/dev/null | cut -d= -f2 || true)

NEW_CONFIG_HASH=""
COMPILED=false

# -- Ensure YAML has computed role_id ----------------------------------------
extract_role_name_from_yaml() {
  local yaml_file="$1"
  grep '^[[:space:]]*role_name:' "$yaml_file" \
    | sed 's/^[[:space:]]*role_name:[[:space:]]*//; s/[[:space:]]*#.*//' \
    | tr -d '"'"'" | head -1
}

compute_role_id() {
  local role_name="$1"
  echo -n "$role_name" | md5sum | cut -c1-18
}

ensure_role_id_in_yaml() {
  local yaml_file="$1"
  local role_id="$2"

  # Check if role_id already exists in the file
  if grep -q '^\s*role_id:' "$yaml_file"; then
    # Update existing role_id
    sed -i "s/^\(\s*role_id:\s*\).*/\1\"$role_id\"/" "$yaml_file"
  else
    # Add role_id after role_name
    python3 - "$yaml_file" "$role_id" <<'PYEOF'
import sys
yaml_file = sys.argv[1]
role_id = sys.argv[2]

with open(yaml_file, 'r') as f:
  lines = f.readlines()

# Find role_name line and insert role_id after it
output = []
for i, line in enumerate(lines):
  output.append(line)
  if 'role_name:' in line:
    indent = len(line) - len(line.lstrip())
    output.append(' ' * indent + f'role_id: "{role_id}"\n')

with open(yaml_file, 'w') as f:
  f.writelines(output)
PYEOF
  fi
}

if [[ "$UPGRADE_DELTA" == true || "$VERIFY" == true ]]; then
  if [[ -n "$CACHED_CONFIG_HASH" \
     && "$CACHED_YAML_SHA256" == "$YAML_SHA256" \
     && "$CACHED_ESPHOME_VER" == "$ESPHOME_VERSION" ]]; then
    log "YAML unchanged, ESPHome ${ESPHOME_VERSION} -- skipping compilation."
    NEW_CONFIG_HASH=$(_resolve_build_config_hash "$YAML_NAME" "$CACHED_CONFIG_HASH")
    _sync_build_cache_config_hash "$NEW_CONFIG_HASH"
    log "Build config_hash: ${NEW_CONFIG_HASH}"
    COMPILED=true
    setup_flash_logs "$NEW_CONFIG_HASH"
  else
    if [[ "$VERBOSE" == true || "$COMPILATION_OUTPUT" == true ]]; then
      _compile_log_banner
      info "Compiling firmware (ESPHome ${ESPHOME_VERSION})..."
      if "$ESPHOME_BIN" compile "$YAML_FILE" 2>&1 | tee -a "$COMPILE_LOG_FILE"; then
        NEW_CONFIG_HASH=$(grep -o 'config_hash=0x[0-9a-f]*' "$COMPILE_LOG_FILE" \
          | tail -1 | sed 's/config_hash=0x//')
        COMPILED=true
        # Persist cache for next run
        printf 'yaml_sha256=%s\nesphome_version=%s\nconfig_hash=%s\n' \
          "$YAML_SHA256" "$ESPHOME_VERSION" "$NEW_CONFIG_HASH" > "$CACHE_FILE"
        setup_flash_logs "$NEW_CONFIG_HASH"
        if [[ -n "$NEW_CONFIG_HASH" ]]; then ok "Build config_hash: ${NEW_CONFIG_HASH}"; fi
      else
        err "Compilation failed -- aborting."
        exit 1
      fi
    else
      COMPILE_LOG=$(mktemp)
      _compile_log_banner
      info "Compiling firmware..."

      if "$ESPHOME_BIN" compile "$YAML_FILE" >> "$COMPILE_LOG" 2>&1; then
        NEW_CONFIG_HASH=$(grep -o 'config_hash=0x[0-9a-f]*' "$COMPILE_LOG" \
          | tail -1 | sed 's/config_hash=0x//')
        COMPILED=true
        printf 'yaml_sha256=%s\nesphome_version=%s\nconfig_hash=%s\n' \
          "$YAML_SHA256" "$ESPHOME_VERSION" "$NEW_CONFIG_HASH" > "$CACHE_FILE"
        setup_flash_logs "$NEW_CONFIG_HASH"
        if [[ -n "$NEW_CONFIG_HASH" ]]; then ok "Build config_hash: ${NEW_CONFIG_HASH}"; fi
      else
        err "Compilation failed:"
        echo
        cat "$COMPILE_LOG"
        echo
        err "Full log: $COMPILE_LOG_FILE"
        exit 1
      fi
    fi
  fi
fi

# -- Reassign mode: filter to specified MACs, then proceed normally --------------
if [[ "$REASSIGN_MODE" == true ]]; then
  if [[ -z "$HOSTNAMES" ]]; then
    err "No devices found to reassign."
    exit 1
  fi

fi

# -- Per-device triage --------------------------------------------------------
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
        ok "${HOSTNAME}: hash ${DEVICE_HASH} matches"
        VERIFY_OK_LIST+=("$HOSTNAME")
      else
        err "${HOSTNAME}: hash ${DEVICE_HASH} != ${NEW_CONFIG_HASH}"
        VERIFY_FAIL_LIST+=("$HOSTNAME")
      fi
    elif [[ -n "$RUNNING_VERSION" && -n "$EXPECTED_VERSION" ]]; then
      if [[ "$RUNNING_VERSION" == "$EXPECTED_VERSION" ]]; then
        ok "${HOSTNAME}: version ${RUNNING_VERSION} matches (no hash available)"
        VERIFY_OK_LIST+=("$HOSTNAME")
      else
        err "${HOSTNAME}: version ${RUNNING_VERSION} != ${EXPECTED_VERSION} (no hash available)"
        VERIFY_FAIL_LIST+=("$HOSTNAME")
      fi
    else
      warn "${HOSTNAME}: no hash or version in mDNS TXT"
      VERIFY_UNKNOWN_LIST+=("$HOSTNAME")
    fi
    continue
  fi


  # Reassign discovers bootstrap-<mac>; its mDNS config_hash is the bootstrap
  # build, not the production image being OTA'd into the production partition.
  if [[ "$REASSIGN_MODE" == true ]]; then
    if [[ -n "$NEW_CONFIG_HASH" ]]; then
      log "${HOSTNAME}: uploading production image via bootstrap OTA (hash ${NEW_CONFIG_HASH})"
    else
      log "${HOSTNAME}: uploading production image via bootstrap OTA"
    fi
    FLASH_LIST+=("$HOSTNAME")
    continue
  fi

  # Primary: config_hash comparison (production hosts on _esphomelib._tcp)
  if [[ -n "$NEW_CONFIG_HASH" && -n "$DEVICE_HASH" ]]; then
    if [[ "$DEVICE_HASH" == "$NEW_CONFIG_HASH" ]]; then
      ok "${HOSTNAME}: hash ${DEVICE_HASH} matches -- skipping."
      SKIP_LIST+=("$HOSTNAME")
    else
      warn "${HOSTNAME}: hash ${DEVICE_HASH} -> ${NEW_CONFIG_HASH} -- will flash."
      FLASH_LIST+=("$HOSTNAME")
    fi
  # Fallback: project_version comparison (devices without config_hash in TXT)
  elif [[ -n "$RUNNING_VERSION" && -n "$EXPECTED_VERSION" ]]; then
    if [[ "$RUNNING_VERSION" == "$EXPECTED_VERSION" ]]; then
      ok "${HOSTNAME}: version ${RUNNING_VERSION} matches -- skipping."
      SKIP_LIST+=("$HOSTNAME")
    else
      warn "${HOSTNAME}: version ${RUNNING_VERSION} -> ${EXPECTED_VERSION} -- will flash."
      FLASH_LIST+=("$HOSTNAME")
    fi
  else
    warn "${HOSTNAME}: no hash or version info -- will flash."
    FLASH_LIST+=("$HOSTNAME")
  fi

done <<< "$HOSTNAMES"

# -- Verify report ------------------------------------------------------------
if [[ "$VERIFY" == true ]]; then
  echo
  echo "----------------------------------------"
  if [[ -n "$NEW_CONFIG_HASH" ]]; then info "Expected hash    : ${NEW_CONFIG_HASH}"; fi
  if [[ -n "$EXPECTED_VERSION" ]]; then info "Expected version : ${EXPECTED_VERSION}"; fi
  if [[ ${#VERIFY_OK_LIST[@]} -gt 0 ]]; then ok  "Matched  : ${VERIFY_OK_LIST[*]}"; fi
  if [[ ${#VERIFY_FAIL_LIST[@]} -gt 0 ]]; then err "Mismatch : ${VERIFY_FAIL_LIST[*]}"; fi
  if [[ ${#VERIFY_UNKNOWN_LIST[@]} -gt 0 ]]; then warn "Unknown  : ${VERIFY_UNKNOWN_LIST[*]}"; fi
  if [[ ${#VERIFY_OK_LIST[@]} -eq 0 && ${#VERIFY_FAIL_LIST[@]} -eq 0 && ${#VERIFY_UNKNOWN_LIST[@]} -eq 0 ]]; then
    warn "No devices were checked."
  fi

  if [[ ${#VERIFY_FAIL_LIST[@]} -gt 0 || ${#VERIFY_UNKNOWN_LIST[@]} -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

# -- OTA flash plan -----------------------------------------------------------
if [[ ${#FLASH_LIST[@]} -eq 0 ]]; then
  if [[ ${#OK_LIST[@]} -eq 0 && ${#FAIL_LIST[@]} -eq 0 ]]; then
    ok "All devices are up to date. Nothing to do."

    # Verify entity ID consistency even when no flashing needed
    CONSISTENCY_OUTPUT=$(verify_entity_id_consistency "$HA_URL" "$HA_TOKEN" "$YAML_FILE" "$HOSTNAMES" 2>&1)
    if [[ -n "$CONSISTENCY_OUTPUT" ]]; then
      if echo "$CONSISTENCY_OUTPUT" | grep -q "WARNING"; then
        echo "$CONSISTENCY_OUTPUT"
      else
        ok "Entity ID consistency: All entity IDs match device names"
      fi
    fi

    exit 0
  fi
  # USB was flashed; skip OTA
else
  if [[ "$DRY_RUN" == true ]]; then
    warn "Dry run -- no OTA devices will be flashed."
    exit 0
  fi
fi

# -- Compile (only if not already done above) ---------------------------------
if [[ "$COMPILED" == false ]]; then
  if [[ "$VERBOSE" == true || "$COMPILATION_OUTPUT" == true ]]; then
    _compile_log_banner
    info "Compiling firmware..."
    if ! "$ESPHOME_BIN" compile "$YAML_FILE" 2>&1 | tee -a "$COMPILE_LOG_FILE"; then
      err "Compilation failed -- aborting."
      exit 1
    fi
    NEW_CONFIG_HASH=$(grep -o 'config_hash=0x[0-9a-f]*' "$COMPILE_LOG_FILE" \
      | tail -1 | sed 's/config_hash=0x//')
    [[ -z "$NEW_CONFIG_HASH" ]] && \
      NEW_CONFIG_HASH=$(_resolve_build_config_hash "$YAML_NAME" "$CACHED_CONFIG_HASH" 2>/dev/null || true)
    [[ -n "$NEW_CONFIG_HASH" ]] && COMPILED=true
  else
    COMPILE_LOG=$(mktemp)
    _compile_log_banner
    info "Compiling firmware..."

    if "$ESPHOME_BIN" compile "$YAML_FILE" >> "$COMPILE_LOG" 2>&1; then
      NEW_CONFIG_HASH=$(grep -o 'config_hash=0x[0-9a-f]*' "$COMPILE_LOG" \
        | tail -1 | sed 's/config_hash=0x//')
      [[ -z "$NEW_CONFIG_HASH" ]] && \
        NEW_CONFIG_HASH=$(_resolve_build_config_hash "$YAML_NAME" "$CACHED_CONFIG_HASH" 2>/dev/null || true)
    else
      err "Compilation failed:"
      echo
      cat "$COMPILE_LOG"
      echo
      err "Full log: $COMPILE_LOG_FILE"
      exit 1
    fi
  fi
fi

WORK_DIR=$(mktemp -d)

# Upload config: production YAMLs omit ota: (no OTA server in firmware) but
# esphome upload requires ota: for the client. Compile uses YAML_FILE; upload
# uses UPLOAD_YAML (temp with OTA client password when --ota-password is set).
if ! _yaml_is_bootstrap "$ORIGINAL_YAML_FILE"; then
  # Must live under yamls/ so !include common/... resolves (same as bootstrap artifacts).
  OTA_UPLOAD_TEMP="$(dirname "$ORIGINAL_YAML_FILE")/.temp-ota-upload-$(basename "$ORIGINAL_YAML_FILE")"
  mkdir -p "$(dirname "$OTA_UPLOAD_TEMP")"
  create_ota_upload_yaml "$ORIGINAL_YAML_FILE" "$OTA_PASSWORD" "$OTA_UPLOAD_TEMP"
  UPLOAD_YAML="$OTA_UPLOAD_TEMP"
else
  UPLOAD_YAML="$YAML_FILE"
fi

# -- Parallel flash -----------------------------------------------------------
# Note: USB devices are NOT flashed here. Use 'iotstack flash' for serial flashing.

slot_count=0

for HOSTNAME in "${FLASH_LIST[@]}"; do
  while [[ $slot_count -ge $MAX_JOBS ]]; do
    wait -n 2>/dev/null || true
    slot_count=$((slot_count - 1))
  done

  FQDN="${HOSTNAME}.local"

  # Extract device name from ORIGINAL YAML filename (not temp file)
  # IMPORTANT: Use ORIGINAL_YAML_FILE because YAML_FILE might be a temp file with OTA password
  # Temp files are like: .temp-api-key-713092.threadrouter.yaml (wrong basename)
  # Original files are like: threadrouter.yaml (correct basename)
  DEVICE_NAME=$(basename "$ORIGINAL_YAML_FILE" .yaml)

  # Find the actual firmware binary by searching the build directory
  # ESPHome creates: <YAMLS_DIR>/.esphome/build/<name>/.pioenvs/<name>/firmware.ota.bin
  # Use YAMLS_DIR (absolute) so this works regardless of the caller's CWD.
  FIRMWARE_BIN="${YAMLS_DIR}/.esphome/build/${DEVICE_NAME}/.pioenvs/${DEVICE_NAME}/firmware.ota.bin"

  # Fallback: search for most recently created firmware.ota.bin (in case name has variables)
  if [[ ! -f "$FIRMWARE_BIN" ]]; then
    FIRMWARE_BIN=$(find "${YAMLS_DIR}/.esphome/build" -name "firmware.ota.bin" -type f -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
  fi

  (
    # Run upload with 30-second timeout (fail fast if auth fails)
    if timeout 30 "$ESPHOME_BIN" upload "$UPLOAD_YAML" --device "$FQDN" --file "$FIRMWARE_BIN"; then
      echo ok > "$WORK_DIR/${HOSTNAME}.result"
    else
      echo fail > "$WORK_DIR/${HOSTNAME}.result"
    fi
  ) > "$WORK_DIR/${HOSTNAME}.log" 2>&1 &

  slot_count=$((slot_count + 1))
done


# -- Wait for OTA jobs (progress monitor only in verbose mode) ----------------
_monitor_ota_auth_failures() {
  local hostname result_f log_f
  for hostname in "${FLASH_LIST[@]}"; do
    result_f="${WORK_DIR}/${hostname}.result"
    log_f="${WORK_DIR}/${hostname}.log"
    if [[ -f "$log_f" ]] && grep -q "Authentication invalid" "$log_f" 2>/dev/null; then
      echo fail > "$result_f"
    fi
  done
}

if [[ "$VERBOSE" == true ]]; then
  (
    elapsed=0
    declare -A auth_failed_devices
    while true; do
      sleep 4
      elapsed=$((elapsed + 4))
      parts=()
      for hostname in "${FLASH_LIST[@]}"; do
        result_f="${WORK_DIR}/${hostname}.result"
        log_f="${WORK_DIR}/${hostname}.log"

        if [[ -f "$log_f" ]] && grep -q "Authentication invalid" "$log_f" 2>/dev/null; then
          echo fail > "$result_f"
          parts+=("${RED}FAIL${RST} ${hostname} (auth failed)")
          auth_failed_devices[$hostname]=true
          continue
        fi

        if [[ -f "$result_f" ]]; then
          if [[ "$(cat "$result_f")" == ok ]]; then
            parts+=("${GRN}OK${RST} ${hostname}")
          else
            parts+=("${RED}FAIL${RST} ${hostname}")
          fi
        elif [[ -f "$log_f" ]]; then
          pct=$(grep -oE '[0-9]+(\.[0-9]+)? ?%' "$log_f" 2>/dev/null \
                | tr -d ' ' | tail -1)
          if [[ -n "$pct" ]]; then
            parts+=("${BLU}${hostname} ${pct}${RST}")
          else
            parts+=("${DIM}... ${hostname}${RST}")
          fi
        else
          parts+=("${DIM}... ${hostname} (queued)${RST}")
        fi
      done
      line=""
      for part in "${parts[@]}"; do
        [[ -n "$line" ]] && line+="   "
        line+="$part"
      done
      echo -e "${DIM}  [${elapsed}s]${RST}  ${line}"

      all_done=true
      for hostname in "${FLASH_LIST[@]}"; do
        result_f="${WORK_DIR}/${hostname}.result"
        if [[ ! -f "$result_f" ]] && [[ ! -v auth_failed_devices[$hostname] ]]; then
          all_done=false
          break
        fi
      done
      [[ "$all_done" == true ]] && break
    done
  ) &
  MONITOR_PID=$!
  wait 2>/dev/null || true
  kill "$MONITOR_PID" 2>/dev/null || true
  wait "$MONITOR_PID" 2>/dev/null || true
else
  wait 2>/dev/null || true
  _monitor_ota_auth_failures
fi

# -- Per-device flash result --------------------------------------------------
for HOSTNAME in "${FLASH_LIST[@]}"; do
  if [[ "$VERBOSE" == true ]]; then
    cat "$WORK_DIR/${HOSTNAME}.log" 2>/dev/null || true
  fi
  if [[ "$(cat "$WORK_DIR/${HOSTNAME}.result" 2>/dev/null)" == ok ]]; then
    # Show the hash of what was installed (build hash), not the pre-flash device hash.
    hash="$NEW_CONFIG_HASH"
    if [[ -z "$hash" ]]; then
      hash=$(_resolve_build_config_hash "$YAML_NAME" "$CACHED_CONFIG_HASH" 2>/dev/null || true)
    fi
    [[ -z "$hash" ]] && hash="unknown"
    hash_short="${hash:0:8}"
    ok "${HOSTNAME}: flash successful. (installed: ${hash_short})"
    OK_LIST+=("$HOSTNAME")
  else
    err "${HOSTNAME}: flash FAILED."
    FAIL_LIST+=("$HOSTNAME")

    # Check if it's an authentication error and provide guidance
    if grep -q "Authentication invalid" "$WORK_DIR/${HOSTNAME}.log" 2>/dev/null || \
       grep -q "timed out" "$WORK_DIR/${HOSTNAME}.log" 2>/dev/null; then
      echo
      echo "  [WARN] OTA Authentication Failed (Wrong OTA Password?)"
      echo
      echo "  The device rejected the OTA password. This likely means:"
      echo "  - The device is using a different OTA password than expected"
      echo "  - The device's previous password hasn't been rotated yet"
      echo
      echo "  Solution: Provide the device's CURRENT OTA password using CLI:"
      mac_suffix="${HOSTNAME##*-}"
      echo "    iotstack reassign $mac_suffix <target-role> --ota-password \"<password>\""
      echo
      echo "  Replace <password> with the OTA password currently in use on the device."
      echo
      echo "  Example:"
      echo "    iotstack reassign $mac_suffix bleproxy --ota-password \"asdpTzVteFsaegVm2pesbaYZsdwWF8\""
      echo
    fi
  fi
done

# -- Copy OTA logs to persistent log directory -------------------------------
if [[ -n "$FLASH_LOG_DIR" ]]; then
  for hostname in "${OK_LIST[@]}" "${FAIL_LIST[@]}"; do
    [[ -f "$WORK_DIR/${hostname}.log" ]] && cp "$WORK_DIR/${hostname}.log" "$FLASH_LOG_DIR/${hostname}.log" 2>/dev/null || true
  done
fi

# HA entity work for production OTA updates only (not bootstrap --reassign).
if [[ "$REASSIGN_MODE" != true ]]; then
  # Recreate entity IDs for flashed devices, or all when --force-update-entities
  if [[ "$DRY_RUN" == false ]] && { [[ ${#OK_LIST[@]} -gt 0 ]] || [[ "$FORCE_UPDATE_ENTITIES" == true ]]; }; then
    ENTITIES_TO_UPDATE=""
    if [[ "$FORCE_UPDATE_ENTITIES" == true ]]; then
      ENTITIES_TO_UPDATE="$HOSTNAMES"
    else
      ENTITIES_TO_UPDATE="$(printf '%s ' "${OK_LIST[@]}")"
    fi
    recreate_entity_ids "$HA_URL" "$HA_TOKEN" "$ENTITIES_TO_UPDATE"
  fi

  CONSISTENCY_OUTPUT=$(verify_entity_id_consistency "$HA_URL" "$HA_TOKEN" "$YAML_FILE" "$HOSTNAMES" 2>&1)
  if [[ -n "$CONSISTENCY_OUTPUT" ]]; then
    if echo "$CONSISTENCY_OUTPUT" | grep -q "WARNING"; then
      if [[ "$DRY_RUN" == true ]]; then
        warn "Entity ID inconsistencies would need fixing:"
        echo "$CONSISTENCY_OUTPUT" | grep -v "^WARNING:" | sed 's/^/  /'
      else
        echo "$CONSISTENCY_OUTPUT"
      fi
    else
      ok "Entity ID consistency: All entity IDs match device names"
    fi
  fi
fi

if [[ ${#FAIL_LIST[@]} -gt 0 ]]; then
  exit 1
fi
