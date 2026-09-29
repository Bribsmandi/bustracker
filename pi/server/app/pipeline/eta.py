"""Arrival time estimation.

Two independent estimates are blended. The live one (remaining distance over
current along-route speed) reacts immediately but is worthless when the bus is
crawling or stopped. The historical one (learned median time per route segment
for this hour of the week) knows about traffic and dwell but not about today. The
blend leans on history only as far as the sample count justifies.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Protocol
from zoneinfo import ZoneInfo

from ..config import Settings
from ..state import BusState
from ..static_data import Route, StaticData
from . import map_match


class SegmentLookup(Protocol):
    def median(
        self, route_id: str, from_stop: str, to_stop: str, hour_of_week: int
    ) -> tuple[float, int] | None:
        """Learned median seconds and sample count, or None."""


@dataclass(frozen=True)
class Eta:
    seconds: float | None
    source: str  # "live" | "blended" | "schedule" | "none"
    confident: bool
    stop_id: str | None = None


def hour_of_week(ts: float, tz: str) -> int:
    dt = datetime.fromtimestamp(ts, ZoneInfo(tz))
    return dt.weekday() * 24 + dt.hour


def minutes_of_day(ts: float, tz: str) -> int:
    dt = datetime.fromtimestamp(ts, ZoneInfo(tz))
    return dt.hour * 60 + dt.minute


def _live_seconds(remaining_m: float, speed: float, cfg: Settings) -> float:
    return remaining_m / max(speed, cfg.eta_min_speed_mps)


def _historical_seconds(
    route: Route,
    progress_m: float,
    target_stop: str,
    segs: SegmentLookup,
    how: int,
) -> tuple[float | None, int]:
    """Sum learned segment times from the bus's position to the target stop."""
    target_along = route.stop_along.get(target_stop)
    if target_along is None or target_along <= progress_m:
        return None, 0

    ordered = [
        (sid, route.stop_along[sid])
        for sid in route.stops
        if sid in route.stop_along
    ]
    ordered.sort(key=lambda x: x[1])

    total = 0.0
    samples: list[int] = []
    prev_id, prev_along = None, progress_m
    for sid, along in ordered:
        if along <= progress_m:
            prev_id = sid
            continue
        if prev_id is None:
            prev_id = sid
            prev_along = along
            if along >= target_along:
                break
            continue
        row = segs.median(route.id, prev_id, sid, how)
        if row is None:
            return None, 0
        median_s, n = row
        span = route.stop_along[sid] - route.stop_along[prev_id]
        # The first segment is entered part-way through.
        fraction = 1.0 if prev_along <= route.stop_along[prev_id] else max(
            0.0, (along - prev_along) / span if span > 0 else 1.0
        )
        total += median_s * min(1.0, fraction)
        samples.append(n)
        prev_id, prev_along = sid, along
        if along >= target_along:
            break

    if not samples:
        return None, 0
    return total, min(samples)


def to_stop(
    state: BusState,
    route: Route,
    stop_id: str,
    data: StaticData,
    cfg: Settings,
    segs: SegmentLookup,
    now: float,
) -> Eta:
    remaining = [s for s in map_match.remaining_stops(route, state.progress_m) if s[0] == stop_id]
    if not remaining:
        return Eta(None, "none", False, stop_id)
    remaining_m = remaining[0][1]

    if state.journey_state == "parked":
        depart_in = _departure_wait(state, route, data, cfg, now)
        travel = remaining_m / cfg.eta_avg_speed_mps
        hist, n = _historical_seconds(
            route, state.progress_m, stop_id, segs, hour_of_week(now, cfg.timezone)
        )
        if hist is not None:
            travel = hist
        return Eta(depart_in + travel, "schedule", n > 0, stop_id)

    live = _live_seconds(remaining_m, state.speed, cfg)
    hist, n = _historical_seconds(
        route, state.progress_m, stop_id, segs, hour_of_week(now, cfg.timezone)
    )
    if hist is None:
        return Eta(live, "live", state.is_moving, stop_id)

    w = min(cfg.eta_hist_weight_cap, n / cfg.eta_hist_full_samples)
    return Eta(w * hist + (1 - w) * live, "blended", True, stop_id)


def _departure_wait(
    state: BusState, route: Route, data: StaticData, cfg: Settings, now: float
) -> float:
    now_min = minutes_of_day(now, cfg.timezone)
    dep = data.next_departure(state.bus_id, route.id, now_min)
    if dep is None:
        return float(cfg.terminal_dwell_sec)
    return max(0.0, (dep.minutes_of_day - now_min) * 60.0)
