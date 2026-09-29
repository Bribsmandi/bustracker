#!/usr/bin/env python3
"""Pretend to be one of the ESP32 units.

Speaks exactly the contract in HARDWARE.md — signed plain-HTTP POST, monotonic
counter, metres per second, `hdg: null` when unknown — so it exercises the real
path: device -> relay -> MQTT -> Pi. Nothing else simulates the signature, which
is where firmware bugs usually are.

    # drive bus1 along its route, one fix every 5 s as the spec requires
    ./simulate_device.py --device esp32-01 --secret <hex> --route mbh_to_east

    # just prove the relay is up and the signature is right
    ./simulate_device.py --device esp32-01 --secret <hex> --once

Secrets come from the relay's devices.json. Pass --url to point at a local relay
instead of the deployed one.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import random
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "pi" / "server"))

from app.config import Settings  # noqa: E402
from app.static_data import StaticData  # noqa: E402

DEFAULT_URL = "http://recverse.ibinujaleel.dev:8081/p"
METRES_PER_DEG = 111_320.0


def post(url: str, secret: str, body: dict, timeout: float = 10.0) -> tuple[int, str]:
    # Sign the exact bytes transmitted. Re-serialising after signing is the usual
    # cause of "bad signature" (HARDWARE.md §5).
    raw = json.dumps(body, separators=(",", ":")).encode()
    sig = hmac.new(secret.encode(), raw, hashlib.sha256).hexdigest()
    req = urllib.request.Request(
        url,
        data=raw,
        headers={"Content-Type": "application/json", "X-Sig": sig},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except (urllib.error.URLError, OSError) as e:
        # The relay being unreachable is an ordinary outcome here, not a crash:
        # it is exactly what the firmware sees in a campus dead spot.
        return 0, f"unreachable: {e}"


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--device", required=True, help="device id, e.g. esp32-01")
    ap.add_argument("--secret", help="device secret (hex); or use --devices-file")
    ap.add_argument(
        "--devices-file", type=Path, help="read the secret from a devices.json"
    )
    ap.add_argument("--bus", help="bus id; defaults to the one bound in devices.json")
    ap.add_argument("--url", default=DEFAULT_URL)
    ap.add_argument("--route", help="walk this route's surveyed polyline")
    ap.add_argument("--once", action="store_true", help="send a single fix and exit")
    ap.add_argument("--interval", type=float, default=5.0, help="seconds between fixes (spec: 5)")
    ap.add_argument("--speed", type=float, default=8.0, help="m/s along the route")
    ap.add_argument("--dwell", type=float, default=60.0, help="seconds held still at each end")
    ap.add_argument("--noise", type=float, default=3.0, help="metres of GPS jitter")
    ap.add_argument("--loop", action="store_true", help="repeat the route until interrupted")
    args = ap.parse_args()

    secret = args.secret
    bus_id = args.bus
    if args.devices_file:
        devices = json.loads(args.devices_file.read_text())
        entry = devices.get(args.device)
        if entry is None:
            print(f"{args.device} not in {args.devices_file}", file=sys.stderr)
            return 2
        secret = secret or entry["secret"]
        bus_id = bus_id or entry["bus_id"]
    if not secret:
        print("need --secret or --devices-file", file=sys.stderr)
        return 2
    if not bus_id:
        print("need --bus or --devices-file", file=sys.stderr)
        return 2

    # §5: a counter that must increase forever. GPS seconds is the scheme the
    # spec recommends, and it survives a restart for free.
    counter = int(time.time())

    def send(lat: float, lng: float, spd: float, hdg: float | None) -> bool:
        nonlocal counter
        counter += 1
        body = {"b": bus_id, "d": args.device, "c": counter, "lat": round(lat, 6),
                "lng": round(lng, 6), "spd": round(spd, 2), "hdg": hdg}
        status, text = post(args.url, secret, body)
        ok = status == 200
        print(f"{status} {text.strip()}  c={counter} lat={lat:.6f} lng={lng:.6f} spd={spd:.1f}")
        return ok

    if args.once:
        data = StaticData(Settings())
        home = data.buses[bus_id].home_terminal if bus_id in data.buses else "mbh"
        stop = data.stops[home]
        return 0 if send(stop.lat, stop.lng, 0.0, None) else 1

    if not args.route:
        print("need --route, or use --once", file=sys.stderr)
        return 2

    data = StaticData(Settings())
    if args.route not in data.routes:
        print(f"unknown route {args.route!r}", file=sys.stderr)
        return 2
    geom = data.routes[args.route].geometry

    def jitter() -> float:
        return random.uniform(-args.noise, args.noise) / METRES_PER_DEG

    try:
        while True:
            for phase in ("start", "drive", "end"):
                if phase in ("start", "end"):
                    along = 0.0 if phase == "start" else geom.length_m
                    lat, lng, _ = geom.position_at(along)
                    for _ in range(max(1, int(args.dwell / args.interval))):
                        send(lat + jitter(), lng + jitter(), 0.0, None)
                        time.sleep(args.interval)
                else:
                    along = 0.0
                    while along <= geom.length_m:
                        lat, lng, hdg = geom.position_at(along)
                        send(lat + jitter(), lng + jitter(), args.speed, round(hdg, 1))
                        along += args.speed * args.interval
                        time.sleep(args.interval)
            if not args.loop:
                break
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
