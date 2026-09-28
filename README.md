# Campus Bus Tracker

Live tracking for the 6 campus buses. Buses run only inside campus.

Until the ESP32 GPS modules are ready, a phone runs the **publisher** app to act
as a bus's GPS. Students use the **tracker** app to see buses live.

## Structure

```
data/                 Canonical data (edit here, then run ./sync_data.sh)
  stops.json          8 stops — FILL IN lat/lng
  buses.json          the 6 buses
  routes.json         9 directed routes (ordered stop lists)
  schedule.json       every departure time from the timetable PDF
supabase/migrations/  Database schema (run once in Supabase)
tracker/              Flutter app: student-facing live map + trip planner
publisher/            Flutter app: dummy GPS sender (pick a bus, share location)
sync_data.sh          Copies data/ into both apps' assets
```

## Setup

### 1. Database
Run both files in the Supabase SQL Editor (Dashboard → SQL Editor), in order:
- `supabase/migrations/0001_init.sql` — live positions table + realtime
- `supabase/migrations/0002_analytics.sql` — stop arrival/departure log

### 2. Stop coordinates
Edit `data/stops.json` and fill each stop's `lat`/`lng` (decimal degrees from
Google Maps). Then:
```bash
./sync_data.sh
```

### 3. Run the apps
```bash
cd publisher && flutter run   # on the "bus" phone: pick a bus, Start sharing
cd tracker   && flutter run   # student device: live map + trip planner
```

## How it works

- **Publisher** reads the phone GPS and upserts one row per bus into
  `bus_positions` (lat, lng, speed, heading), with a 12s heartbeat so a parked
  bus stays "live". It also logs `bus_stop_events` (arrival/departure) as the
  bus enters/leaves each stop's 40 m radius.
- **Tracker** subscribes to `bus_positions` via Supabase Realtime. A bus whose
  latest row is older than **5 minutes** is shown greyed out and treated as
  offline. Bus markers rotate to the travel direction inferred from the route.
- **Trip planner**: pick boarding + destination. The app finds the next bus
  heading to your boarding point, shows a "where's my bus" progress bar for the
  incoming leg, and estimates arrival from live GPS speed — or, when the bus is
  waiting at a terminal, from the timetable departure time plus average speed.

## Notes / TODO
- SOMS routing: the `(S)` trips in `schedule.json` are flagged but SOMS's place
  in the stop order isn't in the PDF. Provide it to enable SOMS routes.
- The Supabase publishable key in each app's `lib/config.dart` is client-safe
  (Row Level Security controls access). No login yet — anyone can publish; add
  driver auth before real deployment.
