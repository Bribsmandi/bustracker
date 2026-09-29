from __future__ import annotations

from app.pipeline import eta as eta_mod
from conftest import feed
from test_pipeline import T0, drive, park


def test_live_eta_uses_a_speed_floor(processor, cfg, data):
    """A crawling bus must not produce an ETA of hours."""
    route = data.routes["mbh_to_east"]
    drive(processor, "bus1", "mbh_to_east", to_m=200, speed=8.0)
    state = processor.live.get("bus1")
    state.speed = 0.01

    next_stop, remaining = None, None
    from app.pipeline import map_match

    next_stop, remaining = map_match.next_stop(route, state.progress_m)
    est = eta_mod.to_stop(state, route, next_stop, data, cfg, processor.db, T0 + 100)
    assert est.seconds <= remaining / cfg.eta_min_speed_mps + 1


def test_unknown_stop_ahead_gives_no_eta(processor, cfg, data):
    route = data.routes["mbh_to_east"]
    drive(processor, "bus1", "mbh_to_east", speed=8.0)
    state = processor.live.get("bus1")
    # The origin is behind the bus, so it is not an upcoming arrival.
    est = eta_mod.to_stop(state, route, "mbh", data, cfg, processor.db, T0 + 500)
    assert est.seconds is None
    assert est.source == "none"


def test_history_pulls_the_estimate_towards_the_learned_time(processor, cfg, data, db):
    route = data.routes["lh_to_east"]
    drive(processor, "bus3", "lh_to_east", to_m=50, speed=8.0)
    state = processor.live.get("bus3")
    now = T0 + 60
    how = eta_mod.hour_of_week(now, cfg.timezone)

    live_only = eta_mod.to_stop(state, route, "centre_circle", data, cfg, db, now)
    assert live_only.source == "live"

    # A slow learned run for every segment up to the target stop.
    ordered = [s for s in route.stops if s in route.stop_along]
    for a, b in zip(ordered, ordered[1:]):
        for _ in range(cfg.eta_hist_full_samples):
            db.record_segment(route.id, a, b, how, 600.0)

    blended = eta_mod.to_stop(state, route, "centre_circle", data, cfg, db, now)
    assert blended.source == "blended"
    assert blended.confident
    assert blended.seconds > live_only.seconds


def test_parked_bus_waits_for_its_scheduled_departure(processor, cfg, data, db):
    route = data.routes["mbh_to_east"]
    mbh = data.stops["mbh"]
    park(processor, "bus1", mbh.lat, mbh.lng, start=T0, seconds=60)
    state = processor.live.get("bus1")
    assert state.journey_state == "parked"

    est = eta_mod.to_stop(state, route, "library", data, cfg, db, T0 + 61)
    assert est.source == "schedule"
    assert est.seconds > 0


def test_hour_of_week_is_in_range(cfg):
    for offset in range(0, 7 * 24 * 3600, 3607):
        how = eta_mod.hour_of_week(T0 + offset, cfg.timezone)
        assert 0 <= how <= 167
