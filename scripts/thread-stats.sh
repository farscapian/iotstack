#!/bin/bash
# thread-stats.sh — Gather Thread network statistics from Home Assistant
#
# Queries Home Assistant OTBR integration for Thread network info:
# - Border router status
# - Router count and details
# - Sleepy device count
# - Active thread devices by type
# - Network topology summary

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Home Assistant config from pass store (or environment)
HA_URL="${HA_URL:-}"
HA_TOKEN="${HA_TOKEN:-}"

# Cache for device list (currently unused, may be needed for future optimization)
# DEVICE_CACHE=""

#######################################
# Utility Functions
#######################################

die() {
  echo -e "${RED}✗ Error: $*${NC}" >&2
  exit 1
}

info() {
  echo -e "${BLUE}ℹ $*${NC}"
}

success() {
  echo -e "${GREEN}✓ $*${NC}"
}

warn() {
  echo -e "${YELLOW}⚠ $*${NC}"
}

debug() {
  [[ "${DEBUG:-0}" == "1" ]] && echo -e "${YELLOW}[DEBUG] $*${NC}" >&2 || true
}

#######################################
# HA Configuration
#######################################

load_ha_credentials() {
  local _thread_stats_script_dir
  _thread_stats_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=scripts/ensure-integration-secrets.sh
  source "${_thread_stats_script_dir}/ensure-integration-secrets.sh"

  if [[ -n "${HA_URL:-}" && -n "${HA_TOKEN:-}" ]]; then
    HA_URL="$(normalize_ha_url "$HA_URL")"
    validate_ha_url "$HA_URL"
    info "Testing Home Assistant WebSocket connection to ${HA_URL}..."
    local test_output=""
    if ! test_output="$(test_ha_websocket "$HA_URL" "$HA_TOKEN" 2>&1)"; then
      echo "$test_output" >&2
      if invalidate_ha_token_if_auth_failure "$test_output"; then
        die "Home Assistant access token is invalid — iotstack/common/ha_token reset to CONFIGURE_ME. Configure a new token and retry."
      fi
      die "Cannot connect to Home Assistant. Check URL, token, and network access."
    fi
    ok "Home Assistant connection verified (${test_output})"
    export HA_URL HA_TOKEN
    return 0
  fi

  ensure_ha_integration
}

#######################################
# WebSocket Communication
#######################################

query_ha_websocket() {
  local msg_type="$1"
  local extra_data="${2:-{}}"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  debug "WebSocket API: $msg_type"

  python3 "${script_dir}/ha_websocket.py" \
    --ha-url "$HA_URL" \
    --ha-token "$HA_TOKEN" \
    query --type "$msg_type" --data "$extra_data"
}

#######################################
# Thread Statistics Queries
#######################################

get_thread_devices() {
  # Get all entities related to Thread from device registry
  # Filters for OTBR integration and Thread devices

  debug "Querying thread devices..."

  local devices_json
  devices_json=$(query_ha_websocket "config/device_registry/list")

  # Filter for OTBR and Thread-related devices
  python3 << PYTHON
import json
import sys

try:
    devices = json.loads('''$devices_json''')
    thread_devices = []

    for device in devices:
        # Look for OTBR integration devices
        if any(cn.get("integration") == "otbr" for cn in device.get("config_entries", [])):
            thread_devices.append(device)
        # Also look for Thread labels
        elif "thread" in device.get("name", "").lower():
            thread_devices.append(device)

    print(json.dumps(thread_devices, indent=2))
except json.JSONDecodeError:
    print("[]")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    print("[]")
PYTHON
}

get_otbr_status() {
  # Get OTBR (OpenThread Border Router) status
  debug "Querying OTBR status..."

  local otbr_status
  otbr_status=$(query_ha_websocket "otbr/info" 2>/dev/null || echo "{}")

  echo "$otbr_status"
}

get_thread_entities() {
  # Query all entities from Thread-related devices
  debug "Querying thread entities..."

  local entities_json
  entities_json=$(query_ha_websocket "get_states")

  python3 << PYTHON
import json
import sys

try:
    entities = json.loads('''$entities_json''')

    thread_entities = {
        "routers": [],
        "sleepy_devices": [],
        "coordinators": [],
        "end_devices": [],
        "other": []
    }

    for entity_id, entity in entities.items():
        # Skip non-thread entities
        if "thread" not in entity_id.lower() and "otbr" not in entity_id.lower():
            continue

        state = entity.get("state", "unknown")
        attrs = entity.get("attributes", {})
        device_type = attrs.get("device_type", "unknown")

        # Categorize by device type
        if "router" in device_type.lower() or "router" in entity_id.lower():
            thread_entities["routers"].append({
                "entity_id": entity_id,
                "state": state,
                "device_type": device_type
            })
        elif "sleepy" in device_type.lower() or "sleepy" in entity_id.lower():
            thread_entities["sleepy_devices"].append({
                "entity_id": entity_id,
                "state": state,
                "device_type": device_type
            })
        elif "coordinator" in device_type.lower():
            thread_entities["coordinators"].append({
                "entity_id": entity_id,
                "state": state,
                "device_type": device_type
            })
        elif "end_device" in device_type.lower():
            thread_entities["end_devices"].append({
                "entity_id": entity_id,
                "state": state,
                "device_type": device_type
            })
        else:
            thread_entities["other"].append({
                "entity_id": entity_id,
                "state": state,
                "device_type": device_type
            })

    print(json.dumps(thread_entities, indent=2))
except json.JSONDecodeError:
    print("{}")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    print("{}")
PYTHON
}

