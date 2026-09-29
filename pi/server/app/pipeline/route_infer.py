"""Which of a bus's directed routes is it currently driving?

The hardware reports raw GPS and nothing else, so the route has to be inferred.
Each candidate accumulates a decayed cost: how far the bus sits off that
polyline, whether it is advancing along it, and whether the timetable expects
that route around now. Shared segments are genuinely ambiguous, and stay so
until the routes diverge — which is why the choice only changes after the
evidence has been sustained for a while, rather than on a single fix.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from zoneinfo import ZoneInfo

from ..config import Settings
from ..geo import Projection, bearing_diff
from ..state import BusState
from ..static_data import Route, StaticData

BACKWARD_PENALTY_M = 60.0
HEADING_WEIGHT = 0.5
SCHEDULE_BONUS_M = 25.0
PARKED_ORIGIN_BONUS_M = 40.0


@dataclass(frozen=True)
class Candidate:
    route: Route
    projection: Projection
    cost: float


def _minutes_of_day(now: float, tz: str) -> int:
    dt = datetime.fromtimestamp(now, ZoneInfo(tz))
    return dt.hour * 60 + dt.minute


def _schedule_favours(data: StaticData, bus_id: str, route: Route, now_min: int, window: int) -> bool:
    entry = data.schedule_for(bus_id, route.id)
    if entry is None:
        return False
    return any(abs(d.minutes_of_day - now_min) <= window for d in entry.departures)


def score(
    state: BusState,
    lat: float,
    lng: float,
    heading: float | None,
    data: StaticData,
    cfg: Settings,
    now: float,
) -> list[Candidate]:
    now_min = _minutes_of_day(now, cfg.timezone)
    out: list[Candidate] = []
    for route in data.usable_routes_for_bus(state.bus_id):
        proj = route.geometry.project(lat, lng)
        cost = proj.offset_m
        if heading is not None and state.is_moving:
            cost += bearing_diff(heading, proj.bearing) * HEADING_WEIGHT
        if route.id == state.route_id and proj.along_m < state.progress_m - cfg.progress_back_tolerance_m:
            cost += BACKWARD_PENALTY_M
        if _schedule_favours(data, state.bus_id, route, now_min, cfg.schedule_prior_window_min):
            cost -= SCHEDULE_BONUS_M
        # A bus waiting at a terminal is ambiguous on geometry alone: it sits at
        # both the end of the route it just finished and the start of the next
        # one. The useful answer for a student is where it is about to go.
        if state.journey_state == "parked" and route.origin == state.destination_id:
            cost -= PARKED_ORIGIN_BONUS_M
        out.append(Candidate(route=route, projection=proj, cost=cost))
    return out


def update(
    state: BusState,
    lat: float,
    lng: float,
    heading: float | None,
    data: StaticData,
    cfg: Settings,
    now: float,
) -> Candidate | None:
    candidates = score(state, lat, lng, heading, data, cfg, now)
    if not candidates:
        return None

    for c in candidates:
        prev = state.route_scores.get(c.route.id, c.cost)
        state.route_scores[c.route.id] = cfg.route_score_decay * prev + c.cost
    for rid in list(state.route_scores):
        if rid not in {c.route.id for c in candidates}:
            del state.route_scores[rid]

    by_id = {c.route.id: c for c in candidates}
    best_id = min(state.route_scores, key=lambda r: state.route_scores[r])

    if state.route_id is None or state.route_id not in state.route_scores:
        return by_id[best_id]
    if best_id == state.route_id:
        return by_id[best_id]

    current = state.route_scores[state.route_id]
    if current - state.route_scores[best_id] > cfg.route_switch_margin:
        return by_id[best_id]
    return by_id[state.route_id]
