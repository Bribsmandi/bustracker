# tracker — the student app

The live map students use. Shows where the 6 campus buses are, which way they are
going, and when the next one reaches a chosen stop.

## Where its data comes from

It subscribes to MQTT. Everything arrives already computed by the Raspberry Pi —
validated, smoothed, matched to a route, with the next stop and ETA worked out —
so the app renders an answer rather than deriving one. That keeps the maths in one
place, means every phone agrees, and lets a fix ship without an app release.

| Topic | Carries | Retained |
|---|---|---|
| `campus/live/buses` | every bus: position, heading, route, status, next stop, ETA | yes |
| `campus/live/config` | stops, routes, timetable | yes |
| `campus/live/stop/{id}` | arrival estimates for one stop | yes |

Retained matters: the current state of the fleet lands the moment the app
subscribes, so there is no "fetch once then subscribe" step and no window where
the map is blank but the connection is healthy.

## Configure before building

Set the broker host and the read-only `app` credential in
[`lib/config.dart`](lib/config.dart). That credential ships inside the app, so
treat it as public — the broker ACL limits it to subscribing to `campus/live/#`.
It cannot be used to inject a bus position: those are signed by the hardware and
verified by the relay before they are ever published.

Set `useWebSocket = true` to reach the broker over WebSocket on port 9001 instead
of native MQTT on 1883 — useful on networks that only allow 443-style traffic.

Flutter **web** is not supported: it would need `mqtt_browser_client`, whose
`dart:js_interop` dependency cannot be compiled for Android or iOS, so it is
deliberately not imported. Web would need a conditional import to add back.

## Run

```bash
flutter pub get
flutter run
```

The bundled `assets/data/` JSON is the offline fallback when the broker is
unreachable; `campus/live/config` overrides it when connected. Refresh the
bundled copy with `../sync_data.sh`.

## Tests

```bash
flutter test          # 74 tests, no network needed
```

Covers geometry, route projection, marker orientation, boarding logic, timetable
handling, and the server payload contract in
[`test/live_payload_test.dart`](test/live_payload_test.dart) — whose fixture is a
verbatim capture from the Python processor, so a server-side change that would
break the app fails there instead of on a phone.

Against a real broker with a real Pi behind it:

```bash
flutter test test_live/live_broker_test.dart
# or point it somewhere else:
BROKER_HOST=127.0.0.1 BROKER_PORT=18830 BROKER_USER= BROKER_PASS= \
  flutter test test_live/live_broker_test.dart
```

That one is kept outside `test/` because it needs a live server, so the normal
suite stays offline and fast.

## What the user sees

- **Live map** — OpenStreetMap tiles, a baked local basemap, each bus as a
  coloured side-view marker rotated to its direction of travel.
- **Status** — `live` normally; `delayed` with a "last seen" label after a missed
  fix; greyed out when `stale` or `offline`. The server decides this, so a wrong
  phone clock cannot distort it.
- **Trip planner** — pick boarding and destination; get the next suitable bus,
  wait time and ride time, with a progress bar for the incoming leg.
- **Timetable fallback** — printed departure times when no bus is tracked, marked
  as unconfirmed so a guess is never shown as a live estimate.
- **Server unreachable banner** — an empty map is ambiguous, so the app says
  explicitly when it cannot reach the server and falls back to the timetable.
- **Simulator** — a debug toggle driving six fake buses locally, behind a loud
  amber banner so it can never be mistaken for live data.
