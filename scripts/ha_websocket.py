#!/usr/bin/env python3
"""Home Assistant WebSocket API client for iotstack.

Uses the public WebSocket API only (no REST).
"""

from __future__ import annotations

import argparse
import json
import re
import ssl
import sys
import time
import urllib.error
import urllib.request
from typing import Any


class HAWebSocketError(Exception):
    """Raised when a Home Assistant WebSocket request fails."""


class HAWebSocketClient:
    """Authenticated Home Assistant WebSocket session."""

    def __init__(self, ha_url: str, token: str, timeout: float = 15.0) -> None:
        self.ha_url = ha_url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self._ws: Any = None
        self._next_id = 1
        self.ha_version = "unknown"

    @property
    def ws_url(self) -> str:
        url = self.ha_url.replace("http://", "ws://").replace("https://", "wss://")
        return f"{url}/api/websocket"

    def connect(self) -> str:
        try:
            import websocket
        except ImportError as exc:
            raise HAWebSocketError(
                "python3 websocket-client is required. Install with: pip3 install websocket-client"
            ) from exc

        try:
            self._ws = websocket.create_connection(self.ws_url, timeout=self.timeout)
            auth_required = json.loads(self._ws.recv())
            if auth_required.get("type") != "auth_required":
                raise HAWebSocketError(
                    f"Unexpected WebSocket message: {auth_required.get('type')}"
                )

            self._ws.send(json.dumps({"type": "auth", "access_token": self.token}))
            auth_ok = json.loads(self._ws.recv())
            if auth_ok.get("type") != "auth_ok":
                message = auth_ok.get("message", "authentication failed")
                raise HAWebSocketError(f"Home Assistant authentication failed: {message}")

            self.ha_version = str(auth_ok.get("ha_version", "unknown"))
            return self.ha_version
        except HAWebSocketError:
            raise
        except Exception as exc:
            raise HAWebSocketError(f"WebSocket connection failed: {exc}") from exc

    def close(self) -> None:
        if self._ws is not None:
            try:
                self._ws.close()
            except Exception:
                pass
            self._ws = None

    def __enter__(self) -> HAWebSocketClient:
        self.connect()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def send_command(
        self,
        msg_type: str,
        *,
        msg_id: int | None = None,
        wait_timeout: float | None = None,
        **fields: Any,
    ) -> Any:
        if self._ws is None:
            raise HAWebSocketError("WebSocket is not connected")

        if msg_id is None:
            msg_id = self._next_id
            self._next_id += 1

        payload: dict[str, Any] = {"id": msg_id, "type": msg_type, **fields}
        self._ws.send(json.dumps(payload))

        deadline = time.time() + (wait_timeout if wait_timeout is not None else self.timeout)
        while time.time() < deadline:
            raw = self._ws.recv()
            message = json.loads(raw)
            if message.get("id") != msg_id:
                continue
            if message.get("type") != "result":
                continue
            if not message.get("success"):
                error = message.get("error", {})
                code = error.get("code", "unknown")
                text = error.get("message", "request failed")
                raise HAWebSocketError(f"{msg_type} failed ({code}): {text}")
            return message.get("result")

        raise HAWebSocketError(f"Timed out waiting for {msg_type} response")


def auth_test(ha_url: str, token: str) -> str:
    with HAWebSocketClient(ha_url, token) as client:
        return client.ha_version


def query(ha_url: str, token: str, msg_type: str, fields: dict[str, Any] | None = None) -> Any:
    with HAWebSocketClient(ha_url, token) as client:
        return client.send_command(msg_type, **(fields or {}))


def _ssl_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


# HA can take a while to connect to a just-rebooted device to advance the ESPHome
# config flow; give each config-flow request a generous read timeout (on the scale
# of the discovery poll) so a slow-but-working setup is not cut off at 30s.
_CONFIG_FLOW_HTTP_TIMEOUT = 90


