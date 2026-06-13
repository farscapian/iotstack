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

# Cache for device list
DEVICE_CACHE=""

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
  # Try to load from pass store if available
  if command -v pass &>/dev/null; then
    if pass iotstack/common/ha_url &>/dev/null; then
      HA_URL="$(pass show iotstack/common/ha_url 2>/dev/null || echo "")"
      debug "Loaded HA_URL from pass: $HA_URL"
    fi
    if pass iotstack/common/ha_token &>/dev/null; then
      HA_TOKEN="$(pass show iotstack/common/ha_token 2>/dev/null || echo "")"
      debug "Loaded HA_TOKEN from pass"
    fi
  fi

  # Fallback: check environment variables
  if [[ -z "$HA_URL" ]]; then
    HA_URL="${HA_URL:-http://homeassistant.local:8123}"
  fi

  if [[ -z "$HA_TOKEN" ]]; then
    die "Home Assistant token not found. Set HA_TOKEN environment variable or store in pass at iotstack/common/ha_token"
  fi

  debug "HA_URL: $HA_URL"
  debug "HA_TOKEN: (set)"
}

#######################################
# WebSocket Communication
#######################################

query_ha_websocket() {
  local endpoint="$1"
  local query="$2"

  # Extract host and path from URL
  local ha_host
  local ha_port

  if [[ "$HA_URL" =~ ^https?://([^/:]+)(:([0-9]+))?(/.*)$ ]]; then
    ha_host="${BASH_REMATCH[1]}"
    ha_port="${BASH_REMATCH[3]:-8123}"
    local ha_path="${BASH_REMATCH[4]}"
  else
    die "Invalid HA_URL format: $HA_URL"
  fi

  debug "Connecting to $ha_host:$ha_port$ha_path"

  # Use Python for WebSocket communication (more reliable than bash)
  python3 << PYTHON
import json
import websocket
import sys

try:
    ws_url = "ws://${ha_host}:${ha_port}/api/websocket"
    ws = websocket.create_connection(ws_url, timeout=5)

    # Authenticate
    auth_msg = json.dumps({"type": "auth", "access_token": "${HA_TOKEN}"})
    ws.send(auth_msg)
    auth_resp = json.loads(ws.recv())

    if auth_resp.get("type") != "auth_ok":
        print("Authentication failed", file=sys.stderr)
        sys.exit(1)

    # Send query
    msg_id = 1
    query_msg = json.dumps({
        "id": msg_id,
        "type": "call_service",
        "domain": "${domain:-homeassistant}",
        "service": "${service:-get_entities}",
        **${query}
    })
    ws.send(query_msg)

    # Receive response
    response = json.loads(ws.recv())
    print(json.dumps(response, indent=2))

    ws.close()
except Exception as e:
    print(f"WebSocket error: {e}", file=sys.stderr)
    sys.exit(1)
PYTHON
}

query_ha_rest() {
  local endpoint="$1"
  local method="${2:-GET}"

  debug "REST API: $method $endpoint"

  curl -s -X "$method" \
    -H "Authorization: Bearer $HA_TOKEN" \
    -H "Content-Type: application/json" \
    "$HA_URL/api/$endpoint"
}

#######################################
# Thread Statistics Queries
#######################################

get_thread_devices() {
  # Get all entities related to Thread from device registry
  # Filters for OTBR integration and Thread devices

  debug "Querying thread devices..."

  # Use REST API to get device list (simpler than WebSocket for this)
  local devices_json
  devices_json=$(query_ha_rest "config/device_registry/list" "GET")

  # Filter for OTBR and Thread-related devices
  echo "$devices_json" | python3 << PYTHON
import json
import sys

try:
    devices = json.load(sys.stdin)
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
  otbr_status=$(query_ha_rest "openthread_border_router" "GET" 2>/dev/null || echo "{}")

  echo "$otbr_status"
}

get_thread_entities() {
  # Query all entities from Thread-related devices
  debug "Querying thread entities..."

  local entities_json
  entities_json=$(query_ha_rest "states" "GET")

  echo "$entities_json" | python3 << PYTHON
import json
import sys

try:
    entities = json.load(sys.stdin)

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
    echo "$thread_entities" | python3 << PYTHON
import json, sys
data = json.load(sys.stdin)
for router in data.get("routers", []):
    print(f"  • {router['entity_id']}: {router['state']}")
PYTHON
    echo ""
  fi

  # Show sleepy devices
  if [[ $sleepy_count -gt 0 ]]; then
    echo -e "${YELLOW}Sleepy Devices:${NC}"
    echo "$thread_entities" | python3 << PYTHON
import json, sys
data = json.load(sys.stdin)
for device in data.get("sleepy_devices", []):
    print(f"  • {device['entity_id']}: {device['state']}")
PYTHON
    echo ""
  fi

  # OTBR status
  info "OTBR Status:"
  query_ha_rest "openthread_border_router" "GET" | python3 -m json.tool 2>/dev/null | sed 's/^/  /' || warn "OTBR endpoint not available"

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
  - curl (for REST API queries)
  - python3-websocket (optional, for WebSocket queries)
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

  # Verify curl is available
  command -v curl &>/dev/null || die "curl is required but not installed"

  # Show statistics
  show_thread_stats
}

# Run main
main "$@"
