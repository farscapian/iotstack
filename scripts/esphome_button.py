#!/usr/bin/env python3
"""Press a button entity on an ESPHome device via the native API (aioesphomeapi).

Usage: esphome_button.py <host> <object_id> [api_password]

<object_id> is the ESPHome entity object_id, e.g. "restart" or
"toggle_boot_partition" (the buttons defined in common/partition_manager_base.yaml).

Both of those buttons reboot the device, so a missing ack / disconnect right
after the press is expected and treated as success -- the caller confirms the
result by watching mDNS.

Exit codes: 0 press sent, 1 could not connect, 2 no such button on the device.
"""
import asyncio
import os
import sys

from aioesphomeapi.model import ButtonInfo

import esphome_api


def _sanitize(name: str) -> str:
    return "".join(c if c.isalnum() else "_" for c in name.strip().lower())


async def press_button(
    host: str,
    object_id: str,
    password: str,
    noise_psk: str | None = None,
) -> int:
    cli = await esphome_api.connect(host, password, noise_psk)
    if cli is None:
        return 1
    try:
        entities, _ = await cli.list_entities_services()
        buttons = [e for e in entities if isinstance(e, ButtonInfo)]
        want = _sanitize(object_id)
        btn = next((b for b in buttons if b.object_id == object_id), None)
        if btn is None:
            # Older firmware may sanitize the object_id differently than the
            # caller spelled it; fall back to matching the entity name.
            btn = next((b for b in buttons if _sanitize(b.name) == want), None)
        if btn is None:
            available = ", ".join(b.object_id for b in buttons) or "(none)"
            esphome_api.eprint_error(
                f"button '{object_id}' not found on {host}; available: {available}"
            )
            return 2
        # The press reboots the device before it can ack; that's expected. Give
        # the write a moment to drain rather than tearing the socket down under it.
        cli.button_command(btn.key, device_id=getattr(btn, "device_id", 0) or 0)
        await asyncio.sleep(0.5)
        return 0
    finally:
        await esphome_api.disconnect(cli)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: esphome_button.py <host> <object_id> [password]",
              file=sys.stderr)
        return 64
    host = sys.argv[1]
    object_id = sys.argv[2]
    password = sys.argv[3] if len(sys.argv) > 3 else ""
    noise_psk = os.environ.get("IOTSTACK_API_NOISE_PSK") or None
    return asyncio.run(press_button(host, object_id, password, noise_psk))


if __name__ == "__main__":
    sys.exit(main())
