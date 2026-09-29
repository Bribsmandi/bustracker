"""Stop arrivals and trip planning.

This logic used to run on the phone, which meant every student's device
re-derived it from raw positions and the timetable. It lives here now so the app
only has to render an answer, and so the learned segment times — which exist
only on the Pi — can inform it.
"""
from __future__ import annotations

import time
from dataclasses import asdict, dataclass

from .config import Settings, settings
from .pipeline import eta as eta_mod
from .processor import Processor
from .static_data import Route


@dataclass
class ArrivalEstimate:
    bus_id: str
    route_id: str
    eta_s: int
    source: str
    confident: bool
    status: str


@dataclass
class TripOption:
    bus_id: str
    route_id: str
    board_stop: str
    dest_stop: str
    wait_s: int
    ride_s: int
    total_s: int
    source: str
    confident: bool


class Planner:
    def __init__(self, processor: Processor, cfg: Settings | None = None):
        self.p = processor
        self.data = processor.data
        self.cfg = cfg or settings

    # ---------------------------------------------------------------- helpers

    def _live_eta(self, bus_id: str, route: Route, stop_id: str, now: float):
        state = self.p.live.get(bus_id)
        if state is None or state.route_id != route.id:
            return None
        if state.status(self.cfg, now) in ("stale", "offline"):
            return None
        est = eta_mod.to_stop(state, route, stop_id, self.data, self.cfg, self.p.db, now)
        if est.seconds is None:
            return None
        return est, state

    def _scheduled_eta(self, bus_id: str, route: Route, stop_id: str, now: float) -> float | None:
        """Timetable fallback: next printed departure plus the run to the stop."""
        if stop_id not in route.stop_along:
            return None
        now_min = eta_mod.minutes_of_day(now, self.cfg.timezone)
        dep = self.data.next_departure(bus_id, route.id, now_min)
        if dep is None:
            return None
        origin_along = route.stop_along.get(route.origin, 0.0)
        run_m = max(0.0, route.stop_along[stop_id] - origin_along)
        return (dep.minutes_of_day - now_min) * 60.0 + run_m / self.cfg.eta_avg_speed_mps

    # --------------------------------------------------------------- arrivals

    def arrivals(self, stop_id: str, now: float | None = None) -> dict:
        now = time.time() if now is None else now
        if stop_id not in self.data.stops:
            return {"stop_id": stop_id, "error": "unknown stop", "arrivals": []}

        out: list[ArrivalEstimate] = []
        for route in self.data.routes.values():
            if stop_id not in route.stop_along:
                continue
            for bus_id in route.buses:
                live = self._live_eta(bus_id, route, stop_id, now)
                if live is not None:
                    est, state = live
                    out.append(
                        ArrivalEstimate(
                            bus_id=bus_id,
                            route_id=route.id,
                            eta_s=int(est.seconds),
                            source=est.source,
                            confident=est.confident,
                            status=state.status(self.cfg, now),
                        )
                    )
                    continue
                sched = self._scheduled_eta(bus_id, route, stop_id, now)
                if sched is not None:
                    state = self.p.live.get(bus_id)
                    out.append(
                        ArrivalEstimate(
                            bus_id=bus_id,
                            route_id=route.id,
                            eta_s=int(sched),
                            source="timetable",
                            confident=False,
                            status=state.status(self.cfg, now) if state else "offline",
                        )
                    )

        out.sort(key=lambda a: a.eta_s)
        return {
            "stop_id": stop_id,
            "name": self.data.stops[stop_id].name,
            "ts": int(now),
            "arrivals": [asdict(a) for a in out[:12]],
        }

    # ------------------------------------------------------------------- trip

    def plan(self, from_stop: str, to_stop: str, now: float | None = None) -> dict:
        now = time.time() if now is None else now
        if from_stop not in self.data.stops or to_stop not in self.data.stops:
            return {"error": "unknown stop", "options": []}
        if from_stop == to_stop:
            return {"error": "boarding and destination are the same stop", "options": []}

        options: list[TripOption] = []
        for route in self.data.routes.values():
            if from_stop not in route.stop_along or to_stop not in route.stop_along:
                continue
            # Direction matters: the boarding stop must come first on this route.
            if route.stop_along[from_stop] >= route.stop_along[to_stop]:
                continue
            ride_m = route.stop_along[to_stop] - route.stop_along[from_stop]

            for bus_id in route.buses:
                ride_s = self._ride_seconds(route, from_stop, to_stop, ride_m, now)
                live = self._live_eta(bus_id, route, from_stop, now)
                if live is not None:
                    est, _ = live
                    wait = est.seconds
                    source, confident = est.source, est.confident
                else:
                    sched = self._scheduled_eta(bus_id, route, from_stop, now)
                    if sched is None:
                        continue
                    wait, source, confident = sched, "timetable", False

                options.append(
                    TripOption(
                        bus_id=bus_id,
                        route_id=route.id,
                        board_stop=from_stop,
                        dest_stop=to_stop,
                        wait_s=int(wait),
                        ride_s=int(ride_s),
                        total_s=int(wait + ride_s),
                        source=source,
                        confident=confident,
                    )
                )

        options.sort(key=lambda o: o.total_s)
        return {
            "from": from_stop,
            "to": to_stop,
            "ts": int(now),
            "options": [asdict(o) for o in options[:6]],
        }

    def _ride_seconds(
        self, route: Route, from_stop: str, to_stop: str, ride_m: float, now: float
    ) -> float:
        """Learned segment times when the whole leg is covered, else average speed."""
        how = eta_mod.hour_of_week(now, self.cfg.timezone)
        ordered = sorted(
            ((sid, route.stop_along[sid]) for sid in route.stops if sid in route.stop_along),
            key=lambda x: x[1],
        )
        start = route.stop_along[from_stop]
        end = route.stop_along[to_stop]
        total = 0.0
        prev: str | None = None
        for sid, along in ordered:
            if along < start:
                continue
            if prev is not None:
                row = self.p.db.median(route.id, prev, sid, how)
                if row is None:
                    return ride_m / self.cfg.eta_avg_speed_mps
                total += row[0]
            prev = sid
            if along >= end:
                break
        return total if total > 0 else ride_m / self.cfg.eta_avg_speed_mps

    # -------------------------------------------------------------- departures

    def upcoming_departures(self, limit: int = 20, now: float | None = None) -> list[dict]:
        now = time.time() if now is None else now
        now_min = eta_mod.minutes_of_day(now, self.cfg.timezone)
        rows = []
        for entry in self.data.schedules:
            for d in entry.departures:
                if d.minutes_of_day < now_min:
                    continue
                rows.append(
                    {
                        "bus_id": entry.bus_id,
                        "route_id": entry.route_id,
                        "origin": entry.origin,
                        "time": d.time,
                        "in_s": (d.minutes_of_day - now_min) * 60,
                        "soms_variant": d.soms_variant,
                    }
                )
        rows.sort(key=lambda r: r["in_s"])
        return rows[:limit]