#######################################
# Statistics Display
#######################################

show_thread_stats() {
  echo ""
  echo -e "${BLUE}╔═══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║          Thread Network Statistics                    ║${NC}"
  echo -e "${BLUE}╚═══════════════════════════════════════════════════════╝${NC}"
  echo ""

  # Get device data
  info "Fetching thread network data from Home Assistant..."

  local thread_entities
  thread_entities=$(get_thread_entities)

  debug "Entities: $thread_entities"

  # Parse and display stats
  local router_count
  local sleepy_count
  local coordinator_count
  local end_device_count
  local other_count

  router_count=$(echo "$thread_entities" | python3 -c "import json, sys; data = json.load(sys.stdin); print(len(data.get('routers', [])))" 2>/dev/null || echo "0")
  sleepy_count=$(echo "$thread_entities" | python3 -c "import json, sys; data = json.load(sys.stdin); print(len(data.get('sleepy_devices', [])))" 2>/dev/null || echo "0")
  coordinator_count=$(echo "$thread_entities" | python3 -c "import json, sys; data = json.load(sys.stdin); print(len(data.get('coordinators', [])))" 2>/dev/null || echo "0")
  end_device_count=$(echo "$thread_entities" | python3 -c "import json, sys; data = json.load(sys.stdin); print(len(data.get('end_devices', [])))" 2>/dev/null || echo "0")
  other_count=$(echo "$thread_entities" | python3 -c "import json, sys; data = json.load(sys.stdin); print(len(data.get('other', [])))" 2>/dev/null || echo "0")

  # Summary stats
  echo -e "${YELLOW}Thread Network Summary:${NC}"
  echo "  Thread Routers:        $router_count"
  echo "  Sleepy Devices:        $sleepy_count"
  echo "  Coordinators:          $coordinator_count"
  echo "  End Devices:           $end_device_count"
  echo "  Other:                 $other_count"
  echo ""

  local total=$((router_count + sleepy_count + coordinator_count + end_device_count + other_count))
  if [[ $total -gt 0 ]]; then
    echo -e "${GREEN}Total Thread Devices: $total${NC}"
  else
    echo -e "${YELLOW}No Thread devices found${NC}"
  fi

  echo ""

  # Show router details
  if [[ $router_count -gt 0 ]]; then
    echo -e "${YELLOW}Thread Routers:${NC}"
    python3 << PYTHON
import json, sys
data = json.loads('''$thread_entities''')
for router in data.get("routers", []):
    print(f"  • {router['entity_id']}: {router['state']}")
PYTHON
    echo ""
  fi

  # Show sleepy devices
  if [[ $sleepy_count -gt 0 ]]; then
    echo -e "${YELLOW}Sleepy Devices:${NC}"
    python3 << PYTHON
import json, sys
data = json.loads('''$thread_entities''')
for device in data.get("sleepy_devices", []):
    print(f"  • {device['entity_id']}: {device['state']}")
PYTHON
    echo ""
  fi

  # OTBR status
  info "OTBR Status:"
  query_ha_websocket "otbr/info" | python3 -m json.tool 2>/dev/null | sed 's/^/  /' || warn "OTBR WebSocket endpoint not available"

  echo ""
}

#######################################
# Main
#######################################

main() {
  # Parse arguments
  case "${1:-}" in
    --help | -h)
      cat << EOF
Usage: thread-stats.sh [OPTIONS]

Query Thread network statistics from Home Assistant.

OPTIONS:
  --help, -h       Show this help message
  --verbose, -v    Enable verbose output
  --debug          Enable debug output
  --ha-url URL     Home Assistant URL (default: http://homeassistant.local:8123)
  --ha-token TOKEN Home Assistant API token

EXAMPLES:
  thread-stats.sh
  HA_TOKEN="your_token" thread-stats.sh --ha-url http://192.168.1.100:8123
  thread-stats.sh --debug

CONFIGURATION:
  Load credentials from pass store:
    pass insert iotstack/common/ha_url
    pass insert iotstack/common/ha_token

  Or set environment variables:
    export HA_URL="http://homeassistant.local:8123"
    export HA_TOKEN="your_long_lived_token"

REQUIREMENTS:
  - python3 websocket-client (pip3 install websocket-client)
  - Home Assistant with OTBR integration configured

EOF
      exit 0
      ;;
    --verbose | -v)
      DEBUG=1
      ;;
    --debug)
      DEBUG=1
      set -x
      ;;
    --ha-url)
      HA_URL="$2"
      shift 2
      ;;
    --ha-token)
      HA_TOKEN="$2"
      shift 2
      ;;
    --*)
      die "Unknown option: $1"
      ;;
  esac

  # Load credentials
  load_ha_credentials

  python3 -c "import websocket" 2>/dev/null \
    || die "python3 websocket-client is required (pip3 install websocket-client)"

  # Show statistics
  show_thread_stats
}

# Run main
main "$@"
