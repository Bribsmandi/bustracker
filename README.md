# Campus Bus Tracker

Live tracking for the 6 campus buses. Buses run only inside campus.

Each bus carries an ESP32 + GPS + SIM900A unit. A relay turns its plain-HTTP
posts into MQTT; a Raspberry Pi in a classroom does all the computation and
storage; students see the buses in the **tracker** app.

## Architecture

```
ESP32 ──signed MQTT :1883──►┌────────────────────┐
  (2G, no TLS, every 5 s)   │  broker.emqx.io    │
                            │  public, free      │
   tracker app ◄────────────│  nothing to run    │
                            └─────────▲──────────┘
                                      │ one outbound connection
                            ┌─────────┴────────────────────┐
                            │ Raspberry Pi (phone hotspot) │
                            │  verify → process → SQLite   │
                            │  publishes finished state    │
                            └──────────────────────────────┘
```

Three constraints shaped this:

1. **Nothing here can accept an inbound connection.** The buses are on cellular
   NAT and the Pi runs on a phone hotspot, so there is no port to forward and no
   public IP anywhere. Every party dials *out* to a common meeting point.
2. **The SIM900A has no TLS**, which rules out every managed broker — their free
   tiers are TLS-only. A public plaintext broker is what the hardware can reach.
3. **Positions must not be forgeable**, and on a public broker anyone can
   publish. Each unit signs its body with a per-device HMAC secret that is never
   transmitted; a monotonic counter blocks replay. The Pi verifies both before
   anything reaches the state machine.

There is no server to rent, deploy, patch or keep alive.

## Structure

```
data/            Canonical data (edit here, then run ./sync_data.sh)
  stops.json     8 stops with coordinates
  buses.json     the 6 buses
  routes.json    10 directed routes (ordered stop lists + surveyed polylines)
  schedule.json  every departure time from the timetable PDF
pi/              The Raspberry Pi backend
  server/        FastAPI + asyncio: processor, pipeline, SQLite, REST API
  scripts/       deploy, backup, trace replay
  systemd/       service units
relay/           Unused by this design. Kept as a fallback if the buses ever
broker/          go back to HTTP and a self-hosted broker.
tracker/         Flutter app: the student live map + trip planner (MQTT)
publisher/       Flutter app: a phone standing in for a tracker unit (test tool)
HARDWARE.md      The device contract — still accurate, do not change lightly
```

## Setup

One machine: the Pi. See [`pi/README.md`](pi/README.md).

```bash
sudo git clone -b pi-backend <url> /opt/bustracker
sudo /opt/bustracker/pi/scripts/deploy_pi.sh
```

Then drive a bus without hardware, signing exactly as the firmware does:

```bash
pi/scripts/replay_trace.py --bus bus1 --route mbh_to_east \
  --devices-file relay/devices.json
```

## How it works

- **Buses** publish `<root>/bus/{id}/gps` directly, signed. Their MQTT Last Will
  marks them offline the moment the broker notices them gone.
- **Processor** (on the Pi) verifies the signature and counter first — on a
  public broker an unverified message is not evidence of anything — then validates, smooths and route-matches every fix,
  infers which of the 10 directed routes the bus is on, detects stop arrivals and
  departures, accumulates distance, logs trips, and learns median segment travel
  times per hour of the week.
- **ETA** blends a live estimate (remaining route distance over smoothed speed,
  with a floor) against those learned segment times, weighted by how many samples
  exist. A bus waiting at a terminal uses the timetable instead.
- **Publishing** is change-driven, not a fixed stream: the Pi publishes
  `<root>/live/buses`, `<root>/live/stop/{id}` and `<root>/live/config` as
  **retained** messages, so a phone gets current state the moment it subscribes,
  and nobody's mobile data is spent re-sending what they already have.
- **REST API** on the Pi covers what pub/sub is the wrong shape for: trip
  planning, analytics and admin. The live map needs none of it.

## Tests

```bash
cd pi/server && .venv/bin/python -m pytest tests/ -q   # 84 server tests
cd tracker   && flutter test                            # 74 app tests
cd publisher && flutter test                            # 14 signing tests
```

Server: signature verification and forgery rejection, geometry, validation,
route matching and progress monotonicity, geofence hysteresis, the parked/departed state machine, trip logging, distance accounting,
ETA blending, the REST API, and the relay↔Pi payload contract.

App: route projection, marker orientation, boarding logic, timetable handling, and
the server payload contract — whose fixture is a verbatim capture from the Python
processor, so a server change that would break the app fails in CI rather than on
a phone.

Publisher: HMAC signing, pinned against a digest computed independently by
`openssl` and Python.

Against a real broker with a real Pi behind it:

```bash
cd tracker && flutter test test_live/live_broker_test.dart
```

## Notes / TODO

- **Device secrets are in git history** (`relay/devices.json`). They are what
  prevents position forgery — rotate before relying on the system. Deferred as a
  prototype decision.
- **No TLS and a public broker.** The SIM900A cannot do TLS, and free managed
  brokers are TLS-only. Positions cannot be forged (HMAC) but anyone can read
  them, and the broker has no SLA. Fine for a demo; move to a private broker
  before anyone depends on it.
- SOMS routing: the `(S)` trips in `schedule.json` are flagged but SOMS's place
  in the stop order isn't in the PDF. Provide it to enable SOMS routes.
- Timetable exceptions (weekends, holidays, exam periods) are not modelled.
