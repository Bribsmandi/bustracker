# Campus Bus Tracker

Live tracking for the 6 campus buses. Buses run only inside campus.

Each bus carries an ESP32 + GPS + SIM900A unit. A relay turns its plain-HTTP
posts into MQTT; a Raspberry Pi in a classroom does all the computation and
storage; students see the buses in the **tracker** app.

## Architecture

```
ESP32 ──HTTP POST + X-Sig──► relay.py ──►┌──────────────────────┐
  (2G, no TLS, every 5 s)    (public VM) │ Mosquitto (public VM)│
                                         │  campus/bus/+/gps    │◄──┐ subscribe
     mobile app ◄────MQTT / WSS──────────│  campus/live/#       │───┘ publish
                                         └──────────────────────┘
                                                    ▲ one outbound connection
                                              ┌─────┴──────────────────────┐
                                              │ Raspberry Pi (classroom)   │
                                              │  processor → SQLite        │
                                              │  FastAPI (REST, admin)     │
                                              └────────────────────────────┘
```

Three constraints shaped this:

1. **The SIM900A cannot do TLS, MQTT or WebSocket.** So the buses keep speaking
   plain signed HTTP, and `relay.py` translates. The firmware never changed.
2. **The Pi cannot be reached from the internet** — campus NAT, no public IP, no
   port forwarding. So it connects *outward* to a broker instead of listening,
   and the broker lives on the VM that was already running the relay.
3. **Positions must not be forgeable** over an unencrypted link. Each unit signs
   its body with a per-device HMAC secret that is never transmitted, and a
   monotonic counter blocks replay. The relay verifies both.

## Structure

```
data/            Canonical data (edit here, then run ./sync_data.sh)
  stops.json     8 stops with coordinates
  buses.json     the 6 buses
  routes.json    10 directed routes (ordered stop lists + surveyed polylines)
  schedule.json  every departure time from the timetable PDF
relay/           HTTP → MQTT relay (runs on the public VM)
  relay.py            verifies the device signature, republishes to MQTT
  simulate_device.py  pretends to be an ESP32, for testing without hardware
broker/          Mosquitto config for the public VM — the hub everything joins
pi/              The Raspberry Pi backend
  server/        FastAPI + asyncio: processor, pipeline, SQLite, REST API
  scripts/       backup, bus provisioning, trace replay
  systemd/       service units
tracker/         Flutter app: the student live map + trip planner (MQTT)
publisher/       Flutter app: a phone standing in for a tracker unit (test tool)
HARDWARE.md      The device contract — still accurate, do not change lightly
```

## Setup

Three machines, in this order:

1. **Broker** — [`broker/README.md`](broker/README.md). Mosquitto on the public
   VM with three credentials (`relay`, `processor`, `app`).
2. **Relay** — [`relay/`](relay/). Point `config.json` at the broker; the device
   endpoint and signing scheme are unchanged.
3. **Pi** — [`pi/README.md`](pi/README.md). Install the service, set
   `BUS_MQTT_HOST`/`BUS_MQTT_PASSWORD`, start it.

Then check the chain end to end without touching a bus:

```bash
relay/simulate_device.py --device esp32-01 --devices-file relay/devices.json \
  --route mbh_to_east
```

## How it works

- **Relay** verifies each device's HMAC signature and monotonic counter, then
  republishes the fix to `campus/bus/{id}/gps`. It also drives
  `campus/bus/{id}/status`, standing in for the MQTT Last Will the device cannot
  register itself.
- **Processor** (on the Pi) validates, smooths and route-matches every fix,
  infers which of the 10 directed routes the bus is on, detects stop arrivals and
  departures, accumulates distance, logs trips, and learns median segment travel
  times per hour of the week.
- **ETA** blends a live estimate (remaining route distance over smoothed speed,
  with a floor) against those learned segment times, weighted by how many samples
  exist. A bus waiting at a terminal uses the timetable instead.
- **Publishing** is change-driven, not a fixed stream: the Pi publishes
  `campus/live/buses`, `campus/live/stop/{id}` and `campus/live/config` as
  **retained** messages, so a phone gets current state the moment it subscribes,
  and nobody's mobile data is spent re-sending what they already have.
- **REST API** on the Pi covers what pub/sub is the wrong shape for: trip
  planning, analytics and admin. The live map needs none of it.

## Tests

```bash
cd pi/server && .venv/bin/python -m pytest tests/ -q   # 60 server tests
cd tracker   && flutter test                            # 74 app tests
cd publisher && flutter test                            # 12 signing tests
```

Server: geometry, validation, route matching and progress monotonicity, geofence
hysteresis, the parked/departed state machine, trip logging, distance accounting,
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
- **No TLS** on any leg yet. The bus→relay hop cannot have it (SIM900A); the
  broker hops should get it before production.
- SOMS routing: the `(S)` trips in `schedule.json` are flagged but SOMS's place
  in the stop order isn't in the PDF. Provide it to enable SOMS routes.
- Timetable exceptions (weekends, holidays, exam periods) are not modelled.
