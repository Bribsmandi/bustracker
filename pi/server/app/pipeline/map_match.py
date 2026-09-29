"""Snap an accepted fix onto the chosen route and maintain progress along it.

Progress, not the raw coordinate, is the state everything downstream reads:
next stop, remaining distance, direction and ETA all fall out of it.
"""
from __future__ import annotations

from dataclasses import dataclass

from ..config import Settings
from ..geo import Projection
from ..state import BusState
from ..static_data import Route


@dataclass(frozen=True)
class Match:
    route: Route
    progress_m: float
    offset_m: float
    bearing: float
    snapped: bool
    advance_m: float


def apply(
    state: BusState, route: Route, proj: Projection, cfg: Settings, route_changed: bool
) -> Match:
    snapped = proj.offset_m <= cfg.snap_radius_m

    fresh = route_changed or state.route_id != route.id
    if fresh:
        progress = proj.along_m
    else:
        # Monotonic within a route. A projection that lands behind the bus is
        # jitter and is ignored rather than rewinding it; a large backward jump
        # means this is probably the wrong route, which route inference decides.
        progress = min(max(proj.along_m, state.progress_m), route.length_m)

    advance = 0.0 if fresh else max(0.0, progress - state.progress_m)
    return Match(
        route=route,
        progress_m=progress,
        offset_m=proj.offset_m,
        bearing=proj.bearing,
        snapped=snapped,
        advance_m=advance,
    )


def next_stop(route: Route, progress_m: float) -> tuple[str | None, float]:
    """The first stop still ahead, and the metres remaining to it."""
    best: tuple[str, float] | None = None
    for stop_id, along in route.stop_along.items():
        if along <= progress_m:
            continue
        if best is None or along < best[1]:
            best = (stop_id, along)
    if best is None:
        return None, 0.0
    return best[0], best[1] - progress_m


def remaining_stops(route: Route, progress_m: float) -> list[tuple[str, float]]:
    ahead = [
        (sid, along - progress_m)
        for sid, along in route.stop_along.items()
        if along > progress_m
    ]
    return sorted(ahead, key=lambda x: x[1])
