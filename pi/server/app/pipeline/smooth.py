"""Exponential smoothing on the local metric plane.

A GPS parked outside a building wanders 5-15 m. Smoothing in metres rather than
degrees keeps the north/east weighting equal.
"""
from __future__ import annotations

from ..config import Settings
from ..geo import Plane, haversine_m
from ..state import BusState


def smooth_position(
    state: BusState, lat: float, lng: float, plane: Plane, cfg: Settings
) -> tuple[float, float]:
    if state.lat is None:
        return lat, lng
    a = cfg.pos_smoothing
    px, py = plane.to_xy(state.lat, state.lng)
    nx, ny = plane.to_xy(lat, lng)
    return plane.to_latlng(a * px + (1 - a) * nx, a * py + (1 - a) * ny)


def smooth_speed(
    state: BusState, reported: float | None, lat: float, lng: float, dt: float, cfg: Settings
) -> float:
    """Prefer the GPS speed; derive from displacement when it is missing."""
    if reported is not None:
        measured = max(0.0, reported)
    elif state.lat is not None and dt > 0:
        measured = haversine_m(state.lat, state.lng, lat, lng) / dt
    else:
        measured = 0.0
    if state.last_accepted_at is None:
        return measured
    a = cfg.speed_smoothing
    return a * state.speed + (1 - a) * measured
