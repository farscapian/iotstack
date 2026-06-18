#!/bin/bash
# yaml-info.sh -- Introspect ESPHome YAML files (variant, board, network)
#
# Requires config.sh to be sourced first.

[[ -n "${_YAML_INFO_LOADED:-}" ]] && return 0
_YAML_INFO_LOADED=1

yaml_device_info() {
  local yaml_file="$1"
  local board="" variant="" network_type="" dev_status=""

  if [[ -f "$yaml_file" ]]; then
    board=$(grep -A5 '^esp32:' "$yaml_file" | grep -E '^\s*board:\s*' | head -1 | sed 's/.*board:\s*//; s/\s*$//')
    variant=$(grep -A5 '^esp32:' "$yaml_file" | grep -E '^\s*variant:\s*' | head -1 | sed 's/.*variant:\s*//; s/\s*$//')
    dev_status=$(grep -E '^\s*development_status:\s*' "$yaml_file" | head -1 | sed 's/.*development_status:\s*//; s/"//g; s/\s*$//')
    if grep -q '^wifi:' "$yaml_file" 2>/dev/null; then
      network_type=wifi
    elif grep -q '^openthread:' "$yaml_file" 2>/dev/null; then
      network_type=thread
    fi
  fi

  printf '%s|%s|%s|%s' "$board" "$variant" "$network_type" "$dev_status"
}

yaml_path_for_role() {
  local role="$1"
  local yaml_rel=""
  yaml_rel=$(grep -m1 "^${role}=" "$ROLES_CONF" 2>/dev/null | cut -d= -f2-)
  [[ -z "$yaml_rel" ]] && return 1
  if [[ "$yaml_rel" = /* ]]; then
    printf '%s\n' "$yaml_rel"
  else
    printf '%s\n' "${PROJECT_ROOT}/${yaml_rel}"
  fi
}

yaml_variant_for_role() {
  local role="$1"
  local yaml_file info
  yaml_file=$(yaml_path_for_role "$role") || return 1
  info=$(yaml_device_info "$yaml_file")
  printf '%s\n' "$info" | cut -d'|' -f2
}

yaml_variant_for_bootstrap() {
  local yaml_file info
  yaml_file="$(iotstack_bootstrap_template_path)"
  if [[ -f "$yaml_file" ]]; then
    info=$(yaml_device_info "$yaml_file")
    printf '%s\n' "$info" | cut -d'|' -f2
    return 0
  fi
  printf '%s\n' esp32c6
}

yaml_resolve_value() {
  # Expand ${substitution} references using the YAML substitutions: block.
  local yaml_file="$1"
  local value="$2"
  declare -A subs=()
  local line key val k

  while IFS= read -r line; do
    key=$(echo "$line" | sed 's/:.*//' | tr -d ' ')
    val=$(echo "$line" | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '"')
    [[ -n "$key" ]] && subs["$key"]="$val"
  done < <(awk '/^substitutions:/{found=1; next} found && /^[^ \t]/{exit} found{print}' "$yaml_file" \
    | grep -v '^\s*$')

  for k in "${!subs[@]}"; do
    value="${value//\$\{$k\}/${subs[$k]}}"
  done
  printf '%s' "$value"
}

yaml_friendly_name_from_file() {
  # Resolved human-friendly device name (before slugification).
  # ESPHome entity IDs come from esphome.friendly_name (often ${friendly_name}).
  local yaml_file="$1"
  local friendly=""

  friendly=$(awk '/^esphome:/{found=1; next} found && /^[^ \t]/{exit} found && /friendly_name:/{print; exit}' "$yaml_file" \
    | sed 's/.*friendly_name:[[:space:]]*//' | tr -d '"')
  if [[ -z "$friendly" ]]; then
    friendly=$(awk '/^substitutions:/{found=1; next} found && /^[^ \t]/{exit} found && /friendly_name:/{print; exit}' "$yaml_file" \
      | sed 's/.*friendly_name:[[:space:]]*//' | tr -d '"')
  fi
  friendly=$(yaml_resolve_value "$yaml_file" "$friendly")
  if [[ -z "$friendly" || "$friendly" =~ \$\{ ]]; then
    friendly=$(awk '/^esphome:/{found=1; next} found && /^\s+name:/{print; found=0}' "$yaml_file" \
      | sed 's/.*name:[[:space:]]*//' | tr -d '"')
    friendly=$(yaml_resolve_value "$yaml_file" "$friendly")
  fi
  [[ -n "$friendly" && ! "$friendly" =~ \$\{ ]] || return 1
  printf '%s\n' "$friendly"
}

yaml_entity_slug_from_file() {
  # Slugified friendly_name -- ESPHome/HA entity ID prefix (e.g. bluetooth_proxy).
  local yaml_file="$1"
  local friendly
  friendly=$(yaml_friendly_name_from_file "$yaml_file") || return 1
  echo "$friendly" | tr '[:upper:]' '[:lower:]' | tr ' -' '__' | sed -E 's/_+/_/g; s/^_|_$//g'
}

yaml_mdns_name_for_role() {
  # ESPHome hostname prefix (before MAC suffix) used for mDNS / devices filtering.
  local role="$1"
  local yaml_file name
  yaml_file=$(yaml_path_for_role "$role") || return 1
  name=$(grep -A15 '^esphome:' "$yaml_file" | grep -E '^\s*name:\s*' | head -1 | sed 's/.*name:\s*//; s/\s*$//; s/"//g')
  name=$(yaml_resolve_value "$yaml_file" "$name")
  [[ -n "$name" ]] || return 1
  printf '%s\n' "$name"
}