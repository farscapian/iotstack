#!/usr/bin/env python3
"""Stream logs from an ESPHome device over the native API (aioesphomeapi).

Usage: esphome_logs.py <host>

The device's API encryption key is read from IOTSTACK_API_NOISE_PSK (base64) in
the environment, never from a file. That is the whole reason this exists rather
than shelling out to 'esphome logs': the ESPHome CLI can only take the key from
a config file on disk, and the key is a per-device secret that should not be
written to persistent storage just to tail a log.

Output matches 'esphome logs' -- same timestamp prefix, same parse_log_message
formatting, and the same async_run reconnect loop underneath -- so a device can
be tailed across a reboot.

Unlike 'esphome logs' this does not decode crash backtraces (that needs the
PlatformIO build artifacts). Use 'esphome logs' directly for that.
"""
import asyncio
import os
import sys
from datetime import datetime

from aioesphomeapi import APIClient, parse_log_message
from aioesphomeapi.log_runner import async_run

_API_PORT = 6053


def _on_log(msg) -> None:
    now = datetime.now().astimezone()
    text = msg.message.decode("utf8", "backslashreplace")
    timestamp = (
        f"[{now.hour:02}:{now.minute:02}:{now.second:02}.{now.microsecond // 1000:03}]"
    )
    for line in parse_log_message(text, timestamp):
        print(line, flush=True)


async def stream_logs(host: str, noise_psk: str | None) -> int:
    cli = APIClient(
        host,
        _API_PORT,
        "",
        client_info="iotstack logs",
        noise_psk=noise_psk,
        provide_time=False,
    )
    # Plaintext downgrade is acceptable for logs and no more: the stream is
    # one-way (device -> client) and this never sends a command or a secret, so
    # pre-encryption firmware can still be tailed. IOTSTACK_API_REQUIRE_NOISE=1
    # forbids it anyway, for callers that demand an authenticated device.
    allow_plaintext = os.environ.get("IOTSTACK_API_REQUIRE_NOISE") != "1"
    stop = await async_run(
        cli,
        _on_log,
        name=host,
        allow_plaintext_fallback=allow_plaintext,
    )
    try:
        await asyncio.Event().wait()
    finally:
        await stop()
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: esphome_logs.py <host>", file=sys.stderr)
        return 64
    host = sys.argv[1]
    noise_psk = os.environ.get("IOTSTACK_API_NOISE_PSK") or None
    try:
        return asyncio.run(stream_logs(host, noise_psk))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
