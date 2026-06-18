#!/usr/bin/env python3
"""Replace Unicode characters with ASCII equivalents in repo text files."""

from __future__ import annotations

import os
import re
import sys

SKIP_DIRS = {".git", ".esphome", "__pycache__", "node_modules", ".pio"}
SKIP_FILES = {"scripts/ascii-only-sanitize.py"}
SKIP_EXT = {
    ".ttf", ".bin", ".png", ".jpg", ".gif", ".webp", ".ico", ".woff", ".woff2",
    ".pyc", ".o", ".a", ".so", ".elf", ".map",
}

REPLACEMENTS = [
    ("[WARN]", "[WARN]"),
    ("[CRITICAL]", "[CRITICAL]"),
    ("[OK]", "[OK]"),
    ("[FAIL]", "[FAIL]"),
    ("[TODO]", "[TODO]"),
    ("E", "E"),
    ("", ""),
    ("", ""),
    ("", ""),
    (">", ">"),
    ("[OK]", "[OK]"),
    ("[FAIL]", "[FAIL]"),
    ("[WARN]", "[WARN]"),
    ("[INFO]", "[INFO]"),
    ("", ""),
    ("-", "-"),
    ("...", "..."),
    ("", ""),
    ("->", "->"),
    ("<-", "<-"),
    ("v", "v"),
    (">=", ">="),
    ("<=", "<="),
    ("!=", "!="),
    ("-", "-"),
    ("=", "="),
    ("=", "="),
    ("|", "|"),
    ("|", "|"),
    ("|-", "|-"),
    ("`-", "`-"),
    ("-|", "-|"),
    ("-+", "-+"),
    ("-+", "-+"),
    ("+-", "+-"),
    ("-+-", "-+-"),
    ("-+-", "-+-"),
    ("-+-", "-+-"),
    ("+=", "+="),
    ("=+", "=+"),
    ("+=", "+="),
    ("=+", "=+"),
    ("+=", "+="),
    ("=+", "=+"),
    ("=+-", "=+-"),
    ("=+-", "=+-"),
    ("=+-", "=+-"),
    ("Ohm", "Ohm"),
    ("u", "u"),
    (" deg", " deg"),
    (".", "."),
    ("-", "-"),
    ("-", "-"),
    ("--", "--"),
    ("\uFE0F", ""),
]


def sanitize(text: str) -> str:
    for old, new in REPLACEMENTS:
        text = text.replace(old, new)
    return text


def should_process(path: str) -> bool:
    rel = path.lstrip("./")
    if rel in SKIP_FILES:
        return False
    if os.path.splitext(path)[1].lower() in SKIP_EXT:
        return False
    return True


def iter_files(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            path = os.path.join(dirpath, name)
            if should_process(path):
                yield path


def main() -> int:
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
    changed = 0
    remaining = []

    for path in iter_files(root):
        try:
            with open(path, encoding="utf-8") as f:
                original = f.read()
        except (UnicodeDecodeError, OSError):
            continue
        if not re.search(r"[^\x00-\x7F]", original):
            continue
        updated = sanitize(original)
        if updated != original:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(updated)
            changed += 1
        if re.search(r"[^\x00-\x7F]", updated):
            remaining.append(path)

    print(f"Updated {changed} file(s)")
    if remaining:
        print(f"Still non-ASCII in {len(remaining)} file(s):")
        for p in remaining[:30]:
            print(f"  {p}")
        return 1
    print("All scanned text files are ASCII-only")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())