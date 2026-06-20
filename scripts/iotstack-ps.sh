#!/bin/bash
# iotstack-ps.sh -- List process trees for running iotstack sessions
#
# Requires config.sh (SCRIPT_DIR) and esp-serial.sh helpers.

[[ -n "${_IOTSTACK_PS_LOADED:-}" ]] && return 0
_IOTSTACK_PS_LOADED=1

# shellcheck source=scripts/esp-serial.sh
source "${SCRIPTS_DIR}/esp-serial.sh"

_iotstack_ps_is_ps_command() {
  local cmdline="$1"
  [[ "$cmdline" == *"iotstack ps"* || "$cmdline" == *"iotstack.sh ps"* ]]
}

_iotstack_ps_skip_pid() {
  local pid="$1"
  local cmdline

  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0
  [[ "$pid" -eq "$$" ]] && return 0
  esp_serial_pid_in_tree "$$" "$pid" && return 0

  cmdline=$(esp_serial_process_cmdline "$pid")
  [[ -z "$cmdline" ]] && return 0
  _iotstack_ps_is_ps_command "$cmdline" && return 0
  return 1
}

_iotstack_ps_collect_invocation_pids() {
  local pid cmdline

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    _iotstack_ps_skip_pid "$pid" && continue
    cmdline=$(esp_serial_process_cmdline "$pid")
    [[ -z "$cmdline" ]] && continue
    esp_serial_is_iotstack_flash_invocation "$cmdline" || continue
    printf '%s\n' "$pid"
  done < <(pgrep -f '(/iotstack\.sh|/iotstack) ' 2>/dev/null || true)
}

_iotstack_ps_root_pids() {
  local -a invocations=()
  local pid ppid parent_cmd

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    invocations+=("$pid")
  done < <(_iotstack_ps_collect_invocation_pids)

  for pid in "${invocations[@]}"; do
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$ppid" ]] && continue
    parent_cmd=$(esp_serial_process_cmdline "$ppid")
    if [[ -n "$parent_cmd" ]] && esp_serial_is_iotstack_flash_invocation "$parent_cmd"; then
      continue
    fi
    printf '%s\n' "$pid"
  done
}

_iotstack_ps_pid_in_any_root() {
  local check_pid="$1"
  shift
  local root

  for root in "$@"; do
    [[ -z "$root" ]] && continue
    [[ "$check_pid" -eq "$root" ]] && return 0
    esp_serial_pid_in_tree "$root" "$check_pid" && return 0
  done
  return 1
}

_iotstack_ps_collect_helper_pids() {
  local pid cmdline

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    _iotstack_ps_skip_pid "$pid" && continue
    cmdline=$(esp_serial_process_cmdline "$pid")
    [[ -z "$cmdline" ]] && continue
    if [[ "$cmdline" == *"/scripts/serial-logs.py"* ]] \
      || [[ "$cmdline" == *"/scripts/log-stamp.py"* && "$cmdline" == *"serial:"* ]] \
      || [[ "$cmdline" == *"/scripts/update_devices.sh"* ]] \
      || [[ "$cmdline" == *" -m esptool"* || "$cmdline" == *" -u -m esptool"* ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(pgrep -f 'serial-logs\.py|log-stamp\.py|update_devices\.sh| -m esptool' 2>/dev/null || true)
}

_iotstack_ps_helper_label() {
  local cmdline="$1"
  if [[ "$cmdline" == *"serial-logs.py"* ]]; then
    printf 'serial capture'
  elif [[ "$cmdline" == *"log-stamp.py"* ]]; then
    printf 'serial log stamp'
  elif [[ "$cmdline" == *"update_devices.sh"* ]]; then
    printf 'update_devices'
  elif [[ "$cmdline" == *"esptool"* ]]; then
    printf 'esptool'
  else
    printf 'helper'
  fi
}

_iotstack_ps_print_tree() {
  local pid="$1"
  local pgid

  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  if command -v pstree &>/dev/null; then
    pstree -ap "$pid" 2>/dev/null \
      || ps --forest -o pid=,ppid=,args= -g "${pgid:-$pid}" 2>/dev/null
  else
    ps --forest -o pid=,ppid=,args= -g "${pgid:-$pid}" 2>/dev/null
  fi
}

_iotstack_ps_print_session() {
  local pid="$1"
  local title="$2"
  local cmdline pgid

  cmdline=$(esp_serial_process_cmdline "$pid")
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')

  echo ""
  echo "${BLU}[INFO]${RST} ${title} pid ${pid} pgid ${pgid:-?}"
  [[ -n "$cmdline" ]] && echo "  cmd: $cmdline"
  _iotstack_ps_print_tree "$pid"
}

_iotstack_ps_collect_sessions() {
  # Populate caller arrays: roots (session leaders) and helpers (detached group leaders).
  local -n _roots_ref="$1"
  local -n _helpers_ref="$2"
  local pid cmdline label pgid
  local -A seen_helpers=()

  _roots_ref=()
  _helpers_ref=()

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    _roots_ref+=("$pid")
  done < <(_iotstack_ps_root_pids | sort -n -u)

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    _iotstack_ps_pid_in_any_root "$pid" "${_roots_ref[@]}" && continue
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -n "$pgid" && "$pid" -ne "$pgid" ]] && continue
    [[ -n "${seen_helpers[$pid]:-}" ]] && continue
    seen_helpers[$pid]=1
    _helpers_ref+=("$pid")
  done < <(_iotstack_ps_collect_helper_pids | sort -n -u)
}

