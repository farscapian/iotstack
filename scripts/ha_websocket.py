#!/usr/bin/env python3
"""Home Assistant WebSocket API client for iotstack.

Uses the public WebSocket API only (no REST).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
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