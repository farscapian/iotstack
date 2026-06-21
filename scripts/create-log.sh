#!/bin/bash
# create-log.sh -- Session logging helpers for iotstack --create-log / --timestamp
#
# Requires config.sh (IOTSTACK_HOME) and SCRIPT_DIR to be set.

[[ -n "${_CREATE_LOG_LOADED:-}" ]] && return 0
_CREATE_LOG_LOADED=1

IOTSTACK_LOG_STAMP="${IOTSTACK_LOG_STAMP:-${SCRIPT_DIR}/scripts/log-stamp.py}"

# Remaining argv after global flags are stripped (set by iotstack_parse_global_argv).
IOTSTACK_ARGV=()

iotstack_parse_global_argv() {
  # Global flags valid anywhere on the command line (before or after subcommand):
  #   -v, --verbose (alias), -q, --quiet (alias), --create-log, --timestamp,
  #   --compilation-output, -env=<file>
  # --create-log generates a GUID log id, implies --timestamp and -v/--verbose.
  # Sets VERBOSE/QUIET/IOTSTACK_CREATE_LOG/IOTSTACK_TIMESTAMP/IOTSTACK_LOG_ID and
  # fills IOTSTACK_ARGV with the rest.
  IOTSTACK_ARGV=()
  VERBOSE=0
  QUIET=0
  unset IOTSTACK_LOG_ID 2>/dev/null || true
  unset IOTSTACK_COMPILATION_OUTPUT 2>/dev/null || true

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--verbose)
        VERBOSE=1
        ;;
      -q|--quiet)
        QUIET=1
        ;;
      --create-log)
        export IOTSTACK_CREATE_LOG=1
        export IOTSTACK_TIMESTAMP=1
        if [[ -z "${IOTSTACK_LOG_ID:-}" ]]; then
          IOTSTACK_LOG_ID=$(uuidgen 2>/dev/null \
            || python3 -c 'import uuid; print(uuid.uuid4())')
          export IOTSTACK_LOG_ID
        fi
        ;;
      --timestamp)
        export IOTSTACK_TIMESTAMP=1
        ;;
      --compilation-output)
        export IOTSTACK_COMPILATION_OUTPUT=1
        ;;
      -env=*)
        ENV_FILE="${HOME}/.iotstack/${1#-env=}"
        ;;
      *)
        IOTSTACK_ARGV+=("$1")
        ;;
    esac
    shift
  done

  [[ "${IOTSTACK_CREATE_LOG:-0}" -eq 1 ]] && VERBOSE=1

  if [[ $VERBOSE -eq 1 && $QUIET -eq 1 ]]; then
    echo "[ERROR] -v/--verbose and -q/--quiet are incompatible" >&2
    exit 1
  fi

  export VERBOSE QUIET
  if [[ $VERBOSE -eq 1 ]]; then
    export IOTSTACK_VERBOSE=1
  else
    unset IOTSTACK_VERBOSE 2>/dev/null || true
  fi
  if [[ "${IOTSTACK_COMPILATION_OUTPUT:-0}" -eq 1 ]]; then
    export IOTSTACK_COMPILATION_OUTPUT=1
  else
    unset IOTSTACK_COMPILATION_OUTPUT 2>/dev/null || true
  fi
}

create_log_enabled() {
  [[ "${IOTSTACK_CREATE_LOG:-0}" -eq 1 ]]
}

iotstack_compilation_output_enabled() {
  [[ "${IOTSTACK_COMPILATION_OUTPUT:-0}" -eq 1 ]]
}

create_log_defer_enabled() {
  [[ "${IOTSTACK_LOG_DEFER:-0}" -eq 1 ]]
}

create_log_defer_start() {
  # Buffer iotstack stamp lines in IOTSTACK_LOG_BUFFER_FILE; flush on EXIT.
  # Used by iotstack clean so the logs directory can be removed mid-command.
  create_log_enabled || return 0
  [[ -n "${IOTSTACK_LOG_BUFFER_FILE:-}" ]] && return 0

  export IOTSTACK_LOG_DEFER=1
  export IOTSTACK_LOG_BUFFER_FILE
  IOTSTACK_LOG_BUFFER_FILE=$(mktemp)

  local prior_cmd=""
  if trap -p EXIT 2>/dev/null | grep -q .; then
    prior_cmd=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/")
  fi

  if [[ -n "$prior_cmd" ]]; then
    # shellcheck disable=SC2064
    trap 'create_log_flush; eval "$_CREATE_LOG_PRIOR_EXIT_CMD"' EXIT
    export _CREATE_LOG_PRIOR_EXIT_CMD="$prior_cmd"
  else
    trap 'create_log_flush' EXIT
  fi
}