_iotstack_ps_pgid_alive() {
  local pgid="$1"

  [[ -n "$pgid" && "$pgid" =~ ^[0-9]+$ ]] || return 1
  pgrep -g "$pgid" >/dev/null 2>&1
}

_iotstack_ps_resume_stopped_group() {
  local pgid="$1"
  local pid state

  [[ -n "$pgid" && "$pgid" =~ ^[0-9]+$ ]] || return 0
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    state=$(ps -p "$pid" -o stat= 2>/dev/null | tr -d ' ' || true)
    [[ "$state" == *T* ]] && kill -CONT "$pid" 2>/dev/null || true
  done < <(pgrep -g "$pgid" 2>/dev/null || true)
}

_iotstack_ps_kill_group() {
  local pid="$1"
  local label="$2"
  local pgid cmdline i

  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0

  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ -z "$pgid" ]] && return 1

  cmdline=$(esp_serial_process_cmdline "$pid")
  info "Stopping ${label} pid ${pid} pgid ${pgid}"
  [[ -n "$cmdline" ]] && echo "  cmd: $cmdline"

  _iotstack_ps_resume_stopped_group "$pgid"
  kill -TERM -"$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for i in 1 2 3 4 5 6; do
    _iotstack_ps_pgid_alive "$pgid" || {
      ok "Stopped ${label} (pgid ${pgid})"
      return 0
    }
    sleep 0.5
  done

  warn "Sending SIGKILL to pgid ${pgid}..."
  _iotstack_ps_resume_stopped_group "$pgid"
  kill -KILL -"$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  esp_serial_kill_process_tree "$pid"
  sleep 0.2
  if _iotstack_ps_pgid_alive "$pgid"; then
    warn "${label} pgid ${pgid} may still be running"
    return 1
  fi
  ok "Stopped ${label} (pgid ${pgid})"
}

iotstack_ps() {
  local -a roots=() helpers=()
  local pid cmdline label

  _iotstack_ps_collect_sessions roots helpers

  if [[ ${#roots[@]} -eq 0 ]]; then
    info "No iotstack command sessions running."
  else
    info "${#roots[@]} iotstack command session(s) running:"
    for pid in "${roots[@]}"; do
      _iotstack_ps_print_session "$pid" "session"
    done
  fi

  if [[ ${#helpers[@]} -gt 0 ]]; then
    info "${#helpers[@]} detached iotstack helper process tree(s):"
    for pid in "${helpers[@]}"; do
      cmdline=$(esp_serial_process_cmdline "$pid")
      label=$(_iotstack_ps_helper_label "$cmdline")
      _iotstack_ps_print_session "$pid" "detached ${label}"
    done
  fi

  if [[ ${#roots[@]} -eq 0 && ${#helpers[@]} -eq 0 ]]; then
    return 0
  fi

  echo ""
  info "Stop all: iotstack ps kill"
}

iotstack_ps_kill() {
  local -a roots=() helpers=()
  local pid cmdline label failures=0

  _iotstack_ps_collect_sessions roots helpers

  if [[ ${#roots[@]} -eq 0 && ${#helpers[@]} -eq 0 ]]; then
    ok "No iotstack processes to stop."
    return 0
  fi

  info "Stopping ${#roots[@]} iotstack session(s) and ${#helpers[@]} detached helper tree(s)..."

  for pid in "${roots[@]}"; do
    _iotstack_ps_kill_group "$pid" "session" || failures=$((failures + 1))
  done

  for pid in "${helpers[@]}"; do
    cmdline=$(esp_serial_process_cmdline "$pid")
    label=$(_iotstack_ps_helper_label "$cmdline")
    _iotstack_ps_kill_group "$pid" "detached ${label}" || failures=$((failures + 1))
  done

  roots=()
  helpers=()
  _iotstack_ps_collect_sessions roots helpers
  if [[ ${#roots[@]} -eq 0 && ${#helpers[@]} -eq 0 ]]; then
    ok "All iotstack processes stopped."
    return 0
  fi

  warn "${#roots[@]} session(s) and ${#helpers[@]} helper tree(s) may still be running."
  info "Run 'iotstack ps' to inspect remaining processes."
  return "$(( failures > 0 ? failures : 1 ))"
}