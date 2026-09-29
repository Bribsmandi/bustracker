"""Parked / outbound state machine, carried over from the Supabase version.

The rules and their justification are unchanged from the SQL implementation this
replaces:

    parked   := within 40 m of a terminal AND moved < 15 m over the last 30 s
    departed := > 25 m from the park anchor AND speed > 2 m/s for 3 fixes

Two independent signals per transition is the whole point. A stationary GPS
drifts 5-15 m, so distance alone invents departures; fused speed is unreliable
below walking pace, so speed alone invents parks.

Trip boundaries are exactly these transitions, so the trip log is a side effect:
departure opens a trip, arrival closes it.
"""
from __future__ import annotations

from dataclasses import dataclass

from ..config import Settings
from ..geo import haversine_m
from ..state import BusState
from ..static_data import StaticData


@dataclass(frozen=True)
class JourneyResult:
    state: str
    origin_id: str | None
    destination_id: str | None
    departed: bool = False
    arrived: bool = False
    terminal_id: str | None = None
    nearest_m: float | None = None


def advance(
    state: BusState, data: StaticData, cfg: Settings, now: float
) -> JourneyResult:
    if state.lat is None:
        return JourneyResult(state.journey_state, state.origin_id, state.destination_id)

    nearest = data.nearest_stop(state.lat, state.lng, terminals_only=True)
    if nearest is None:
        return JourneyResult(state.journey_state, state.origin_id, state.destination_id)
    terminal, nearest_m = nearest

    if state.journey_state == "parked":
        from_park = (
            0.0
            if state.park_lat is None
            else haversine_m(state.lat, state.lng, state.park_lat, state.park_lng)
        )
        recent = state.trail[-cfg.depart_min_fixes :]
        moving = sum(1 for f in recent if f.speed >= cfg.depart_min_speed_mps)

        if from_park > cfg.depart_min_distance_m and moving >= cfg.depart_min_fixes:
            origin = state.destination_id or terminal.id
            dest = state.origin_id
            state.journey_state = "outbound"
            state.origin_id = origin
            state.destination_id = dest
            state.park_lat = None
            state.park_lng = None
            return JourneyResult(
                "outbound", origin, dest, departed=True, terminal_id=origin, nearest_m=nearest_m
            )
        return JourneyResult(
            "parked", state.origin_id, state.destination_id, nearest_m=nearest_m
        )

    if nearest_m <= cfg.arrive_radius_m:
        window_start = now - cfg.parked_window_sec
        in_window = [f for f in state.trail if f.t >= window_start]
        # Coverage deliberately looks OUTSIDE the window: the oldest fix inside a
        # 30 s window is by definition younger than 30 s, so a within-window span
        # can never reach the threshold. A fix from before the window opened is
        # what proves the bus has really been sitting here.
        has_prior = any(f.t < window_start for f in state.trail)
        drift = max(
            (haversine_m(state.lat, state.lng, f.lat, f.lng) for f in in_window),
            default=float("inf"),
        )

        if has_prior and len(in_window) >= 2 and drift <= cfg.parked_max_drift_m:
            state.journey_state = "parked"
            state.destination_id = terminal.id
            state.park_lat = state.lat
            state.park_lng = state.lng
            return JourneyResult(
                "parked",
                state.origin_id,
                terminal.id,
                arrived=True,
                terminal_id=terminal.id,
                nearest_m=nearest_m,
            )

    return JourneyResult(
        state.journey_state, state.origin_id, state.destination_id, nearest_m=nearest_m
    )