create_log_flush() {
  create_log_enabled || return 0
  [[ "${IOTSTACK_LOG_FLUSHED:-0}" -eq 1 ]] && return 0
  [[ -n "${IOTSTACK_LOG_FILE:-}" ]] || return 0
  [[ -n "${IOTSTACK_LOG_BUFFER_FILE:-}" && -f "$IOTSTACK_LOG_BUFFER_FILE" ]] || return 0

  export IOTSTACK_LOG_FLUSHED=1
  mkdir -p "$(dirname "$IOTSTACK_LOG_FILE")"
  if [[ -n "${IOTSTACK_LOG_ID:-}" && -f "$IOTSTACK_LOG_FILE" ]]; then
    {
      echo ""
      cat "$IOTSTACK_LOG_BUFFER_FILE"
    } >> "$IOTSTACK_LOG_FILE"
  else
    cat "$IOTSTACK_LOG_BUFFER_FILE" > "$IOTSTACK_LOG_FILE"
  fi
  rm -f "$IOTSTACK_LOG_BUFFER_FILE"
  unset IOTSTACK_LOG_BUFFER_FILE IOTSTACK_LOG_DEFER 2>/dev/null || true
}

iotstack_timestamp_enabled() {
  [[ "${IOTSTACK_TIMESTAMP:-0}" -eq 1 ]]
}

create_log_child_output_piped() {
  create_log_enabled || iotstack_timestamp_enabled
}

iotstack_timestamp_prefix() {
  if iotstack_timestamp_enabled; then
    printf '%s ' "$(date -Iseconds)"
  fi
}

create_log_stamp_line() {
  # Append one stamped line to IOTSTACK_LOG_FILE (no stdout redirect).
  local source="$1"
  local line="$2"
  create_log_enabled || return 0
  [[ -n "${IOTSTACK_LOG_FILE:-}" ]] || return 0
  local ts
  ts=$(date -Iseconds)
  if create_log_defer_enabled && [[ -n "${IOTSTACK_LOG_BUFFER_FILE:-}" ]]; then
    printf '%s [%s] %s\n' "$ts" "$source" "$line" >> "$IOTSTACK_LOG_BUFFER_FILE"
    return 0
  fi
  mkdir -p "$(dirname "$IOTSTACK_LOG_FILE")"
  printf '%s [%s] %s\n' "$ts" "$source" "$line" >> "$IOTSTACK_LOG_FILE"
}

create_log_stamp_pipe() {
  # Stamp stdin lines into IOTSTACK_LOG_FILE. With --log-only, does not write stdout
  # (console is fed separately via tee /dev/tty for real-time output).
  local source="$1"
  if create_log_enabled && [[ -n "${IOTSTACK_LOG_FILE:-}" && -f "$IOTSTACK_LOG_STAMP" ]]; then
    stdbuf -oL -eL python3 -u "$IOTSTACK_LOG_STAMP" \
      --source "$source" \
      --log-file "$IOTSTACK_LOG_FILE" \
      --log-only
  else
    cat
  fi
}

create_log_subprocess_indent_env() {
  # Indent for piped child output (step indent + 2 spaces under the parent [INFO] line).
  export IOTSTACK_LOG_SUB_INDENT="  "
}

create_log_console_stamp_pipe() {
  # Prefix each stdin line with a timestamp on stdout.
  local source="${1:-}"
  if [[ -f "$IOTSTACK_LOG_STAMP" ]]; then
    local -a stamp_args=(--console-only)
    if create_log_enabled && [[ -n "${IOTSTACK_LOG_FILE:-}" ]]; then
      stamp_args=(--console --source "$source" --log-file "$IOTSTACK_LOG_FILE")
    fi
    create_log_subprocess_indent_env
    stdbuf -oL -eL env \
      IOTSTACK_LOG_INDENT="${IOTSTACK_LOG_INDENT:-}" \
      IOTSTACK_LOG_SUB_INDENT="${IOTSTACK_LOG_SUB_INDENT:-}" \
      python3 -u "$IOTSTACK_LOG_STAMP" "${stamp_args[@]}"
  else
    cat
  fi
}

create_log_tee_console() {
  # Filter: mirror child stdout to the terminal (optionally timestamped) and stamp
  # a copy into the session log when --create-log is set.
  local source="$1"
  if create_log_enabled && iotstack_timestamp_enabled; then
    create_log_console_stamp_pipe "$source"
  elif create_log_enabled; then
    stdbuf -oL -eL tee /dev/tty | create_log_stamp_pipe "$source"
  elif iotstack_timestamp_enabled; then
    create_log_console_stamp_pipe "$source"
  else
    cat
  fi
}

