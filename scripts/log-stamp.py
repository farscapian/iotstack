#!/usr/bin/env python3
"""Stamp log lines with timestamp + source; optionally mirror to stdout.

With --log-only (default for session logging), only the log file is stamped;
stdout is left to tee /dev/tty for real-time console output.

With --console / --console-only, each line is prefixed with an ISO timestamp on
stdout (no source tag). Combined with --log-file, the log keeps [source] tags.
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime


def _timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _stamp_log_line(source: str, line: str) -> str:
    return f"{_timestamp()} [{source}] {line}"


def _stamp_console_line(line: str) -> str:
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

    log_f = None
    if args.log_file:
        log_f = open(args.log_file, "a", encoding="utf-8", buffering=1)

    try:
        while True:
            raw = sys.stdin.buffer.readline()
            if not raw:
                break
            line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
            if args.console and not args.log_only:
                sys.stdout.write(_stamp_console_line(line) + "\n")
                sys.stdout.flush()
            if log_f is not None:
                stamped = _stamp_log_line(args.source, line) + "\n"
                log_f.write(stamped)
                log_f.flush()
    finally:
        if log_f is not None:
            log_f.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())