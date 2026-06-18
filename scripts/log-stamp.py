#!/usr/bin/env python3
"""Stamp log lines with timestamp + source; optionally mirror to stdout.

With --log-only (default for session logging), only the log file is stamped;
stdout is left to tee /dev/tty for real-time console output.
"""
from __future__ import annotations

import argparse
import sys
from datetime import datetime


def _stamp_line(source: str, line: str) -> str:
    ts = datetime.now().astimezone().isoformat(timespec="seconds")
    return f"{ts} [{source}] {line}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Timestamp and tag log lines")
    parser.add_argument("--source", required=True, help="Log source label")
    parser.add_argument("--log-file", required=True, help="Append stamped lines here")
    parser.add_argument(
        "--log-only",
        action="store_true",
        help="Write stamped lines only to --log-file (stdout passes through elsewhere)",
    )
    args = parser.parse_args()

    log_f = open(args.log_file, "a", encoding="utf-8", buffering=1)

    try:
        while True:
            raw = sys.stdin.buffer.readline()
            if not raw:
                break
            line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
            stamped = _stamp_line(args.source, line) + "\n"
            if not args.log_only:
                sys.stdout.write(stamped)
                sys.stdout.flush()
            log_f.write(stamped)
            log_f.flush()
    finally:
        log_f.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())