create_log_run() {
  # Run a command with line-buffered stdout/stderr mirrored live (and timestamped
  # and/or stamped to the session log).
  # Usage: create_log_run <source_label> <cmd> [args...]
  local source="$1"
  shift
  if create_log_child_output_piped; then
    create_log_subprocess_indent_env
    env PYTHONUNBUFFERED=1 stdbuf -oL -eL "$@" 2>&1 | create_log_tee_console "$source"
    return "${PIPESTATUS[0]}"
  fi
  "$@"
}

create_log_watch_append() {
  # Append one TSV line to IOTSTACK_SESSION_WATCH for every iotstack invocation.
  # Columns: ts, pid, log_id, session_log, serial_log, command
  local invocation_cmd="$1"
  local watch_file="${IOTSTACK_SESSION_WATCH:-${IOTSTACK_HOME}/logs/sessions.watch}"
  local ts log_id session_log serial_log

  ts=$(date -Iseconds)
  mkdir -p "$(dirname "$watch_file")"

  if [[ ! -f "$watch_file" ]]; then
    printf '#%s\t%s\t%s\t%s\t%s\t%s\n' \
      ts pid log_id session_log serial_log command >"$watch_file"
  fi

  if [[ -n "${IOTSTACK_LOG_ID:-}" ]]; then
    log_id="$IOTSTACK_LOG_ID"
    serial_log="${IOTSTACK_HOME}/logs/iotstack-${IOTSTACK_LOG_ID}-serial.log"
  else
    log_id="-"
    serial_log="-"
  fi

  if [[ -n "${IOTSTACK_LOG_FILE:-}" ]]; then
    session_log="$IOTSTACK_LOG_FILE"
  else
    session_log="-"
  fi

  invocation_cmd="${invocation_cmd//$'\t'/ }"
  invocation_cmd="${invocation_cmd//$'\n'/ }"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$$" "$log_id" "$session_log" "$serial_log" "$invocation_cmd" >>"$watch_file"
}

