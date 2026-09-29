"""Message parsing and rejection rules.

Freshness beats completeness (requirement F2): anything doubtful is dropped with
a reason, never buffered for later.
"""
from __future__ import annotations

from dataclasses import dataclass

from ..config import Settings
from ..geo import haversine_m
from ..state import BusState


class Rejected(Exception):
    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


@dataclass(frozen=True)
class RawFix:
    seq: int | None
    t: float
    lat: float
    lng: float
    speed: float | None
    heading: float | None
    sats: int | None
    hdop: float | None


def parse(payload: dict) -> RawFix:
    try:
        lat = float(payload["lat"])
        lng = float(payload["lng"])
    except (KeyError, TypeError, ValueError):
        raise Rejected("bad coordinates")

    def opt_f(key: str) -> float | None:
        v = payload.get(key)
        if v is None:
            return None
        try:
            return float(v)
        except (TypeError, ValueError):
            raise Rejected(f"bad {key}")

    def opt_i(key: str) -> int | None:
        v = opt_f(key)
        return None if v is None else int(v)

    t = opt_f("t")
    return RawFix(
        seq=opt_i("seq"),
        t=t if t is not None else 0.0,
        lat=lat,
        lng=lng,
        speed=opt_f("spd"),
        heading=opt_f("hdg"),
        sats=opt_i("sats"),
        hdop=opt_f("hdop"),
    )


def check(fix: RawFix, state: BusState, cfg: Settings, now: float) -> None:
    """Raise Rejected if this fix must not be accepted."""
    if not (-90 <= fix.lat <= 90 and -180 <= fix.lng <= 180):
        raise Rejected("coordinates out of range")

    if fix.seq is not None and state.last_seq is not None and fix.seq <= state.last_seq:
        raise Rejected("stale seq")
    if fix.seq is None and fix.t and state.last_msg_t is not None and fix.t < state.last_msg_t:
        raise Rejected("stale timestamp")

    if fix.sats is not None and fix.sats < cfg.min_sats:
        raise Rejected("too few satellites")
    if fix.hdop is not None and fix.hdop > cfg.max_hdop:
        raise Rejected("hdop too high")

    if not cfg.in_bbox(fix.lat, fix.lng):
        raise Rejected("outside campus")

    if state.lat is not None and state.last_accepted_at is not None:
        dt = max(0.001, now - state.last_accepted_at)
        implied = haversine_m(state.lat, state.lng, fix.lat, fix.lng) / dt
        if implied > cfg.max_jump_mps:
            raise Rejected("implausible jump")
