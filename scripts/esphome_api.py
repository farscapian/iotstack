"""Shared native-API connection helper for the esphome_* scripts.

Both esphome_service.py (user services) and esphome_button.py (button entities)
talk to the same firmware over aioesphomeapi, with the same credential rules --
in particular the plaintext-downgrade guard, which is a security control and so
lives here exactly once rather than being copied per caller.
"""
import asyncio
import logging
import os
import sys

from aioesphomeapi import APIClient

logging.getLogger("aioesphomeapi").setLevel(logging.ERROR)
from aioesphomeapi.core import EncryptionPlaintextAPIError

_ERR_RED = "\033[0;31m"
_WARN_YELLOW = "\033[0;33m"
_ERR_RST = "\033[0m"


def eprint_error(msg: str) -> None:
    print(f"{_ERR_RED}[ERROR]{_ERR_RST} {msg}", file=sys.stderr)


def eprint_warn(msg: str) -> None:
    # Connect failures are recoverable: the shell caller decides whether to
    # abort (it emits its own [ERROR]) or fall back (e.g. USB). Reserve [ERROR]
    # for the caller so it stays a reliable "we quit" signal.
    print(f"{_WARN_YELLOW}[WARN]{_ERR_RST} {msg}", file=sys.stderr)


def plaintext_protocol_mismatch(exc: BaseException) -> bool:
    if isinstance(exc, EncryptionPlaintextAPIError):
        return True
    if "plaintext protocol" in str(exc).lower():
        return True
    cause = exc.__cause__
    return bool(cause and plaintext_protocol_mismatch(cause))


async def connect(
    host: str,
    password: str = "",
    noise_psk: str | None = None,
) -> APIClient | None:
    """Connect to <host>:6053, returning a logged-in client or None."""
    psk_attempts: list[str | None] = [noise_psk] if noise_psk else [None]
    # Plaintext downgrade is a convenience for reading pre-encryption production
    # firmware. It must NEVER apply to secret-bearing writes (bootstrap
    # update_nvs_secrets), or a keyless/spoofed device would harvest every
    # credential in cleartext. IOTSTACK_API_REQUIRE_NOISE=1 forbids the fallback.
    require_noise = os.environ.get("IOTSTACK_API_REQUIRE_NOISE") == "1"
    if noise_psk and not require_noise:
        psk_attempts.append(None)

    for attempt, psk in enumerate(psk_attempts):
        cli = APIClient(host, 6053, password or "", noise_psk=psk)
        try:
            await asyncio.wait_for(cli.connect(login=True), timeout=15.0)
            if attempt > 0 and os.environ.get("IOTSTACK_VERBOSE"):
                print(
                    f"[DEBUG] {host}: connected via plaintext API (device firmware predates NVS encryption)",
                    file=sys.stderr,
                )
            return cli
        except Exception as exc:  # noqa: BLE001
            if (
                psk
                and attempt + 1 < len(psk_attempts)
                and plaintext_protocol_mismatch(exc)
            ):
                if os.environ.get("IOTSTACK_VERBOSE"):
                    print(
                        f"[DEBUG] {host}: plaintext API fallback (re-flash/OTA production firmware to enable encryption)",
                        file=sys.stderr,
                    )
                continue
            eprint_warn(f"could not connect to {host}:6053: {exc}")
            return None
    eprint_warn(f"could not connect to {host}:6053")
    return None


async def disconnect(cli: APIClient) -> None:
    try:
        await cli.disconnect(force=True)
    except Exception:  # noqa: BLE001
        pass
