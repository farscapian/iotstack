#!/usr/bin/env python3
"""Read text_sensor states from an ESPHome device via the native API.

Usage: esphome_text_sensors.py <host> <object_id> [object_id...]
       [--password PASSWORD]

Prints one line per sensor: object_id=value
Exits 0 when all requested sensors were observed; 1 on connection/API errors;
2 when connected but one or more sensors were not found.
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys

from aioesphomeapi import APIClient
from aioesphomeapi.core import EncryptionPlaintextAPIError
from aioesphomeapi.model import TextSensorInfo

logging.getLogger("aioesphomeapi").setLevel(logging.ERROR)

_WARN_YELLOW = "\033[0;33m"
_ERR_RST = "\033[0m"


def _eprint_warn(msg: str) -> None:
    # Connect failures are recoverable: the shell caller decides whether to
    # abort (it emits its own [ERROR]) or fall back (e.g. USB). Reserve [ERROR]
    # for the caller so it stays a reliable "we quit" signal.
    print(f"{_WARN_YELLOW}[WARN]{_ERR_RST} {msg}", file=sys.stderr)


def _plaintext_protocol_mismatch(exc: BaseException) -> bool:
    if isinstance(exc, EncryptionPlaintextAPIError):
        return True
    if "plaintext protocol" in str(exc).lower():
        return True
    cause = exc.__cause__
    return bool(cause and _plaintext_protocol_mismatch(cause))


async def read_text_sensors(
    host: str,
    object_ids: list[str],
    password: str,
    noise_psk: str | None,
    wait_s: float = 3.0,
) -> tuple[dict[str, str], list[str]]:
    wanted = set(object_ids)
    key_to_oid: dict[int, str] = {}
    observed: dict[str, str] = {}

    def on_state(state) -> None:
        oid = key_to_oid.get(state.key)
        if oid:
            observed[oid] = str(state.state)

    psk_attempts: list[str | None] = [noise_psk] if noise_psk else [None]
    if noise_psk:
        psk_attempts.append(None)

    cli: APIClient | None = None
    for attempt, psk in enumerate(psk_attempts):
        cli = APIClient(host, 6053, password or "", noise_psk=psk)
        try:
            await asyncio.wait_for(cli.connect(login=True), timeout=15.0)
            if attempt > 0 and os.environ.get("IOTSTACK_VERBOSE"):
                print(
                    f"[DEBUG] {host}: plaintext API fallback",
                    file=sys.stderr,
                )
            break
        except Exception as exc:  # noqa: BLE001
            if (
                psk
                and attempt + 1 < len(psk_attempts)
                and _plaintext_protocol_mismatch(exc)
            ):
                continue
            _eprint_warn(f"could not connect to {host}:6053: {exc}")
            return {}, list(object_ids)
    else:
        _eprint_warn(f"could not connect to {host}:6053")
        return {}, list(object_ids)

    assert cli is not None
    try:
        entities, _ = await cli.list_entities_services()
        for entity in entities:
            if not isinstance(entity, TextSensorInfo):
                continue
            oid = entity.object_id
            if oid in wanted:
                key_to_oid[entity.key] = oid

        cli.subscribe_states(on_state)
        deadline = asyncio.get_running_loop().time() + wait_s
        while len(observed) < len(key_to_oid) and asyncio.get_running_loop().time() < deadline:
            await asyncio.sleep(0.1)
    finally:
        try:
            await cli.disconnect(force=True)
        except Exception:  # noqa: BLE001
            pass

    not_found = [oid for oid in object_ids if oid not in observed]
    return observed, not_found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host")
    parser.add_argument("object_ids", nargs="+")
    parser.add_argument("--password", default="")
    args = parser.parse_args()

    noise_psk = os.environ.get("IOTSTACK_API_NOISE_PSK") or None
    observed, not_found = asyncio.run(
        read_text_sensors(args.host, args.object_ids, args.password, noise_psk)
    )

    if not observed and not_found == args.object_ids:
        return 1

    for oid in args.object_ids:
        if oid in observed:
            print(f"{oid}={observed[oid]}")

    return 2 if not_found else 0


if __name__ == "__main__":
    sys.exit(main())