#!/usr/bin/env python3
"""Decode NVS partition binary and extract keys from the iotstack namespace."""

from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path

PAGE_SIZE = 4096
HEADER_SIZE = 32
BITMAP_OFFSET = 32
BITMAP_SIZE = 32
FIRST_ENTRY_OFFSET = 64
ENTRY_SIZE = 32
MAX_ENTRIES = 126

PAGE_ACTIVE = 0xFFFFFFFE
PAGE_FULL = 0xFFFFFFFC

U8 = 0x01
SZ = 0x21
BLOB = 0x41
BLOB_DATA = 0x42
BLOB_IDX = 0x48

IOTSTACK_NAMESPACE = "iotstack"
KNOWN_KEYS = (
    "wifi_ssid",
    "wifi_password",
    "ota_password",
    "prod_api_key",
    "thread_tlv",
    "device_role",
    "git_commit",
)


def _entry_used(bitmap: bytes, entry_idx: int) -> bool:
    bitnum = entry_idx * 2
    byte_idx = bitnum // 8
    bit_offset = bitnum & 7
    if byte_idx >= len(bitmap):
        return False
    return (bitmap[byte_idx] & (1 << bit_offset)) == 0


def _page_state(page: bytes) -> int:
    return struct.unpack_from("<I", page, 0)[0]


def _page_usable(page: bytes) -> bool:
    state = _page_state(page)
    return state in (PAGE_ACTIVE, PAGE_FULL)


def _read_key(entry: bytes) -> str:
    raw = entry[8:24]
    end = raw.find(b"\x00")
    if end == -1:
        end = len(raw)
    return raw[:end].decode("utf-8", errors="replace")


def _verify_entry_crc(entry: bytes) -> bool:
    crc_data = bytearray(28)
    crc_data[0:4] = entry[0:4]
    crc_data[4:28] = entry[8:32]
    expected = struct.unpack_from("<I", entry, 4)[0]
    actual = zlib.crc32(bytes(crc_data), 0xFFFFFFFF) & 0xFFFFFFFF
    return expected == actual


def _collect_string_value(page: bytes, entry_idx: int, span: int, datalen: int) -> bytes:
    chunks = bytearray()
    data_entries = span - 1
    for offset in range(1, data_entries + 1):
        start = FIRST_ENTRY_OFFSET + (entry_idx + offset) * ENTRY_SIZE
        chunks.extend(page[start : start + ENTRY_SIZE])
    return bytes(chunks[:datalen])


def _parse_blob_value(pages: list[bytes], page_idx: int, entry_idx: int, span: int) -> bytes | None:
    header = pages[page_idx][
        FIRST_ENTRY_OFFSET + entry_idx * ENTRY_SIZE : FIRST_ENTRY_OFFSET + (entry_idx + 1) * ENTRY_SIZE
    ]
    if header[1] != BLOB:
        return None

    total_size = struct.unpack_from("<I", header, 24)[0]
    chunk_count = header[28]
    chunk_start = header[29]
    key = _read_key(header)

    chunks: list[bytes] = []
    for chunk_index in range(chunk_start, chunk_start + chunk_count):
        found = False
        for p_idx, page in enumerate(pages):
            if not _page_usable(page):
                continue
            bitmap = page[BITMAP_OFFSET : BITMAP_OFFSET + BITMAP_SIZE]
            for idx in range(MAX_ENTRIES):
                if not _entry_used(bitmap, idx):
                    continue
                entry = page[
                    FIRST_ENTRY_OFFSET + idx * ENTRY_SIZE : FIRST_ENTRY_OFFSET + (idx + 1) * ENTRY_SIZE
                ]
                if entry[0] != header[0] or entry[1] != BLOB_DATA:
                    continue
                if entry[3] != chunk_index:
                    continue
                if _read_key(entry) != key:
                    continue
                chunk_size = struct.unpack_from("<H", entry, 24)[0]
                data_span = entry[2]
                chunk = _collect_string_value(page, idx, data_span, chunk_size)
                chunks.append(chunk)
                found = True
                break
            if found:
                break
        if not found:
            return None

    return b"".join(chunks)[:total_size]