def _http_config_flow_request(
    ha_url: str,
    token: str,
    flow_id: str,
    *,
    method: str = "GET",
    user_input: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Submit a config-flow step (HA exposes step handling via authenticated REST)."""
    url = f"{ha_url.rstrip('/')}/api/config/config_entries/flow/{flow_id}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    data = None
    if method == "POST":
        data = json.dumps(user_input if user_input is not None else {}).encode()

    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(
            req, timeout=_CONFIG_FLOW_HTTP_TIMEOUT, context=_ssl_context()
        ) as resp:
            body = resp.read().decode()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise HAWebSocketError(
            f"Config flow HTTP {exc.code}: {detail or exc.reason}"
        ) from exc
    except TimeoutError as exc:
        # A bare TimeoutError (not wrapped in URLError) is raised when the read
        # times out -- typically HA taking too long to reach the just-rebooted
        # device to complete the ESPHome config flow. Surface it cleanly so the
        # caller logs a one-line reason instead of a traceback.
        raise HAWebSocketError(
            f"Config flow request timed out after {_CONFIG_FLOW_HTTP_TIMEOUT}s "
            "(Home Assistant could not reach the device to finish setup)"
        ) from exc
    except urllib.error.URLError as exc:
        raise HAWebSocketError(f"Config flow HTTP request failed: {exc}") from exc

    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        raise HAWebSocketError(f"Invalid JSON from config flow: {body[:200]}") from exc


def _mac_suffix_from_hostname(hostname: str) -> str | None:
    match = re.search(r"([0-9a-f]{6})$", hostname.strip().lower())
    return match.group(1) if match else None


def _normalize_ha_host(value: str) -> str:
    return value.strip().lower().removesuffix(".local")


def _ha_label_matches_hostname(label: str, hostname: str) -> bool:
    """True when an HA title/device_name refers to the same device as hostname."""
    target = _normalize_ha_host(hostname)
    text = _normalize_ha_host(label)
    if not target or not text:
        return False
    if text == target or target in text or text in target:
        return True
    mac = _mac_suffix_from_hostname(target)
    if mac:
        compact = re.sub(r"[^0-9a-f]", "", text)
        if mac in compact:
            return True
    return False


def _find_esphome_flow(flows: list[dict[str, Any]], hostname: str) -> dict[str, Any] | None:
    for flow in flows:
        if flow.get("handler") != "esphome":
            continue
        context = flow.get("context") or {}
        title = str(context.get("title", ""))
        placeholders = context.get("title_placeholders") or {}
        name = str(placeholders.get("name", ""))
        if _ha_label_matches_hostname(title, hostname) or _ha_label_matches_hostname(
            name, hostname
        ):
            return flow
    return None


def _find_esphome_entry_id(ha_url: str, token: str, hostname: str) -> str | None:
    """Return the esphome config-entry id for a device, or None if not integrated."""
    entries = query(ha_url, token, "config_entries/get", {"domain": "esphome"}) or []
    for entry in entries:
        data = entry.get("data") or {}
        for field in (
            str(data.get("device_name", "")),
            str(data.get("host", "")),
            str(entry.get("title", "")),
        ):
            if _ha_label_matches_hostname(field, hostname):
                return entry.get("entry_id")

    devices = query(ha_url, token, "config/device_registry/list") or []
    for device in devices:
        for identifier_set in device.get("identifiers") or []:
            if not isinstance(identifier_set, (list, tuple)) or len(identifier_set) < 2:
                continue
            if str(identifier_set[0]).lower() != "esphome":
                continue
            if _ha_label_matches_hostname(str(identifier_set[1]), hostname):
                entry_ids = device.get("config_entries") or []
                if entry_ids:
                    return str(entry_ids[0])
    return None


def _esphome_entry_exists(ha_url: str, token: str, hostname: str) -> bool:
    return _find_esphome_entry_id(ha_url, token, hostname) is not None


def _flow_input_for_step(step_id: str, noise_psk: str) -> dict[str, Any]:
    if step_id == "discovery_confirm":
        return {}
    if step_id == "encryption_key":
        return {"noise_psk": noise_psk}
    if step_id == "authenticate":
        return {"password": ""}
    if step_id == "reauth_confirm":
        return {"noise_psk": noise_psk}
    raise HAWebSocketError(f"Unsupported ESPHome config-flow step: {step_id}")


def _http_flow_start(
    ha_url: str, token: str, payload: dict[str, Any]
) -> dict[str, Any]:
    """Start a new config/reconfigure flow via the flow index endpoint.

    Passing an ``entry_id`` makes HA start the flow with source=reconfigure for
    that entry (used to re-read a device after its config changed).
    """
    url = f"{ha_url.rstrip('/')}/api/config/config_entries/flow"
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode(), headers=headers, method="POST"
    )
    try:
        with urllib.request.urlopen(
            req, timeout=_CONFIG_FLOW_HTTP_TIMEOUT, context=_ssl_context()
        ) as resp:
            body = resp.read().decode()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise HAWebSocketError(
            f"Config flow start HTTP {exc.code}: {detail or exc.reason}"
        ) from exc
    except TimeoutError as exc:
        raise HAWebSocketError(
            f"Config flow start timed out after {_CONFIG_FLOW_HTTP_TIMEOUT}s"
        ) from exc
    except urllib.error.URLError as exc:
        raise HAWebSocketError(f"Config flow start request failed: {exc}") from exc
    try:
        return json.loads(body)
    except json.JSONDecodeError as exc:
        raise HAWebSocketError(f"Invalid JSON from flow start: {body[:200]}") from exc


def reconfigure_esphome_entry(
    ha_url: str, token: str, entry_id: str, noise_psk: str
) -> dict[str, Any]:
    """Drive HA's reconfigure flow for an existing esphome entry.

    Adding entities to a device (or a whole new platform, e.g. the first light)
    is only guaranteed to surface in HA once the entry re-reads the device.
    Reconfigure re-runs the config flow against the stored connection and, on
    success, reloads the entry -- so the new entities appear. Terminates on an
    ``abort`` with reason ``reconfigure_successful``.
    """
    result = _http_flow_start(
        ha_url, token, {"handler": "esphome", "entry_id": entry_id}
    )
    flow_id = result.get("flow_id", "")
    for _ in range(20):
        step_type = result.get("type")
        if step_type == "create_entry":
            return {"status": "reconfigured"}
        if step_type == "abort":
            reason = result.get("reason", "unknown")
            if reason in {
                "reconfigure_successful",
                "already_configured",
                "already_configured_updates",
                "already_configured_detailed",
            }:
                return {"status": "reconfigured", "reason": reason}
            raise HAWebSocketError(f"ESPHome reconfigure aborted: {reason}")
        if step_type == "form":
            step_id = result.get("step_id", "")
            try:
                user_input = _flow_input_for_step(step_id, noise_psk)
            except HAWebSocketError:
                # Reconfigure steps we do not model (e.g. a bare confirm) take no
                # input; submit empty rather than failing the whole reconfigure.
                user_input = {}
            result = _http_config_flow_request(
                ha_url, token, flow_id, method="POST", user_input=user_input
            )
            continue
        if step_type == "menu":
            options = result.get("menu_options") or []
            if not options:
                raise HAWebSocketError("ESPHome reconfigure menu has no options")
            result = _http_config_flow_request(
                ha_url, token, flow_id, method="POST",
                user_input={"next_step_id": options[0]},
            )
            continue
        raise HAWebSocketError(f"Unexpected reconfigure response type: {step_type}")
    raise HAWebSocketError("ESPHome reconfigure did not complete")


def register_esphome_device(
    ha_url: str,
    token: str,
    hostname: str,
    noise_psk: str,
    *,
    poll_timeout: float = 90.0,
) -> dict[str, Any]:
    """Complete HA ESPHome discovery for a production device.

    Uses WebSocket (flow/progress, config_entries/get) to find the device and
    authenticated REST to advance config-flow steps (HA has no WS submit API).
    When the device already has an entry (a re-flash), drive a reconfigure so HA
    picks up any entities added since it was first integrated.
    """
    entry_id = _find_esphome_entry_id(ha_url, token, hostname)
    if entry_id:
        try:
            reconfigure_esphome_entry(ha_url, token, entry_id, noise_psk)
            return {"status": "reconfigured", "hostname": hostname}
        except HAWebSocketError as exc:
            # Best-effort: never fail a flash over reconfigure. HA already has the
            # device, and new entities also surface on the next reconnect.
            print(
                f"[warn] reconfigure of {hostname} did not complete: {exc}",
                file=sys.stderr,
            )
            return {"status": "already_registered", "hostname": hostname}

    deadline = time.time() + poll_timeout
    flow: dict[str, Any] | None = None
    while time.time() < deadline:
        flows = query(ha_url, token, "config_entries/flow/progress") or []
        flow = _find_esphome_flow(flows, hostname)
        if flow:
            break
        time.sleep(5)

    if not flow:
        # No zeroconf flow when the device is already integrated (common on re-flash).
        if _esphome_entry_exists(ha_url, token, hostname):
            return {"status": "already_registered", "hostname": hostname}
        raise HAWebSocketError(
            f"No ESPHome discovery flow for {hostname} after {int(poll_timeout)}s"
        )

    flow_id = flow["flow_id"]
    result = _http_config_flow_request(ha_url, token, flow_id, method="GET")

    for _ in range(20):
        step_type = result.get("type")
        if step_type == "create_entry":
            return result
        if step_type == "abort":
            reason = result.get("reason", "unknown")
            if reason in {
                "already_configured",
                "already_configured_updates",
                "already_configured_detailed",
            }:
                return {"status": "already_configured", "reason": reason}
            raise HAWebSocketError(f"ESPHome config flow aborted: {reason}")
        if step_type == "form":
            step_id = result.get("step_id", "")
            user_input = _flow_input_for_step(step_id, noise_psk)
            result = _http_config_flow_request(
                ha_url, token, flow_id, method="POST", user_input=user_input
            )
            continue
        if step_type == "menu":
            options = result.get("menu_options") or []
            if not options:
                raise HAWebSocketError("ESPHome config flow menu has no options")
            result = _http_config_flow_request(
                ha_url, token, flow_id, method="POST", user_input={"next_step_id": options[0]}
            )
            continue
        raise HAWebSocketError(f"Unexpected config-flow response type: {step_type}")

    raise HAWebSocketError(f"ESPHome config flow for {hostname} did not complete")


def call_service(
    ha_url: str,
    token: str,
    domain: str,
    service: str,
    *,
    service_data: dict[str, Any] | None = None,
    target: dict[str, Any] | None = None,
    return_response: bool = False,
) -> Any:
    fields: dict[str, Any] = {
        "domain": domain,
        "service": service,
    }
    if service_data:
        fields["service_data"] = service_data
    if target:
        fields["target"] = target
    if return_response:
        fields["return_response"] = True

    with HAWebSocketClient(ha_url, token) as client:
        return client.send_command("call_service", **fields)


def main() -> int:
    parser = argparse.ArgumentParser(description="Home Assistant WebSocket API client")
    parser.add_argument("--ha-url", required=True)
    parser.add_argument("--ha-token", required=True)
    sub = parser.add_subparsers(dest="command", required=True)

    auth_parser = sub.add_parser("auth-test", help="Verify WebSocket authentication")
    auth_parser.set_defaults(func=lambda args: _cmd_auth_test(args))

    query_parser = sub.add_parser("query", help="Send a WebSocket query command")
    query_parser.add_argument("--type", required=True, dest="msg_type")
    query_parser.add_argument("--data", default="{}", help="JSON object with extra fields")
    query_parser.set_defaults(func=lambda args: _cmd_query(args))

    service_parser = sub.add_parser("call-service", help="Call a Home Assistant service")
    service_parser.add_argument("domain")
    service_parser.add_argument("service")
    service_parser.add_argument("--data", default="{}", help="service_data JSON object")
    service_parser.add_argument("--target", default="", help="target JSON object")
    service_parser.set_defaults(func=lambda args: _cmd_call_service(args))

    register_parser = sub.add_parser(
        "register-esphome",
        help="Complete ESPHome zeroconf discovery in Home Assistant",
    )
    register_parser.add_argument("--hostname", required=True)
    register_parser.add_argument(
        "--noise-psk",
        required=True,
        help="Device API encryption key (base64 noise_psk for HA)",
    )
    register_parser.add_argument(
        "--poll-timeout",
        type=float,
        default=90.0,
        help="Seconds to wait for HA discovery flow",
    )
    register_parser.set_defaults(func=lambda args: _cmd_register_esphome(args))

    args = parser.parse_args()
    try:
        args.func(args)
        return 0
    except HAWebSocketError as exc:
        print(f"[error] {exc}", file=sys.stderr)
        return 1


def _cmd_auth_test(args: argparse.Namespace) -> None:
    version = auth_test(args.ha_url, args.ha_token)
    print(f"Home Assistant {version}")


def _cmd_query(args: argparse.Namespace) -> None:
    fields = json.loads(args.data)
    result = query(args.ha_url, args.ha_token, args.msg_type, fields)
    json.dump(result, sys.stdout)
    print()


def _cmd_register_esphome(args: argparse.Namespace) -> None:
    result = register_esphome_device(
        args.ha_url,
        args.ha_token,
        args.hostname,
        args.noise_psk,
        poll_timeout=args.poll_timeout,
    )
    status = result.get("status")
    if status == "reconfigured":
        print(f"[OK] Home Assistant reconfigured {args.hostname}")
        return
    if status in {"already_registered", "already_configured"}:
        print(f"[OK] Home Assistant already has {args.hostname}")
        return
    title = (result.get("result") or {}).get("title", args.hostname)
    print(f"[OK] Home Assistant registered: {title}")


def _cmd_call_service(args: argparse.Namespace) -> None:
    service_data = json.loads(args.data) if args.data else None
    target = json.loads(args.target) if args.target else None
    result = call_service(
        args.ha_url,
        args.ha_token,
        args.domain,
        args.service,
        service_data=service_data,
        target=target,
    )
    json.dump(result, sys.stdout)
    print()


if __name__ == "__main__":
    raise SystemExit(main())