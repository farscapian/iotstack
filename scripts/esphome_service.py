#!/usr/bin/env python3
"""Call a native-API user service on an ESPHome device via aioesphomeapi.

Usage: esphome_service.py <host> <service_name> [api_password [json_variables]]

json_variables is an optional JSON object whose keys/values match the ESPHome
service variable names.  Example:
  esphome_service.py bootstrap-abc123.local update_nvs_secrets '' \
    '{"matrix_cols":"2","matrix_panel_w":"64","matrix_panel_h":"32"}'

Exits 0 if the service was sent. The service may reboot the device (e.g.
switch_to_bootstrap), so a missing ack / disconnect afterwards is treated as
success -- the caller verifies the result by watching mDNS.
"""
import asyncio
import json
import logging
import os
import sys

from aioesphomeapi import APIClient

logging.getLogger("aioesphomeapi").setLevel(logging.ERROR)
from aioesphomeapi.core import EncryptionPlaintextAPIError

_ERR_RED = "\033[0;31m"
_WARN_YELLOW = "\033[0;33m"
_ERR_RST = "\033[0m"


def _eprint_error(msg: str) -> None:
    print(f"{_ERR_RED}[ERROR]{_ERR_RST} {msg}", file=sys.stderr)


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


async def call_service(
    host: str,
    service_name: str,
    password: str,
    variables: dict,
    noise_psk: str | None = None,
) -> int:
    psk_attempts: list[str | None] = [noise_psk] if noise_psk else [None]
    # Plaintext downgrade is a convenience for reading pre-encryption production
    # firmware. It must NEVER apply to secret-bearing writes (bootstrap
    # update_nvs_secrets), or a keyless/spoofed device would harvest every
    # credential in cleartext. IOTSTACK_API_REQUIRE_NOISE=1 forbids the fallback.
    require_noise = os.environ.get("IOTSTACK_API_REQUIRE_NOISE") == "1"
    if noise_psk and not require_noise:
        psk_attempts.append(None)

    cli: APIClient | None = None
    for attempt, psk in enumerate(psk_attempts):
        cli = APIClient(host, 6053, password or "", noise_psk=psk)
        try:
            await asyncio.wait_for(cli.connect(login=True), timeout=15.0)
            if attempt > 0 and os.environ.get("IOTSTACK_VERBOSE"):
                print(
                    f"[DEBUG] {host}: connected via plaintext API (device firmware predates NVS encryption)",
                    file=sys.stderr,
                )
            break
        except Exception as exc:  # noqa: BLE001
            if (
                psk
                and attempt + 1 < len(psk_attempts)
                and _plaintext_protocol_mismatch(exc)
            ):
                if os.environ.get("IOTSTACK_VERBOSE"):
                    print(
                        f"[DEBUG] {host}: plaintext API fallback (re-flash/OTA production firmware to enable encryption)",
                        file=sys.stderr,
                    )
                continue
            _eprint_warn(f"could not connect to {host}:6053: {exc}")
            return 1
    else:
        _eprint_warn(f"could not connect to {host}:6053")
        return 1
    assert cli is not None
    try:
        _, services = await cli.list_entities_services()
        svc = next((s for s in services if s.name == service_name), None)
        if svc is None:
            available = ", ".join(s.name for s in services) or "(none)"
            _eprint_error(
                f"service '{service_name}' not found on {host}; "
                f"available: {available}"
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
            _eprint_error(f"invalid JSON variables: {exc}")
            return 64
    noise_psk = os.environ.get("IOTSTACK_API_NOISE_PSK") or None
    return asyncio.run(call_service(host, service, password, variables, noise_psk))


if __name__ == "__main__":
    sys.exit(main())
