#!/usr/bin/env python3
"""Call a native-API user service on an ESPHome device via aioesphomeapi.

Usage: esphome_service.py <host> <service_name> [api_password [json_variables]]

json_variables is an optional JSON object whose keys/values match the ESPHome
service variable names.  Example:
  esphome_service.py failsafe-abc123.local update_nvs_secrets '' \
    '{"ota_password":"...","api_key":"..."}'

Exits 0 if the service was sent. The service may reboot the device (e.g.
switch_to_failsafe), so a missing ack / disconnect afterwards is treated as
success — the caller verifies the result by watching mDNS.
"""
import asyncio
import json
import os
import sys

from aioesphomeapi import APIClient


async def call_service(
    host: str,
    service_name: str,
    password: str,
    variables: dict,
    noise_psk: str | None = None,
) -> int:
    cli = APIClient(host, 6053, password or "", noise_psk=noise_psk or None)
    try:
        await asyncio.wait_for(cli.connect(login=True), timeout=15.0)
    except Exception as exc:  # noqa: BLE001
        print(f"[ERROR] could not connect to {host}:6053: {exc}", file=sys.stderr)
        return 1
    try:
        _, services = await cli.list_entities_services()
        svc = next((s for s in services if s.name == service_name), None)
        if svc is None:
            available = ", ".join(s.name for s in services) or "(none)"
            print(
                f"[ERROR] service '{service_name}' not found on {host}; "
                f"available: {available}",
                file=sys.stderr,
            )
            return 2
        try:
            # The service may reboot the device before acking; that's expected.
            await asyncio.wait_for(cli.execute_service(svc, variables), timeout=4.0)
        except Exception:  # noqa: BLE001
            pass
        return 0
    finally:
        try:
            await cli.disconnect(force=True)
        except Exception:  # noqa: BLE001
            pass


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: esphome_service.py <host> <service> [password [json_vars]]",
              file=sys.stderr)
        return 64
    host = sys.argv[1]
    service = sys.argv[2]
    password = sys.argv[3] if len(sys.argv) > 3 else ""
    variables: dict = {}
    if len(sys.argv) > 4 and sys.argv[4]:
        try:
            variables = json.loads(sys.argv[4])
        except json.JSONDecodeError as exc:
            print(f"[ERROR] invalid JSON variables: {exc}", file=sys.stderr)
            return 64
    noise_psk = os.environ.get("IOTSTACK_API_NOISE_PSK") or None
    return asyncio.run(call_service(host, service, password, variables, noise_psk))


if __name__ == "__main__":
    sys.exit(main())
