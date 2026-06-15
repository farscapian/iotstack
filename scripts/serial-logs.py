#!/usr/bin/env python3
"""Stream raw serial logs from an ESP device — no ESPHome YAML needed.

Usage: serial-logs.py <port> [baud]   (baud defaults to 115200)
"""
import sys

import serial


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: serial-logs.py <port> [baud]", file=sys.stderr)
        return 64
    port = sys.argv[1]
    baud = int(sys.argv[2]) if len(sys.argv) > 2 else 115200
    try:
        ser = serial.Serial(port, baud, timeout=1)
    except Exception as exc:  # noqa: BLE001
        print(f"[ERROR] could not open {port}: {exc}", file=sys.stderr)
        return 1
    try:
        while True:
            data = ser.readline()
            if data:
                sys.stdout.buffer.write(data)
                sys.stdout.flush()
    except KeyboardInterrupt:
        return 0
    finally:
        ser.close()


if __name__ == "__main__":
    sys.exit(main())
