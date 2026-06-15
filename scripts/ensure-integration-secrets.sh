#!/usr/bin/env bash
# ensure-integration-secrets.sh
# Prompt for, validate, and load Home Assistant and Thread TLV credentials.
#
# Source this script to use its functions, or invoke directly:
#   ./ensure-integration-secrets.sh --ha [--thread] [--thread-optional]
#   ./ensure-integration-secrets.sh --load-ha
#
# Exports: HA_URL, HA_TOKEN, THREAD_TLV (when applicable)

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/config.sh
source "${_SCRIPT_DIR}/config.sh"

export GNUPGHOME
export PASSWORD_STORE_DIR

PLACEHOLDER_VALUE="CONFIGURE_ME"

# Avoid re-defining helpers when sourced multiple times.
if [[ -z "${_IOTSTACK_ENSURE_SECRETS_LOADED:-}" ]]; then
  _IOTSTACK_ENSURE_SECRETS_LOADED=1

  RED=$'\033[0;31m'
  GRN=$'\033[0;32m'
  YLW=$'\033[0;33m'
  BLU=$'\033[0;34m'
  RST=$'\033[0m'

  err()  { echo -e "${RED}[ERROR]${RST} $*" >&2; exit 1; }
  ok()   { echo -e "${GRN}[OK]${RST} $*" >&2; }
  info() { echo -e "${BLU}[INFO]${RST} $*" >&2; }
  warn() { echo -e "${YLW}[WARN]${RST} $*" >&2; }

  is_unconfigured() {
    local value="${1:-}"
    value="$(printf '%s' "$value" | xargs)"
    [[ -z "$value" || "$value" == "$PLACEHOLDER_VALUE" ]]
  }

  get_pass_secret() {
    pass show "$1" 2>/dev/null | head -n1 || true
  }

  store_pass_secret() {
    local pass_path="$1"
    local value="$2"
    { echo "$value"; echo "$value"; } | pass insert -f "$pass_path" >/dev/null 2>&1 \
      || err "Failed to store credential in pass: $pass_path"
  }

  prompt_value() {
    local prompt_text="$1"
    local is_secret="${2:-false}"
    local value=""

    echo "" >&2
    echo -ne "${YLW}[PROMPT]${RST} ${prompt_text}: " >&2
    if [[ "$is_secret" == "true" ]]; then
      read -rs value </dev/tty 2>/dev/null || value=""
      echo >&2
    else
      read -r value </dev/tty 2>/dev/null || value=""
    fi
    printf '%s' "$value" | xargs
  }

  ensure_pass_secret() {
    local pass_path="$1"
    local prompt_text="$2"
    local is_secret="${3:-false}"
    local required="${4:-true}"

    local value
    value="$(get_pass_secret "$pass_path")"

    if is_unconfigured "$value"; then
      value="$(prompt_value "$prompt_text" "$is_secret")"
      if [[ -z "$value" ]]; then
        if [[ "$required" == "true" ]]; then
          err "Credential required: $pass_path"
        fi
        echo ""
        return 0
      fi
      if [[ "$pass_path" == "iotstack/common/ha_url" ]]; then
        value="$(normalize_ha_url "$value")"
        validate_ha_url "$value"
      fi
      store_pass_secret "$pass_path" "$value"
      info "Stored credential: $pass_path"
    fi

    echo "$value"
  }

  normalize_ha_url() {
    local url="$1"
    url="$(printf '%s' "$url" | xargs)"
    url="${url%/}"

    # Accept common bare host:port input (e.g. homeassistant.local:8123).
    if [[ ! "$url" =~ ^https?:// ]]; then
      if [[ "$url" =~ ^(localhost|127\.0\.0\.1)(:|/|$) ]]; then
        url="http://${url}"
      else
        url="https://${url}"
      fi
    fi

    # Base URL only — strip any path the user may have pasted.
    if [[ "$url" =~ ^(https?://[^/?#]+) ]]; then
      url="${BASH_REMATCH[1]}"
    fi

    printf '%s' "$url"
  }

  validate_ha_url() {
    local url="$1"
    if [[ ! "$url" =~ ^https?://[^/[:space:]]+ ]]; then
      err "Invalid Home Assistant URL: $url (expected host:8123 or http(s)://host:8123)"
    fi
  }

  ha_url_to_ws_url() {
    local ha_url="$1"
    local ws_url="${ha_url//http:\/\//ws://}"
    ws_url="${ws_url//https:\/\//wss://}"
    printf '%s/api/websocket' "$ws_url"
  }

  test_ha_websocket() {
    local ha_url="$1"
    local ha_token="$2"
    python3 "${_SCRIPT_DIR}/ha_websocket.py" \
      --ha-url "$ha_url" \
      --ha-token "$ha_token" \
      auth-test
  }

  ha_websocket_query() {
    local msg_type="$1"
    local extra_data="${2:-{}}"
    python3 "${_SCRIPT_DIR}/ha_websocket.py" \
      --ha-url "$HA_URL" \
      --ha-token "$HA_TOKEN" \
      query --type "$msg_type" --data "$extra_data"
  }

  ha_websocket_call_service() {
    local domain="$1"
    local service="$2"
    local service_data="${3:-{}}"
    local target="${4:-}"
    local args=(
      --ha-url "$HA_URL"
      --ha-token "$HA_TOKEN"
      call-service "$domain" "$service"
      --data "$service_data"
    )
    if [[ -n "$target" ]]; then
      args+=(--target "$target")
    fi
    python3 "${_SCRIPT_DIR}/ha_websocket.py" "${args[@]}"
  }

  load_ha_credentials_optional() {
    HA_URL="$(get_pass_secret "iotstack/common/ha_url")"
    HA_TOKEN="$(get_pass_secret "iotstack/common/ha_token")"

    if is_unconfigured "$HA_URL"; then
      HA_URL=""
    else
      HA_URL="$(normalize_ha_url "$HA_URL")"
    fi

    if is_unconfigured "$HA_TOKEN"; then
      HA_TOKEN=""
    fi

    export HA_URL HA_TOKEN

    if [[ -n "$HA_URL" && -n "$HA_TOKEN" ]]; then
      return 0
    fi
    return 1
  }

  ensure_ha_integration() {
    local skip_test="${1:-false}"

    command -v pass &>/dev/null || err "pass is required but not installed"

    HA_URL="$(ensure_pass_secret \
      "iotstack/common/ha_url" \
      "Home Assistant URL (e.g. homeassistant.local:8123)" \
      "false" \
      "true")"
    HA_TOKEN="$(ensure_pass_secret \
      "iotstack/common/ha_token" \
      "Home Assistant long-lived access token" \
      "true" \
      "true")"

    HA_URL="$(normalize_ha_url "$HA_URL")"
    validate_ha_url "$HA_URL"

    if [[ "$skip_test" != "true" ]]; then
      info "Testing Home Assistant WebSocket connection to ${HA_URL}..."
      local test_output=""
      if ! test_output="$(test_ha_websocket "$HA_URL" "$HA_TOKEN" 2>&1)"; then
        echo "$test_output" >&2
        err "Cannot connect to Home Assistant. Check URL, token, and network access."
      fi
      ok "Home Assistant connection verified (${test_output})"
    fi

    export HA_URL HA_TOKEN
  }

  ensure_thread_tlv() {
    local optional="${1:-false}"
    local required="true"
    local prompt="Thread operational dataset TLV (hex string from HA Settings → Thread)"

    if [[ "$optional" == "true" ]]; then
      required="false"
      prompt="Thread operational dataset TLV (optional, press Enter to skip)"
    fi

    command -v pass &>/dev/null || err "pass is required but not installed"

    THREAD_TLV="$(ensure_pass_secret \
      "iotstack/common/thread_tlv" \
      "$prompt" \
      "true" \
      "$required")"

    if [[ "$optional" != "true" && -z "$THREAD_TLV" ]]; then
      err "Thread TLV is required"
    fi

    export THREAD_TLV
  }
fi

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Ensure iotstack integration credentials are configured in pass.

Options:
  --ha               Prompt for HA URL/token if missing; verify WebSocket access
  --thread           Prompt for Thread TLV if missing (required)
  --thread-optional  Prompt for Thread TLV; allow skip
  --load-ha          Load HA credentials without prompting (optional integration)
  -h, --help         Show this help

Examples:
  $(basename "$0") --ha --thread
  $(basename "$0") --load-ha
EOF
}

main() {
  local require_ha=false
  local require_thread=false
  local thread_optional=false
  local load_ha_only=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ha)
        require_ha=true
        ;;
      --thread)
        require_thread=true
        ;;
      --thread-optional)
        thread_optional=true
        ;;
      --load-ha)
        load_ha_only=true
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        err "Unknown option: $1"
        ;;
    esac
    shift
  done

  if [[ "$load_ha_only" == "true" ]]; then
    load_ha_credentials_optional || return 1
    return 0
  fi

  if [[ "$require_ha" != "true" && "$require_thread" != "true" && "$thread_optional" != "true" ]]; then
    usage >&2
    return 1
  fi

  if [[ "$require_ha" == "true" ]]; then
    ensure_ha_integration
  fi

  if [[ "$require_thread" == "true" ]]; then
    ensure_thread_tlv "false"
  elif [[ "$thread_optional" == "true" ]]; then
    ensure_thread_tlv "true"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi