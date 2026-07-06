#!/usr/bin/env python3
"""Stamp log lines with timestamp + source; optionally mirror to stdout.

With --log-only (default for session logging), only the log file is stamped;
stdout is left to tee /dev/tty for real-time console output.

With --console / --console-only, each line is prefixed with an ISO timestamp on
stdout (no source tag). Combined with --log-file, the log keeps [source] tags.

esptool prints an identical chip/connection banner (version, "Connected to ...",
"Chip type:", MAC lines, stub-flasher lines) on every one of the ~6 invocations
in a flash. The first is useful; the repeats are noise. Since each invocation is
a separate stamper process, they coordinate through a per-session marker file
(see _banner_marker_path) so the banner is shown once and suppressed afterward.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
import tempfile
from datetime import datetime

# ANSI escape sequences: CSI (colors, cursor moves, erase-line), OSC (title),
# and lone Fe escapes. Stripped from the persisted log so it stays plain text;
# the live console keeps its color (see main()).
_ANSI_RE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\].*?(?:\x07|\x1b\\)|[@-Z\\-_])")

# esptool's chip/connection/stub banner -- identical on every invocation. Matched
# against the ANSI-stripped line. Operation output (Writing/Wrote/Hash/erase
# ranges/resets) and errors are deliberately NOT included so they always show.
_BANNER_RE = re.compile(
    r"^(?:"
    r"esptool v"
    r"|Serial port "
    r"|Connecting\."
    r"|Connected to "
    r"|Chip type:"
    r"|Features:"
    r"|Crystal frequency:"
    r"|USB mode:"
    r"|MAC:"
    r"|BASE MAC:"
    r"|MAC_EXT:"
    r"|Uploading stub flasher"
    r"|Running stub flasher"
    r"|Stub flasher running"
    r"|Stub flasher is already running"
    r")"
)


def _timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _clean_for_log(line: str) -> str:
    # Collapse carriage-return progress redraws (e.g. esptool's write meter, which
    # emits every frame as "\r\x1b[K...") down to the final rendered frame, then
    # strip ANSI. Returns "" for control-only input so it is dropped from the log.
    if "\r" in line:
        line = line.rsplit("\r", 1)[-1]
    return _ANSI_RE.sub("", line).rstrip()


def _banner_marker_path(log_file: str | None) -> str | None:
    # Per-session marker: printed-banner coordination across the separate stamper
    # processes of one flash. Keyed on the session log path, so a fresh flash uses
    # a new log file -> new (absent) marker -> banner shown once again.
    if not log_file:
        return None
    digest = hashlib.md5(log_file.encode("utf-8")).hexdigest()[:16]
    return os.path.join(tempfile.gettempdir(), f"iotstack-esptool-banner-{digest}")


def _stamp_log_line(source: str, line: str) -> str:
    return f"{_timestamp()} [{source}] {line}"


def _console_indent() -> str:
    return os.environ.get("IOTSTACK_LOG_INDENT", "") + os.environ.get(
        "IOTSTACK_LOG_SUB_INDENT", ""
    )


def _stamp_console_line(line: str) -> str:
    indent = _console_indent()
    if indent:
        return f"{_timestamp()} {indent}{line}"
    return f"{_timestamp()} {line}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Timestamp and tag log lines")
    parser.add_argument("--source", default="", help="Log source label")
    parser.add_argument("--log-file", help="Append stamped lines here")
    parser.add_argument(
        "--log-only",
        action="store_true",
        help="Write stamped lines only to --log-file (stdout passes through elsewhere)",
    )
    parser.add_argument(
        "--console",
        action="store_true",
        help="Prefix each line with a timestamp on stdout (no source tag)",
    )
    parser.add_argument(
        "--console-only",
        action="store_true",
        help="Alias for --console without --log-file",
    )
    args = parser.parse_args()

    if args.console_only:
        args.console = True

    if not args.console and not args.log_file:
        parser.error("one of --console/--console-only or --log-file is required")

    # Suppress esptool's repeated chip/connection banner: shown on the first
    # invocation of a session, dropped (console and log) on the rest.
    marker = _banner_marker_path(args.log_file)
    suppress_banner = bool(marker) and os.path.exists(marker)
    saw_banner = False

    log_f = None
    if args.log_file:
        log_f = open(args.log_file, "a", encoding="utf-8", buffering=1)

    try:
        while True:
            raw = sys.stdin.buffer.readline()
            if not raw:
                break
            line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
            if not line.strip():
                continue
            cleaned = _clean_for_log(line)
            if cleaned and _BANNER_RE.match(cleaned):
                saw_banner = True
                if suppress_banner:
                    continue
            if args.console and not args.log_only:
                sys.stdout.write(_stamp_console_line(line) + "\n")
                sys.stdout.flush()
            if log_f is not None and cleaned:
                log_f.write(_stamp_log_line(args.source, cleaned) + "\n")
                log_f.flush()
    finally:
        if log_f is not None:
            log_f.close()
        # First invocation that showed a banner arms the marker so the next ones
        # in this session suppress it.
        if marker and saw_banner and not suppress_banner:
            try:
                open(marker, "w").close()
            except OSError:
                pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
