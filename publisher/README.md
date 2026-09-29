# publisher — a phone standing in for a tracker unit

Development and field-test tool, **not** something students install. It does
exactly what the ESP32 firmware does and nothing more: read GPS, sign it, POST it
every 5 seconds.

Useful for proving the whole chain (relay → MQTT → Pi → tracker app) before
hardware is fitted, and for recording real GPS traces by driving the routes.

## What it no longer does

The old version claimed the bus, ran its own parked/departed state machine, and
opened and closed trip rows. The Raspberry Pi works all of that out from raw
positions now, so a phone and a real ESP32 produce identical results and there is
only one implementation to keep correct.

That is why there is no start/destination picker any more — the server infers
route and direction from the track.

## Configure before building

In [`lib/config.dart`](lib/config.dart), set:

- `relayUrl` — the relay endpoint (unchanged from the old design)
- `deviceId` and `deviceSecret` — issued per unit and registered in the relay's
  `devices.json`

The relay binds one device to one bus, so picking a different bus in the UI is
refused with `wrong bus`. The secret never leaves the phone: it signs the body and
is never transmitted.

## Run

```bash
flutter pub get
flutter run
```

Pick the bus, press **Start sharing**. On Android it runs as a foreground service
so it keeps reporting with the screen off — otherwise the OS suspends it the
moment the phone goes in a pocket and the bus silently goes offline.

The status card shows accepted/sent counts, the current counter, and the last
acceptance, so a signing or binding problem is obvious immediately.

## The wire protocol

Implemented per [`HARDWARE.md`](../HARDWARE.md):

```
POST /p
X-Sig: hex(HMAC_SHA256(device_secret, exact_body_bytes))

{"b":"bus1","d":"esp32-01","c":1234,"lat":11.3185,"lng":75.9379,"spd":6.4,"hdg":312}
```

- `c` increases forever, persisted, seeded from clock seconds — if it ever went
  backwards the relay would reject everything as a replay until it caught up.
- `spd` is metres per second, never km/h or knots.
- `hdg` is `null` when unknown, never `0` — zero means due north and would point
  every parked bus the same wrong way on the map.
- One socket is kept open; reconnecting every 5 s multiplies data and power use.

A `403` stops sharing immediately: a bad signature or wrong bus is a configuration
error, and retrying identical requests will never start working. A dropped network
is not fatal — the fix is dropped and the next one is fresher anyway.

## Tests

```bash
flutter test
```

[`test/uploader_test.dart`](test/uploader_test.dart) pins the signing against a
digest computed independently by `openssl dgst` and Python's `hmac`, so the Dart
implementation is checked against what the relay will actually compute rather than
against itself.

## Alternative without a phone

[`../relay/simulate_device.py`](../relay/simulate_device.py) does the same job from
a laptop, walking a bus along a surveyed route polyline.
