#!/usr/bin/env python3
"""Stream raw serial logs from an ESP device -- no ESPHome YAML needed.

Usage: serial-logs.py [options] <port> [baud]
  --reconnect           Retry on port open/read error instead of exiting
  --stop-on <string>    Exit 0 when <string> appears in a line
  --timestamps          Prefix each line with an ISO 8601 timestamp
  --log-file <path>     Also write timestamped output to <path>
"""
import sys
import time
import serial
from datetime import datetime


def _now() -> str:
    return datetime.now().astimezone().isoformat(timespec='seconds')


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print("usage: serial-logs.py [--reconnect] [--stop-on <string>] "
              "[--timestamps] [--log-file <path>] <port> [baud]",
              file=sys.stderr)
        return 64

    reconnect = False
    stop_on: bytes | None = None
    timestamps = False
    log_file: str | None = None
    positional = []
    i = 0
    while i < len(args):
        if args[i] == "--reconnect":
            reconnect = True
            i += 1
        elif args[i] == "--stop-on" and i + 1 < len(args):
            stop_on = args[i + 1].encode()
            i += 2
        elif args[i] == "--timestamps":
            timestamps = True
            i += 1
        elif args[i] == "--log-file" and i + 1 < len(args):
            log_file = args[i + 1]
            i += 2
        else:
            positional.append(args[i])
            i += 1

    if not positional:
        print("usage: serial-logs.py [--reconnect] [--stop-on <string>] "
              "[--timestamps] [--log-file <path>] <port> [baud]",
              file=sys.stderr)
        return 64

    port = positional[0]
    baud = int(positional[1]) if len(positional) > 1 else 115200

    log_fp = None
    if log_file:
        try:
            log_fp = open(log_file, 'a', encoding='utf-8')
            header = f"=== {_now()} serial log opened: {port} ===\n"
            log_fp.write(header)
            log_fp.flush()
        except OSError as exc:
            print(f"[ERROR] could not open log file {log_file}: {exc}", file=sys.stderr)
            return 1

    use_text = timestamps or (log_file is not None)

    try:
        while True:
            try:
                ser = serial.Serial(port, baud, timeout=1)
                ser.reset_input_buffer()
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
                    if not data:
                        continue
                    if use_text:
                        line = data.decode('utf-8', errors='replace').rstrip('\r\n')
                        ts = _now()
                        output = f"{ts} {line}\n"
                        sys.stdout.write(output)
                        sys.stdout.flush()
                        if log_fp:
                            log_fp.write(output)
                            log_fp.flush()
                    else:
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
    finally:
        if log_fp:
            try:
                log_fp.write(f"=== {_now()} serial log closed: {port} ===\n")
                log_fp.close()
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
