"""Live per-bus state, held in memory and shared by the processor and the API."""
from __future__ import annotations

import time
from dataclasses import dataclass, field

from .config import Settings, settings


@dataclass
class Fix:
    """One accepted position, after validation and smoothing."""

    t: float
    lat: float
    lng: float
    speed: float


@dataclass
class StopVisit:
    stop_id: str
    arrived_at: float
    departed_at: float | None = None
    scheduled_at: int | None = None
    trip_id: int | None = None
    event_id: int | None = None
    halted: bool = False
    logged: bool = False


@dataclass
class BusState:
    bus_id: str

    last_seq: int | None = None
    last_msg_t: float | None = None
    last_accepted_at: float | None = None
    rejects: int = 0

    lat: float | None = None
    lng: float | None = None
    speed: float = 0.0
    heading: float | None = None
    raw_heading: float | None = None
    sats: int | None = None
    hdop: float | None = None

    route_id: str | None = None
    progress_m: float = 0.0
    route_scores: dict[str, float] = field(default_factory=dict)

    # Journey state machine (ported from the Supabase implementation).
    journey_state: str = "outbound"
    origin_id: str | None = None
    destination_id: str | None = None
    park_lat: float | None = None
    park_lng: float | None = None

    trail: list[Fix] = field(default_factory=list)
    inside_stop: str | None = None
    current_visit: StopVisit | None = None

    trip_id: int | None = None
    trip_started_at: float | None = None
    trip_distance_m: float = 0.0
    day: str | None = None
    day_distance_m: float = 0.0
    day_active_s: float = 0.0
    day_trips: int = 0

    will_offline: bool = False
    last_track_sample: float = 0.0

    def age(self, now: float | None = None) -> float | None:
        if self.last_accepted_at is None:
            return None
        return max(0.0, (now if now is not None else time.time()) - self.last_accepted_at)

    def status(self, cfg: Settings | None = None, now: float | None = None) -> str:
        cfg = cfg or settings
        age = self.age(now)
        if age is None:
            return "offline"
        if self.will_offline or age > cfg.stale_max_age:
            return "offline"
        if age <= cfg.live_max_age:
            return "live"
        if age <= cfg.delayed_max_age:
            return "delayed"
        return "stale"

    @property
    def is_moving(self) -> bool:
        return self.speed >= settings.moving_speed_mps

    def trim_trail(self, now: float, keep_sec: float) -> None:
        cutoff = now - keep_sec
        # Keep one fix older than the window: proving the bus has sat still for a
        # full window needs a sample from before the window opened.
        keep_from = 0
        for i, f in enumerate(self.trail):
            if f.t >= cutoff:
                keep_from = max(0, i - 1)
                break
        else:
            keep_from = max(0, len(self.trail) - 1)
        if keep_from:
            del self.trail[:keep_from]


class LiveState:
    def __init__(self, bus_ids: list[str]):
        self.buses: dict[str, BusState] = {b: BusState(bus_id=b) for b in bus_ids}

    def get(self, bus_id: str) -> BusState | None:
        return self.buses.get(bus_id)

    def online_count(self, now: float | None = None) -> int:
        return sum(1 for b in self.buses.values() if b.status(now=now) in ("live", "delayed"))
