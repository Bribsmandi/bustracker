from __future__ import annotations

from app.processor import Processor
from conftest import feed

T0 = 1790000000.0


def drive(processor: Processor, bus_id: str, route_id: str, *, start: float = T0,
          speed: float = 8.0, step_s: float = 1.0, from_m: float = 0.0,
          to_m: float | None = None) -> float:
    """Walk a bus along a route's surveyed polyline, one fix per step."""
    geom = processor.data.routes[route_id].geometry
    limit = geom.length_m if to_m is None else min(to_m, geom.length_m)
    t = start
    along = from_m
    while along <= limit:
        lat, lng, _ = geom.position_at(along)
        feed(processor, bus_id, lat, lng, t=t, spd=speed)
        along += speed * step_s
        t += step_s
    return t


def park(processor: Processor, bus_id: str, lat: float, lng: float, *, start: float,
         seconds: float = 60.0, drift_m: float = 3.0) -> float:
    """Hold a bus still, with the few metres of GPS wander a real unit shows."""
    t = start
    i = 0
    while t <= start + seconds:
        # Alternating offsets, inside the drift tolerance.
        d = (drift_m / 111_320.0) * (1 if i % 2 else -1)
        feed(processor, bus_id, lat + d, lng, t=t, spd=0.0)
        t += 2.0
        i += 1
    return t


# ------------------------------------------------------------- route matching


def test_progress_advances_monotonically_along_a_route(processor):
    geom = processor.data.routes["mbh_to_east"].geometry
    state = processor.live.get("bus1")
    seen: list[float] = []
    t = T0
    along = 0.0
    while along <= geom.length_m:
        lat, lng, _ = geom.position_at(along)
        feed(processor, "bus1", lat, lng, t=t, spd=8.0)
        seen.append(state.progress_m)
        along += 8.0
        t += 1.0

    assert seen == sorted(seen)
    assert state.progress_m > geom.length_m * 0.8


def test_route_is_inferred_without_the_bus_reporting_it(processor):
    drive(processor, "bus1", "mbh_to_east", to_m=300)
    assert processor.live.get("bus1").route_id == "mbh_to_east"


def test_jitter_does_not_rewind_progress(processor):
    t = drive(processor, "bus3", "lh_to_east", to_m=400)
    state = processor.live.get("bus3")
    high = state.progress_m

    geom = processor.data.routes["lh_to_east"].geometry
    # A fix that projects 10 m behind: inside tolerance, so progress must hold.
    lat, lng, _ = geom.position_at(max(0.0, high - 10))
    feed(processor, "bus3", lat, lng, t=t + 1, spd=6.0)
    assert state.progress_m >= high


def test_bus_only_matches_its_own_routes(processor):
    drive(processor, "ac_mbh", "ac_mbh_out", to_m=300)
    assert processor.live.get("ac_mbh").route_id in {"ac_mbh_out", "ac_arch_to_mbh"}


# -------------------------------------------------------------- stop geofence


def test_arrival_and_departure_are_logged_once(processor, db):
    library = processor.data.stops["library"]
    along = processor.data.routes["mbh_to_east"].stop_along["library"]
    t = park(processor, "bus1", library.lat, library.lng, start=T0, seconds=40)
    # Pull away from the stop, past the 60 m exit radius.
    drive(processor, "bus1", "mbh_to_east", start=t + 1, from_m=along, to_m=along + 200, speed=6.0)
    db.flush_now()

    rows = db.conn.execute(
        "SELECT stop_id, arrived_at, departed_at FROM stop_events WHERE bus_id='bus1'"
    ).fetchall()
    assert [r["stop_id"] for r in rows].count("library") == 1
    assert rows[0]["departed_at"] is not None


def test_jitter_on_the_boundary_does_not_emit_repeated_arrivals(processor, db):
    stop = processor.data.stops["atm_circle"]
    # Sit at ~45 m: past the 40 m enter radius, inside the 60 m exit radius.
    offset = 45 / 111_320.0
    t = T0
    for i in range(30):
        feed(processor, "bus1", stop.lat + offset, stop.lng, t=t, spd=0.2)
        t += 2.0
    db.flush_now()
    assert db.conn.execute("SELECT COUNT(*) c FROM stop_events").fetchone()["c"] == 0


