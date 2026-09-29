#!/usr/bin/env python3
"""Publish a GPS trace over MQTT so the whole pipeline can be exercised
without a bus.

Two sources:

  --route mbh_to_east     walk the surveyed polyline from data/routes.json
  --file trace.jsonl      replay a recording (one JSON fix per line)

A synthetic route walk is enough to check progress, stop events, trips and ETAs.
Record real traces with the publisher app to get genuine GPS noise.

    ./replay_trace.py --bus bus1 --route mbh_to_east --user bus1 --password ...
    ./replay_trace.py --bus bus1 --file traces/morning.jsonl --rate 10

--dwell holds the bus still at each end so the parked/departed transitions fire:
they deliberately need a settled window, so a walk that starts moving instantly
never opens a trip.
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import random
import sys
import time
from pathlib import Path

import paho.mqtt.client as mqtt

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "pi" / "server"))

from app.config import Settings  # noqa: E402
from app.static_data import StaticData  # noqa: E402

METRES_PER_DEG = 111_320.0


def synth_fixes(
    data: StaticData, route_id: str, speed: float, step_s: float, dwell_s: float, noise_m: float
) -> list[dict]:
    route = data.routes[route_id]
    geom = route.geometry
    fixes: list[dict] = []

    def emit(lat: float, lng: float, spd: float) -> None:
        jitter = noise_m / METRES_PER_DEG
        fixes.append(
            {
                "lat": lat + random.uniform(-jitter, jitter),
                "lng": lng + random.uniform(-jitter, jitter),
                "spd": round(spd, 2),
                "sats": random.randint(7, 11),
                "hdop": round(random.uniform(0.8, 1.6), 1),
            }
        )

    start_lat, start_lng, _ = geom.position_at(0.0)
    for _ in range(int(dwell_s / step_s)):
        emit(start_lat, start_lng, 0.0)

    along = 0.0
    while along <= geom.length_m:
        lat, lng, _ = geom.position_at(along)
        emit(lat, lng, speed)
        along += speed * step_s

    end_lat, end_lng, _ = geom.position_at(geom.length_m)
    for _ in range(int(dwell_s / step_s)):
        emit(end_lat, end_lng, 0.0)

    return fixes


def load_fixes(path: Path) -> list[dict]:
    fixes = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                fixes.append(json.loads(line))
    return fixes


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bus", required=True, help="bus id, e.g. bus1")
    ap.add_argument("--device", default="", help="device id to sign as, e.g. esp32-01")
    ap.add_argument("--secret", default="", help="that device's HMAC secret")
    ap.add_argument("--devices-file", type=Path, help="read device and secret from a devices.json")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--route", help="route id from data/routes.json")
    src.add_argument("--file", type=Path, help="recorded trace, one JSON fix per line")
    ap.add_argument("--host", default="broker.emqx.io")
    ap.add_argument("--root", default="cbt7f3c9e21b", help="topic root; must match the server")
    ap.add_argument("--port", type=int, default=1883)
    ap.add_argument("--user", default="")
    ap.add_argument("--password", default="")
    ap.add_argument("--ws", action="store_true", help="connect over WebSocket (port 9001 / the tunnel)")
    ap.add_argument("--speed", type=float, default=8.0, help="m/s for a synthesized walk")
    ap.add_argument("--step", type=float, default=1.0, help="seconds between fixes")
    ap.add_argument("--dwell", type=float, default=40.0, help="seconds held still at each end")
    ap.add_argument("--noise", type=float, default=3.0, help="metres of jitter to add")
    ap.add_argument("--rate", type=float, default=1.0, help="speed-up factor; 0 sends as fast as possible")
    ap.add_argument("--loop", action="store_true", help="repeat until interrupted")
    ap.add_argument("--dry-run", action="store_true", help="print instead of publishing")
    args = ap.parse_args()

    cfg = Settings()
    data = StaticData(cfg)
    if args.bus not in data.buses:
        print(f"unknown bus {args.bus!r}; expected one of {', '.join(data.buses)}", file=sys.stderr)
        return 2
    if args.route and args.route not in data.routes:
        print(f"unknown route {args.route!r}", file=sys.stderr)
        return 2

    fixes = (
        load_fixes(args.file)
        if args.file
        else synth_fixes(data, args.route, args.speed, args.step, args.dwell, args.noise)
    )
    if not fixes:
        print("no fixes to send", file=sys.stderr)
        return 1

    # Must match the server's BUS_TOPIC_ROOT.
    root = args.root
    topic = f"{root}/bus/{args.bus}/gps"
    status_topic = f"{root}/bus/{args.bus}/status"

    device_id, secret = args.device, args.secret
    if args.devices_file:
        devices = json.loads(args.devices_file.read_text())
        for did, entry in devices.items():
            if entry.get("bus_id") == args.bus:
                device_id, secret = did, entry["secret"]
                break
    if not secret:
        print("need --secret (with --device) or --devices-file: the server "
              "rejects unsigned fixes", file=sys.stderr)
        return 2

    client = None
    if not args.dry_run:
        client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"replay-{args.bus}-{random.randint(1000, 9999)}",
            transport="websockets" if args.ws else "tcp",
        )
        if args.user:
            client.username_pw_set(args.user, args.password)
        client.will_set(status_topic, "offline", qos=1, retain=True)
        client.connect(args.host, args.port, keepalive=10)
        client.loop_start()
        client.publish(status_topic, "online", qos=1, retain=True)

    delay = 0.0 if args.rate == 0 or args.dry_run else args.step / args.rate
    seq = int(time.time()) % 1_000_000
    sent = 0

    try:
        while True:
            for fix in fixes:
                seq += 1
                # Same shape and signature the firmware produces, so the server
                # cannot tell a replay from a real bus.
                body = json.dumps(
                    {
                        "b": args.bus,
                        "d": device_id,
                        "c": seq,
                        "lat": round(fix["lat"], 6),
                        "lng": round(fix["lng"], 6),
                        "spd": fix.get("spd", 0.0),
                        "hdg": fix.get("hdg"),
                    },
                    separators=(",", ":"),
                )
                sig = hmac.new(secret.encode(), body.encode(), hashlib.sha256).hexdigest()
                message = f"{sig}.{body}"
                if args.dry_run:
                    print(f"{topic} {message}")
                else:
                    client.publish(topic, message, qos=0)
                sent += 1
                if delay:
                    time.sleep(delay)
            if not args.loop:
                break
    except KeyboardInterrupt:
        print("\ninterrupted", file=sys.stderr)
    finally:
        if client is not None:
            client.publish(status_topic, "offline", qos=1, retain=True)
            time.sleep(0.2)
            client.loop_stop()
            client.disconnect()

    print(f"sent {sent} fix(es) to {topic}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
