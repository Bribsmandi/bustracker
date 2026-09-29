"""The processing pipeline: one accepted GPS fix in, live state and history out.

Runs in the same process as the API so live state is shared in memory. Six buses
reporting every 5 s is a little over one message a second, so nothing here needs
to be clever about throughput — fan-out to students is the expensive part, and
the broker handles that.
"""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass
from datetime import datetime
from zoneinfo import ZoneInfo

from .config import Settings, settings
from .db import Database
from .geo import haversine_m
from .pipeline import eta as eta_mod
from .pipeline import geofence, journey, map_match, route_infer, smooth, validate
from .state import BusState, Fix, LiveState
from .static_data import StaticData

log = logging.getLogger("bus.processor")

TRAIL_KEEP_SEC = 300.0


@dataclass
class Arrival:
    stop_id: str
    ts: float
    route_id: str | None
    trip_id: int | None


class Processor:
    def __init__(
        self,
        data: StaticData,
        db: Database,
        live: LiveState | None = None,
        cfg: Settings | None = None,
    ):
        self.data = data
        self.db = db
        self.cfg = cfg or settings
        self.live = live or LiveState(list(data.buses))
        self.last_arrival: dict[str, Arrival] = {}
        self.rejects: dict[str, str] = {}
        # Set whenever live state changes, so the publisher can send on change
        # rather than on a timer.
        self.dirty = False

    # ----------------------------------------------------------------- ingest

    def handle_message(self, bus_id: str, payload: dict, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        state = self.live.get(bus_id)
        if state is None:
            log.warning("message for unknown bus %r", bus_id)
            return False

        try:
            fix = validate.parse(payload)
            validate.check(fix, state, self.cfg, now)
        except validate.Rejected as e:
            state.rejects += 1
            self.rejects[bus_id] = e.reason
            log.info("rejected fix from %s: %s", bus_id, e.reason)
            return False

        self._accept(state, fix, now)
        self.dirty = True
        return True

    def handle_status(self, bus_id: str, payload: str, now: float | None = None) -> None:
        state = self.live.get(bus_id)
        if state is None:
            return
        offline = payload.strip().lower() == "offline"
        if offline != state.will_offline:
            self.dirty = True
        state.will_offline = offline
        log.info("bus %s reported %s", bus_id, "offline" if offline else "online")

    def _accept(self, state: BusState, fix: validate.RawFix, now: float) -> None:
        dt = now - state.last_accepted_at if state.last_accepted_at is not None else 0.0
        prev_lat, prev_lng = state.lat, state.lng

        lat, lng = smooth.smooth_position(state, fix.lat, fix.lng, self.data.plane, self.cfg)
        speed = smooth.smooth_speed(state, fix.speed, lat, lng, dt, self.cfg)

        state.raw_heading = fix.heading
        state.sats = fix.sats
        state.hdop = fix.hdop
        if fix.seq is not None:
            state.last_seq = fix.seq
        if fix.t:
            state.last_msg_t = fix.t

        prev_route = state.route_id
        candidate = route_infer.update(state, lat, lng, fix.heading, self.data, self.cfg, now)

        state.lat = lat
        state.lng = lng
        state.speed = speed
        state.last_accepted_at = now

        if candidate is not None:
            match = map_match.apply(
                state, candidate.route, candidate.projection, self.cfg, prev_route != candidate.route.id
            )
            state.route_id = match.route.id
            state.progress_m = match.progress_m
            state.heading = match.bearing if match.snapped else fix.heading
            advance = match.advance_m
        else:
            state.heading = fix.heading
            advance = 0.0

        state.trail.append(Fix(t=now, lat=lat, lng=lng, speed=speed))
        state.trim_trail(now, TRAIL_KEEP_SEC)

        self._roll_day(state, now)
        self._accumulate(state, prev_lat, prev_lng, advance, dt)
        self._advance_journey(state, now)
        self._stop_events(state, lat, lng, now)
        self._sample_track(state, now)

    # ------------------------------------------------------------- accounting

    def _roll_day(self, state: BusState, now: float) -> None:
        day = datetime.fromtimestamp(now, ZoneInfo(self.cfg.timezone)).strftime("%Y-%m-%d")
        if state.day == day:
            return
        state.day = day
        state.day_distance_m = 0.0
        state.day_active_s = 0.0
        state.day_trips = 0

    def _accumulate(
        self, state: BusState, prev_lat: float | None, prev_lng: float | None, advance: float, dt: float
    ) -> None:
        if not state.is_moving or dt <= 0 or dt > 30:
            return
        # Prefer along-route advance; a bus off any polyline still covers ground.
        step = advance
        if step <= 0 and prev_lat is not None:
            step = haversine_m(prev_lat, prev_lng, state.lat, state.lng)
        state.day_distance_m += step
        state.trip_distance_m += step
        state.day_active_s += dt
        self.db.upsert_daily(
            state.day, state.bus_id, state.day_distance_m, state.day_active_s, state.day_trips
        )

    def _advance_journey(self, state: BusState, now: float) -> None:
        result = journey.advance(state, self.data, self.cfg, now)

        if result.departed:
            self.db.abandon_open_trips(state.bus_id, result.origin_id)
            state.trip_id = self.db.open_trip(state.bus_id, state.route_id, result.origin_id, now)
            state.trip_started_at = now
            state.trip_distance_m = 0.0
            state.day_trips += 1
            log.info("bus %s departed %s (trip %s)", state.bus_id, result.origin_id, state.trip_id)

        elif result.arrived and state.trip_id is not None:
            self.db.close_trip(state.trip_id, result.terminal_id, now, state.trip_distance_m)
            log.info(
                "bus %s arrived %s after %.0f m", state.bus_id, result.terminal_id, state.trip_distance_m
            )
            state.trip_id = None
            state.trip_started_at = None

    def _stop_events(self, state: BusState, lat: float, lng: float, now: float) -> None:
        for event in geofence.update(state, lat, lng, self.data, self.cfg, now):
            visit = event.visit
            if event.kind == "arrival":
                visit.trip_id = state.trip_id
                visit.scheduled_at = self._scheduled_at(state, visit.stop_id, now)
                visit.event_id = self.db.log_arrival(
                    state.bus_id,
                    visit.stop_id,
                    state.route_id,
                    state.trip_id,
                    visit.arrived_at,
                    visit.scheduled_at,
                )
                self._learn_segment(state, visit.stop_id, visit.arrived_at)
            elif visit.event_id is not None:
                self.db.log_departure(visit.event_id, visit.departed_at or now)

    def _scheduled_at(self, state: BusState, stop_id: str, now: float) -> int | None:
        """Only terminals have printed times, so punctuality is measured there."""
        stop = self.data.stops.get(stop_id)
        if stop is None or not stop.is_terminal or state.route_id is None:
            return None
        entry = self.data.schedule_for(state.bus_id, state.route_id)
        if entry is None or entry.origin != stop_id:
            return None
        local = datetime.fromtimestamp(now, ZoneInfo(self.cfg.timezone))
        midnight = local.replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
        now_min = (now - midnight) / 60
        nearest = min(entry.departures, key=lambda d: abs(d.minutes_of_day - now_min))
        return int(midnight + nearest.minutes_of_day * 60)

    def _learn_segment(self, state: BusState, stop_id: str, ts: float) -> None:
        prev = self.last_arrival.get(state.bus_id)
        self.last_arrival[state.bus_id] = Arrival(stop_id, ts, state.route_id, state.trip_id)
        if (
            prev is None
            or state.route_id is None
            or prev.route_id != state.route_id
            or prev.trip_id != state.trip_id
            or prev.stop_id == stop_id
        ):
            return
        duration = ts - prev.ts
        if duration <= 0 or duration > 3600:
            return
        self.db.record_segment(
            state.route_id,
            prev.stop_id,
            stop_id,
            eta_mod.hour_of_week(prev.ts, self.cfg.timezone),
            duration,
        )

    def _sample_track(self, state: BusState, now: float) -> None:
        if not state.is_moving or now - state.last_track_sample < self.cfg.track_sample_sec:
            return
        state.last_track_sample = now
        self.db.log_position(
            state.bus_id, now, state.lat, state.lng, state.speed, state.route_id, state.progress_m
        )

    # ---------------------------------------------------------------- reading

    def bus_payload(self, state: BusState, now: float) -> dict:
        route = self.data.routes.get(state.route_id) if state.route_id else None
        next_stop, remaining_m = (None, 0.0)
        eta_s: float | None = None
        confident = False
        if route is not None:
            next_stop, remaining_m = map_match.next_stop(route, state.progress_m)
            if next_stop is not None:
                est = eta_mod.to_stop(
                    state, route, next_stop, self.data, self.cfg, self.db, now
                )
                eta_s = est.seconds
                confident = est.confident

        return {
            "id": state.bus_id,
            "lat": round(state.lat, 6) if state.lat is not None else None,
            "lng": round(state.lng, 6) if state.lng is not None else None,
            "heading": round(state.heading, 1) if state.heading is not None else None,
            "speed": round(state.speed, 2),
            "route": state.route_id,
            "progress": round(state.progress_m / route.length_m, 4)
            if route is not None and route.length_m > 0
            else None,
            "progress_m": round(state.progress_m, 1),
            "status": state.status(self.cfg, now),
            "age": round(state.age(now), 1) if state.age(now) is not None else None,
            "journey_state": state.journey_state,
            "origin": state.origin_id,
            "destination": state.destination_id,
            "next_stop": next_stop,
            "next_stop_m": round(remaining_m, 1) if next_stop else None,
            "eta_s": round(eta_s) if eta_s is not None else None,
            "eta_confident": confident,
            "at_stop": state.inside_stop,
        }

    def snapshot(self, now: float | None = None) -> dict:
        now = time.time() if now is None else now
        return {
            "type": "snapshot",
            "ts": int(now),
            "config_version": self.data.version,
            "buses": [self.bus_payload(s, now) for s in self.live.buses.values()],
        }