def test_short_pass_by_does_not_count_as_an_arrival(processor, db):
    # 8 m/s through the stop: inside the radius for well under the dwell minimum.
    drive(processor, "bus1", "mbh_to_east", speed=8.0)
    db.flush_now()
    events = db.conn.execute("SELECT stop_id FROM stop_events").fetchall()
    assert "library" not in [e["stop_id"] for e in events]


# ------------------------------------------------------------------- journey


def test_parking_at_a_terminal_requires_a_settled_window(processor):
    mbh = processor.data.stops["mbh"]
    state = processor.live.get("bus1")

    park(processor, "bus1", mbh.lat, mbh.lng, start=T0, seconds=10)
    assert state.journey_state == "outbound"

    park(processor, "bus1", mbh.lat, mbh.lng, start=T0 + 12, seconds=60)
    assert state.journey_state == "parked"
    assert state.destination_id == "mbh"


def test_departure_needs_distance_and_sustained_speed(processor):
    mbh = processor.data.stops["mbh"]
    state = processor.live.get("bus1")
    t = park(processor, "bus1", mbh.lat, mbh.lng, start=T0, seconds=60)
    assert state.journey_state == "parked"

    # Creeping 30 m at 0.5 m/s: far enough, but not moving convincingly.
    geom = processor.data.routes["mbh_to_east"].geometry
    lat, lng, _ = geom.position_at(30)
    feed(processor, "bus1", lat, lng, t=t + 1, spd=0.5)
    assert state.journey_state == "parked"

    drive(processor, "bus1", "mbh_to_east", start=t + 2, from_m=35, to_m=120, speed=6.0)
    assert state.journey_state == "outbound"
    assert state.origin_id == "mbh"


def test_trip_opens_on_departure_and_closes_on_arrival(processor, db):
    mbh = processor.data.stops["mbh"]
    east = processor.data.stops["east_campus"]
    route = processor.data.routes["mbh_to_east"]

    t = park(processor, "bus1", mbh.lat, mbh.lng, start=T0, seconds=60)
    t = drive(processor, "bus1", "mbh_to_east", start=t + 1, from_m=30, speed=8.0)
    db.flush_now()
    open_trip = db.conn.execute(
        "SELECT id, origin_id, arrived_at FROM trips WHERE bus_id='bus1'"
    ).fetchone()
    assert open_trip is not None
    assert open_trip["origin_id"] == "mbh"
    assert open_trip["arrived_at"] is None

    park(processor, "bus1", east.lat, east.lng, start=t + 1, seconds=60)
    db.flush_now()
    closed = db.conn.execute("SELECT * FROM trips WHERE id=?", (open_trip["id"],)).fetchone()
    assert closed["arrived_at"] is not None
    assert closed["destination_id"] == "east_campus"
    assert closed["distance_m"] > route.length_m * 0.5


# ------------------------------------------------------------------ distance


def test_parked_drift_does_not_inflate_distance(processor):
    mbh = processor.data.stops["mbh"]
    state = processor.live.get("bus1")
    park(processor, "bus1", mbh.lat, mbh.lng, start=T0, seconds=300, drift_m=12.0)
    assert state.day_distance_m == 0.0


def test_distance_tracks_the_route_length(processor):
    route = processor.data.routes["lh_to_east"]
    drive(processor, "bus3", "lh_to_east", speed=8.0)
    travelled = processor.live.get("bus3").day_distance_m
    assert route.length_m * 0.85 < travelled < route.length_m * 1.15


# -------------------------------------------------------------------- status


def test_status_degrades_with_age(processor, cfg):
    """Thresholds are sized against the hardware's 5 s fix interval, so one
    missed fix still reads as live and a 2G reconnect is not reported offline."""
    state = processor.live.get("bus1")
    feed(processor, "bus1", 11.317194, 75.937560, t=T0)
    assert state.status(cfg, T0 + 6) == "live"
    assert state.status(cfg, T0 + 11) == "live"
    assert state.status(cfg, T0 + 20) == "delayed"
    assert state.status(cfg, T0 + 60) == "stale"
    assert state.status(cfg, T0 + 200) == "offline"


def test_last_will_marks_a_bus_offline_immediately(processor, cfg):
    feed(processor, "bus1", 11.317194, 75.937560, t=T0)
    processor.handle_status("bus1", "offline")
    assert processor.live.get("bus1").status(cfg, T0 + 1) == "offline"
    processor.handle_status("bus1", "online")
    assert processor.live.get("bus1").status(cfg, T0 + 1) == "live"
