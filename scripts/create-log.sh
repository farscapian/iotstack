#!/bin/bash
# create-log.sh -- Session logging helpers for iotstack --create-log / --timestamp
#
# Requires config.sh (IOTSTACK_HOME) and SCRIPT_DIR to be set.

[[ -n "${_CREATE_LOG_LOADED:-}" ]] && return 0
_CREATE_LOG_LOADED=1

IOTSTACK_LOG_STAMP="${IOTSTACK_LOG_STAMP:-${SCRIPT_DIR}/scripts/log-stamp.py}"

# Remaining argv after global flags are stripped (set by iotstack_parse_global_argv).
IOTSTACK_ARGV=()

iotstack_normalize_log_id() {
  # Accept flash-matrix-0 or flash-matrix-0.log (filename suffix is optional).
  local log_id="$1"
  log_id="${log_id%.log}"
  printf '%s' "$log_id"
}

iotstack_validate_log_id() {
  local log_id
  log_id=$(iotstack_normalize_log_id "$1")
  if [[ -z "$log_id" ]]; then
    echo "[ERROR] --log-id requires a value" >&2
    exit 1
  fi
  if [[ ! "$log_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "[ERROR] --log-id must contain only letters, digits, and . _ -" >&2
    exit 1
  fi
  printf '%s' "$log_id"
}

iotstack_parse_global_argv() {
  # Global flags valid anywhere on the command line (before or after subcommand):
  #   -v, --verbose (alias), -q, --quiet (alias), --create-log, --timestamp,
  #   --log-id=<id>, -env=<file>
  # --log-id implies --create-log, --timestamp, and -v/--verbose.
  # Sets VERBOSE/QUIET/IOTSTACK_CREATE_LOG/IOTSTACK_TIMESTAMP/IOTSTACK_LOG_ID and
  # fills IOTSTACK_ARGV with the rest.
  IOTSTACK_ARGV=()
  VERBOSE=0
  QUIET=0
  unset IOTSTACK_LOG_ID 2>/dev/null || true

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
        ;;
      --timestamp)
        export IOTSTACK_TIMESTAMP=1
        ;;
      --log-id=*)
        IOTSTACK_LOG_ID=$(iotstack_validate_log_id "${1#--log-id=}")
        export IOTSTACK_LOG_ID
        export IOTSTACK_CREATE_LOG=1
        export IOTSTACK_TIMESTAMP=1
        ;;
      --log-id)
        shift
        [[ $# -gt 0 ]] || { echo "[ERROR] --log-id requires a value" >&2; exit 1; }
        IOTSTACK_LOG_ID=$(iotstack_validate_log_id "$1")
        export IOTSTACK_LOG_ID
        export IOTSTACK_CREATE_LOG=1
        export IOTSTACK_TIMESTAMP=1
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

  [[ -n "${IOTSTACK_LOG_ID:-}" ]] && VERBOSE=1

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
}

create_log_enabled() {
  [[ "${IOTSTACK_CREATE_LOG:-0}" -eq 1 ]]
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

create_log_console_stamp_pipe() {
  # Prefix each stdin line with a timestamp on stdout.
  local source="${1:-}"
  if [[ -f "$IOTSTACK_LOG_STAMP" ]]; then
    local -a stamp_args=(--console-only)
    if create_log_enabled && [[ -n "${IOTSTACK_LOG_FILE:-}" ]]; then
      stamp_args=(--console --source "$source" --log-file "$IOTSTACK_LOG_FILE")
    fi
    stdbuf -oL -eL python3 -u "$IOTSTACK_LOG_STAMP" "${stamp_args[@]}"
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
    IOTSTACK_LOG_SUB_INDENT="  " env PYTHONUNBUFFERED=1 stdbuf -oL -eL "$@" 2>&1 \
      | create_log_tee_console "$source"
    return "${PIPESTATUS[0]}"
  fi
  "$@"
}

create_log_setup() {
  # Keep stdout/stderr on the terminal so child tools (esphome, esptool, etc.) stay
  # line-buffered. iotstack messages are stamped via create_log_stamp_line(); piped
  # subprocesses use create_log_run() / create_log_tee_console().
  #
  # Default: iotstack-<cmd>.log (truncated each run).
  # --log-id=<id>: iotstack-<id>.log; append when the file already exists (any command).
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
        IOTSTACK_LOG_SUB_INDENT="  " python3 -u -m esptool "${esptool_args[@]}" 2>&1 \
          | stdbuf -oL -eL tee "$tmp" /dev/tty \
          | create_log_stamp_pipe "$source"
      else
        IOTSTACK_LOG_SUB_INDENT="  " python3 -u -m esptool "${esptool_args[@]}" 2>&1 \
          | stdbuf -oL -eL tee "$tmp" \
          | create_log_tee_console "$source"
      fi
    else
      IOTSTACK_LOG_SUB_INDENT="  " python3 -u -m esptool "${esptool_args[@]}" 2>&1 \
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

  create_log_esptool_output=$(python3 -m esptool "${esptool_args[@]}" 2>&1 | tee -a "$flash_log" >/dev/null)
  return "${PIPESTATUS[0]}"
}