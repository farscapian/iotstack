#!/usr/bin/env python3
"""Stream raw serial logs from an ESP device -- no ESPHome YAML needed.

Usage: serial-logs.py [options] <port> [baud]
  --reconnect           Retry on port open/read error instead of exiting
  --stop-on <string>    Exit 0 when <string> appears in a line
"""
import sys
import time
import serial


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print("usage: serial-logs.py [--reconnect] [--stop-on <string>] <port> [baud]",
              file=sys.stderr)
        return 64

    reconnect = False
    stop_on: bytes | None = None
    positional = []
    i = 0
    while i < len(args):
        if args[i] == "--reconnect":
            reconnect = True
            i += 1
        elif args[i] == "--stop-on" and i + 1 < len(args):
            stop_on = args[i + 1].encode()
            i += 2
        else:
            positional.append(args[i])
            i += 1

    if not positional:
        print("usage: serial-logs.py [--reconnect] [--stop-on <string>] <port> [baud]",
              file=sys.stderr)
        return 64

    port = positional[0]
    baud = int(positional[1]) if len(positional) > 1 else 115200

    while True:
        try:
            ser = serial.Serial(port, baud, timeout=1)
        except Exception as exc:  # noqa: BLE001
            if reconnect:
                print(f"[serial-logs] waiting for {port}: {exc}", file=sys.stderr)
                time.sleep(1)
                continue
            print(f"[ERROR] could not open {port}: {exc}", file=sys.stderr)
            return 1
        try:
            while True:
                data = ser.readline()
                if data:
                    sys.stdout.buffer.write(data)
                    sys.stdout.flush()
                    if stop_on and stop_on in data:
                        ser.close()
                        return 0
        except KeyboardInterrupt:
            ser.close()
            return 0
        except Exception:  # noqa: BLE001
            ser.close()
            if reconnect:
                time.sleep(1)
                continue
            return 1


if __name__ == "__main__":
    sys.exit(main())
