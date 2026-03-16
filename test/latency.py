#!/usr/bin/env python3

import argparse
import json
import os
import socket
import statistics
import subprocess
import sys
import time
from typing import Any


def percentile(values: list[float], p: float) -> float | None:
    if not values:
        return None
    values_sorted = sorted(values)
    if len(values_sorted) == 1:
        return float(values_sorted[0])

    k = (len(values_sorted) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(values_sorted) - 1)
    if f == c:
        return float(values_sorted[f])
    return float(values_sorted[f] + (values_sorted[c] - values_sorted[f]) * (k - f))


def cmd_tcp_connect(args: argparse.Namespace) -> int:
    lat_ms: list[float] = []
    success = 0
    failures = 0

    for _ in range(args.count):
        start = time.perf_counter()
        sock: socket.socket | None = None
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.settimeout(args.timeout_s)
            if args.source_ip:
                sock.bind((args.source_ip, 0))
            sock.connect((args.host, args.port))
            dt_ms = (time.perf_counter() - start) * 1000.0
            lat_ms.append(dt_ms)
            success += 1
        except Exception:
            failures += 1
        finally:
            if sock is not None:
                try:
                    sock.close()
                except Exception:
                    pass
        if args.sleep_s > 0:
            time.sleep(args.sleep_s)

    out: dict[str, Any] = {
        "host": args.host,
        "port": args.port,
        "count": args.count,
        "success": success,
        "failures": failures,
        "failure_rate": (failures / args.count) if args.count else None,
        "timeout_s": args.timeout_s,
        "sleep_s": args.sleep_s,
        "source": args.source_ip,
        "min_ms": min(lat_ms) if lat_ms else None,
        "avg_ms": (sum(lat_ms) / len(lat_ms)) if lat_ms else None,
        "max_ms": max(lat_ms) if lat_ms else None,
        "stdev_ms": statistics.pstdev(lat_ms) if len(lat_ms) > 1 else (0.0 if lat_ms else None),
        "p50_ms": percentile(lat_ms, 50),
        "p90_ms": percentile(lat_ms, 90),
        "p99_ms": percentile(lat_ms, 99),
    }

    print(json.dumps(out, indent=2, sort_keys=True))
    return 0


def cmd_ping(args: argparse.Namespace) -> int:
    cmd = ["ping", "-c", str(args.count)]
    if args.iface:
        cmd += ["-I", args.iface]
    cmd.append(args.host)

    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output = proc.stdout

    transmitted = received = None
    packet_loss_percent = None
    rtt_min = rtt_avg = rtt_max = rtt_mdev = None

    for line in output.splitlines():
        if "packets transmitted" in line and "packet loss" in line:
            # e.g. "50 packets transmitted, 50 received, 0% packet loss, time 10087ms"
            parts = line.split(",")
            try:
                transmitted = int(parts[0].split()[0])
                received = int(parts[1].split()[0])
                packet_loss_percent = float(parts[2].strip().split("%", 1)[0])
            except Exception:
                pass
        if line.strip().startswith("rtt min/avg/max"):
            # e.g. "rtt min/avg/max/mdev = 2.158/17.310/453.490/69.018 ms"
            try:
                stats = line.split("=", 1)[1].strip().split()[0]
                a, b, c, d = stats.split("/")
                rtt_min, rtt_avg, rtt_max, rtt_mdev = map(float, (a, b, c, d))
            except Exception:
                pass

    out: dict[str, Any] = {
        "host": args.host,
        "count": args.count,
        "iface": args.iface,
        "exit_code": proc.returncode,
        "transmitted": transmitted,
        "received": received,
        "packet_loss_percent": packet_loss_percent,
        "rtt_min_ms": rtt_min,
        "rtt_avg_ms": rtt_avg,
        "rtt_max_ms": rtt_max,
        "rtt_mdev_ms": rtt_mdev,
    }

    if args.include_raw:
        out["raw"] = output

    print(json.dumps(out, indent=2, sort_keys=True))
    return 0 if proc.returncode == 0 else proc.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description="Latency measurement helpers for openziti-5gc tests")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_tcp = sub.add_parser("tcp-connect", help="Measure TCP connect latency")
    p_tcp.add_argument("--host", default=os.environ.get("HOST", "10.10.5.2"))
    p_tcp.add_argument("--port", type=int, default=int(os.environ.get("PORT", "5201")))
    p_tcp.add_argument("--count", type=int, default=int(os.environ.get("COUNT", "100")))
    p_tcp.add_argument("--timeout-s", type=float, default=float(os.environ.get("TIMEOUT_S", "2.0")))
    p_tcp.add_argument("--sleep-s", type=float, default=float(os.environ.get("SLEEP_S", "0.05")))
    p_tcp.add_argument("--source-ip", default=os.environ.get("UEIP"))
    p_tcp.set_defaults(func=cmd_tcp_connect)

    p_ping = sub.add_parser("ping", help="Run ping and emit JSON summary")
    p_ping.add_argument("--host", default=os.environ.get("HOST", "10.10.5.2"))
    p_ping.add_argument("--count", type=int, default=int(os.environ.get("PING_COUNT", "50")))
    p_ping.add_argument("--iface", default=os.environ.get("IFACE", "uesimtun0"))
    p_ping.add_argument("--include-raw", action="store_true")
    p_ping.set_defaults(func=cmd_ping)

    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