def parse_nvs_partition(data: bytes, namespace: str = IOTSTACK_NAMESPACE) -> dict[str, str]:
    if len(data) % PAGE_SIZE != 0:
        raise ValueError(f"NVS data size {len(data)} is not a multiple of page size {PAGE_SIZE}")

    pages = [data[i : i + PAGE_SIZE] for i in range(0, len(data), PAGE_SIZE)]
    ns_index_map: dict[int, str] = {}
    values: dict[str, str] = {}

    for page_idx, page in enumerate(pages):
        if not _page_usable(page):
            continue

        bitmap = page[BITMAP_OFFSET : BITMAP_OFFSET + BITMAP_SIZE]
        entry_idx = 0
        while entry_idx < MAX_ENTRIES:
            if not _entry_used(bitmap, entry_idx):
                entry_idx += 1
                continue

            start = FIRST_ENTRY_OFFSET + entry_idx * ENTRY_SIZE
            entry = page[start : start + ENTRY_SIZE]
            span = entry[2]
            if span == 0 or span == 0xFF:
                entry_idx += 1
                continue
            if span > MAX_ENTRIES - entry_idx:
                entry_idx += 1
                continue

            entry_type = entry[1]
            ns_index = entry[0]
            key = _read_key(entry)

            if ns_index == 0 and entry_type == U8 and _verify_entry_crc(entry):
                ns_index_map[entry[24]] = key
                entry_idx += span
                continue

            target_ns = ns_index_map.get(ns_index)
            if target_ns != namespace:
                entry_idx += span
                continue

            if entry_type == SZ and _verify_entry_crc(entry):
                datalen = struct.unpack_from("<H", entry, 24)[0]
                raw = _collect_string_value(page, entry_idx, span, datalen)
                values[key] = raw.decode("utf-8", errors="replace")
            elif entry_type == BLOB and _verify_entry_crc(entry):
                raw = _parse_blob_value(pages, page_idx, entry_idx, span)
                if raw is not None:
                    values[key] = raw.decode("utf-8", errors="replace")

            entry_idx += span

    return values


def _format_all(values: dict[str, str]) -> str:
    lines = []
    for key in KNOWN_KEYS:
        if key in values:
            lines.append(f"{key}={values[key]}")
    for key in sorted(values):
        if key not in KNOWN_KEYS:
            lines.append(f"{key}={values[key]}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Decode iotstack NVS partition binary")
    parser.add_argument("nvs_bin", type=Path, help="Path to NVS partition binary")
    parser.add_argument(
        "keys",
        nargs="*",
        help="Key(s) to print (default: all known keys present)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Print all keys in the iotstack namespace",
    )
    parser.add_argument(
        "--namespace",
        default=IOTSTACK_NAMESPACE,
        help=f"NVS namespace to read (default: {IOTSTACK_NAMESPACE})",
    )
    args = parser.parse_args()

    if not args.nvs_bin.is_file():
        print(f"[ERROR] NVS binary not found: {args.nvs_bin}", file=sys.stderr)
        return 1

    data = args.nvs_bin.read_bytes()
    try:
        values = parse_nvs_partition(data, namespace=args.namespace)
    except ValueError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    if args.all or not args.keys:
        if not values:
            print("[WARN] No keys found in NVS namespace", file=sys.stderr)
            return 1
        print(_format_all(values))
        return 0

    missing = []
    for key in args.keys:
        if key not in values:
            missing.append(key)
            continue
        print(values[key])

    if missing:
        print(
            f"[ERROR] Key(s) not found in NVS: {', '.join(missing)}",
            file=sys.stderr,
        )
        print(
            f"[INFO] Available keys: {', '.join(sorted(values)) or '(none)'}",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())