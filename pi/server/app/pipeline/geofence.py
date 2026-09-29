"""Stop arrival and departure detection.

Enter and exit use different radii on purpose: with a single radius a bus idling
on the boundary emits an endless arrival/departure pair on every jitter step.
"""
from __future__ import annotations

from dataclasses import dataclass

from ..config import Settings
from ..geo import haversine_m
from ..state import BusState, StopVisit
from ..static_data import StaticData


@dataclass(frozen=True)
class StopEvent:
    kind: str  # "arrival" | "departure"
    visit: StopVisit


def update(
    state: BusState, lat: float, lng: float, data: StaticData, cfg: Settings, now: float
) -> list[StopEvent]:
    events: list[StopEvent] = []

    if state.inside_stop is None:
        nearest = data.nearest_stop(lat, lng)
        if nearest is None:
            return events
        stop, dist = nearest
        if dist <= cfg.stop_enter_m:
            state.inside_stop = stop.id
            state.current_visit = StopVisit(stop_id=stop.id, arrived_at=now)
        return events

    stop = data.stops.get(state.inside_stop)
    visit = state.current_visit
    if stop is None or visit is None:
        state.inside_stop = None
        state.current_visit = None
        return events

    dist = haversine_m(lat, lng, stop.lat, stop.lng)
    if not state.is_moving:
        visit.halted = True

    # A bus driving straight through is inside a 40 m radius for several seconds
    # at road speed, so dwell time alone would invent an arrival at every stop it
    # passes. It counts as an arrival only if it actually came to a halt.
    if not visit.logged and visit.halted and now - visit.arrived_at >= cfg.stop_min_dwell_sec:
        visit.logged = True
        events.append(StopEvent("arrival", visit))

    if dist > cfg.stop_exit_m:
        if visit.logged:
            visit.departed_at = now
            events.append(StopEvent("departure", visit))
        state.inside_stop = None
        state.current_visit = None

    return events