create_log_setup() {
  # Keep stdout/stderr on the terminal so child tools (esphome, esptool, etc.) stay
  # line-buffered. iotstack messages are stamped via create_log_stamp_line(); piped
  # subprocesses use create_log_run() / create_log_tee_console().
  #
  # --create-log: generates iotstack-<guid>.log (always fresh; GUID is unique per run).
  # Without --create-log: no session log.
  local command="$1"
  local log_name session_cmd
  create_log_enabled || return 0

  export PYTHONUNBUFFERED=1
  if [[ -n "${IOTSTACK_LOG_ID:-}" ]]; then
    log_name="iotstack-${IOTSTACK_LOG_ID}"
  else
    log_name="iotstack-${command}"
  fi
  export IOTSTACK_LOG_FILE="${IOTSTACK_HOME}/logs/${log_name}.log"

  session_cmd="iotstack"
  if [[ ${#IOTSTACK_ARGV[@]} -gt 0 ]]; then
    session_cmd+=" ${IOTSTACK_ARGV[*]}"
  fi

  if [[ "$command" == "clean" ]]; then
    create_log_defer_start
    printf '%s === %s ===\n' "$(date -Iseconds)" "$session_cmd" >> "$IOTSTACK_LOG_BUFFER_FILE"
    return 0
  fi

  mkdir -p "$(dirname "$IOTSTACK_LOG_FILE")"

  if [[ -n "${IOTSTACK_LOG_ID:-}" && -f "$IOTSTACK_LOG_FILE" ]]; then
    {
      echo ""
      printf '%s === %s ===\n' "$(date -Iseconds)" "$session_cmd"
    } >> "$IOTSTACK_LOG_FILE"
  else
    : > "$IOTSTACK_LOG_FILE"
    printf '%s === %s ===\n' "$(date -Iseconds)" "$session_cmd" >> "$IOTSTACK_LOG_FILE"
  fi
}

create_log_serial_source() {
  # Label for ESP serial streams: serial:<variant>:<tty>
  local tty="$1"
  local variant="${2:-}"
  if [[ -z "$variant" ]]; then
    if declare -F esp_detect_chip &>/dev/null; then
      variant=$(esp_detect_chip "$tty" 2>/dev/null) || variant="unknown"
    else
      variant="unknown"
    fi
  fi
  printf 'serial:%s:%s' "$variant" "$tty"
}

create_log_run_esptool() {
  # Run esptool with optional session logging and/or console timestamps.
  # Sets create_log_esptool_output.
  # Usage: create_log_run_esptool <source_label> <flash_log> <esptool-args...>
  local source="$1"
  local flash_log="$2"
  shift 2
  local -a esptool_args=("$@")
  local tmp rc

  if create_log_child_output_piped; then
    tmp=$(mktemp)
    if [[ $VERBOSE -eq 1 ]]; then
      if create_log_enabled && ! iotstack_timestamp_enabled; then
        python3 -u -m esptool "${esptool_args[@]}" 2>&1 \
          | stdbuf -oL -eL tee "$tmp" /dev/tty \
          | create_log_stamp_pipe "$source"
      else
        python3 -u -m esptool "${esptool_args[@]}" 2>&1 \
          | stdbuf -oL -eL tee "$tmp" \
          | create_log_tee_console "$source"
      fi
    else
      python3 -u -m esptool "${esptool_args[@]}" 2>&1 \
        | tee "$tmp" \
        | create_log_tee_console "$source" >/dev/null
    fi
    rc=${PIPESTATUS[0]}
    create_log_esptool_output=$(cat "$tmp")
    rm -f "$tmp"
    return "$rc"
  fi

  if [[ $VERBOSE -eq 1 ]]; then
    create_log_esptool_output=$(python3 -m esptool "${esptool_args[@]}" 2>&1 | tee -a "$flash_log")
    return "${PIPESTATUS[0]}"
  fi

  tmp=$(mktemp)
  python3 -m esptool "${esptool_args[@]}" 2>&1 | tee -a "$flash_log" >"$tmp"
  rc=${PIPESTATUS[0]}
  create_log_esptool_output=$(cat "$tmp")
  rm -f "$tmp"
  return "$rc"
}

create_log_serial_capture_enabled() {
  [[ "${IOTSTACK_CREATE_LOG:-0}" -eq 1 ]]
}

create_log_serial_capture_stop() {
  local pid tty

  if [[ -n "${IOTSTACK_SERIAL_LOG_PID:-}" ]]; then
    pid="$IOTSTACK_SERIAL_LOG_PID"
    kill -TERM -"$pid" 2>/dev/null \
      || { declare -F esp_serial_kill_process_tree &>/dev/null \
        && esp_serial_kill_process_tree "$pid"; } \
      || kill -TERM "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    unset IOTSTACK_SERIAL_LOG_PID
  fi

  tty="${IOTSTACK_FLASH_SERIAL_TTY:-}"
  if [[ -n "$tty" ]] && declare -F esp_serial_clear_tty_interference &>/dev/null; then
    esp_serial_clear_tty_interference "$tty"
  fi
  if [[ -n "$tty" ]] && declare -F esp_serial_wait_tty_free &>/dev/null; then
    esp_serial_wait_tty_free "$tty" 5
  fi
}

create_log_serial_capture_pause() {
  create_log_serial_capture_stop
}

create_log_serial_capture_start() {
  # Background serial monitor -> iotstack-<log-id>-serial.log (file only; --reconnect).
  # Usage: create_log_serial_capture_start <tty> [variant]
  local tty="$1"
  local variant="${2:-unknown}"
  local log_file source py baud stamp_py

  create_log_serial_capture_enabled || return 0
  [[ -n "$tty" ]] || return 0

  if declare -F esp_serial_clear_tty_interference &>/dev/null; then
    esp_serial_clear_tty_interference "$tty"
  fi
  create_log_serial_capture_stop

  log_file="${IOTSTACK_HOME}/logs/iotstack-${IOTSTACK_LOG_ID}-serial.log"
  export IOTSTACK_SERIAL_LOG_FILE="$log_file"
  export IOTSTACK_FLASH_SERIAL_TTY="$tty"
  export IOTSTACK_FLASH_SERIAL_VARIANT="$variant"

  mkdir -p "$(dirname "$log_file")"
  if [[ -f "$log_file" ]]; then
    printf '\n%s === serial capture resumed (%s) ===\n' "$(date -Iseconds)" "$tty" >>"$log_file"
  else
    printf '%s === serial capture started (%s) ===\n' "$(date -Iseconds)" "$tty" >"$log_file"
  fi

  source=$(create_log_serial_source "$tty" "$variant")

  py=$(head -1 "$(command -v esphome)" 2>/dev/null | sed 's/^#!//')
  [[ -x "$py" ]] || py="python3"

  stamp_py="$IOTSTACK_LOG_STAMP"
  baud="${IOTSTACK_SERIAL_MONITOR_BAUD:-115200}"

  setsid bash -c '
    exec "$0" -u "$1" --reconnect "$2" "$3" 2>&1 \
      | stdbuf -oL -eL python3 -u "$4" --source "$5" --log-file "$6" --log-only
  ' "$py" "${SCRIPT_DIR}/scripts/serial-logs.py" "$tty" "$baud" "$stamp_py" "$source" "$log_file" &
  IOTSTACK_SERIAL_LOG_PID=$!
  export IOTSTACK_SERIAL_LOG_PID
}

create_log_serial_capture_resume() {
  [[ -n "${IOTSTACK_FLASH_SERIAL_TTY:-}" ]] || return 0
  create_log_serial_capture_start "${IOTSTACK_FLASH_SERIAL_TTY}" "${IOTSTACK_FLASH_SERIAL_VARIANT:-unknown}"
}