"""Static reference data: stops, buses, routes, schedule.

The JSON files in data/ stay canonical. They are loaded once at startup, and
served verbatim to the app from /config so a timetable fix needs no app release.
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path

from .config import Settings, settings
from .geo import Plane, RouteGeometry, haversine_m


@dataclass(frozen=True)
class Stop:
    id: str
    name: str
    full_name: str
    is_terminal: bool
    lat: float
    lng: float


@dataclass(frozen=True)
class Bus:
    id: str
    label: str
    type: str
    home_terminal: str
    color: str


@dataclass
class Route:
    id: str
    name: str
    buses: list[str]
    origin: str
    destination: str
    stops: list[str]
    geometry: RouteGeometry
    # Distance along the polyline of each stop the route serves.
    stop_along: dict[str, float] = field(default_factory=dict)

    @property
    def length_m(self) -> float:
        return self.geometry.length_m


@dataclass(frozen=True)
class Departure:
    time: str
    soms_variant: bool

    @property
    def minutes_of_day(self) -> int:
        h, m = self.time.split(":")
        return int(h) * 60 + int(m)


@dataclass(frozen=True)
class ScheduleEntry:
    bus_id: str
    route_id: str
    origin: str
    departures: tuple[Departure, ...]


class StaticData:
    def __init__(self, cfg: Settings | None = None, data_dir: Path | None = None):
        self.cfg = cfg or settings
        self.data_dir = data_dir or self.cfg.data_dir
        self.plane = Plane(*self.cfg.center)

        self._raw: dict[str, dict] = {}
        self.stops: dict[str, Stop] = {}
        self.buses: dict[str, Bus] = {}
        self.routes: dict[str, Route] = {}
        self.schedules: list[ScheduleEntry] = []
        self.version = ""
        self.load()

    def _read(self, name: str) -> dict:
        with open(self.data_dir / name) as f:
            doc = json.load(f)
        self._raw[name] = doc
        return doc

    def load(self) -> None:
        stops = self._read("stops.json")["stops"]
        self.stops = {
            s["id"]: Stop(
                id=s["id"],
                name=s["name"],
                full_name=s.get("fullName", s["name"]),
                is_terminal=bool(s.get("isTerminal", False)),
                lat=float(s["lat"]),
                lng=float(s["lng"]),
            )
            for s in stops
            if s.get("lat") is not None and s.get("lng") is not None
        }

        self.buses = {
            b["id"]: Bus(
                id=b["id"],
                label=b["label"],
                type=b.get("type", "regular"),
                home_terminal=b.get("homeTerminal", ""),
                color=b.get("color", "#3366cc"),
            )
            for b in self._read("buses.json")["buses"]
        }

        self.routes = {}
        for r in self._read("routes.json")["routes"]:
            path = [(float(p[0]), float(p[1])) for p in r.get("path", [])]
            if not path:
                # No surveyed polyline: fall back to straight lines between stops.
                path = [
                    (self.stops[s].lat, self.stops[s].lng)
                    for s in r["stops"]
                    if s in self.stops
                ]
            route = Route(
                id=r["id"],
                name=r["name"],
                buses=list(r["buses"]),
                origin=r["origin"],
                destination=r["destination"],
                stops=list(r["stops"]),
                geometry=RouteGeometry(self.plane, path),
            )
            for stop_id in route.stops:
                stop = self.stops.get(stop_id)
                if stop is None:
                    continue
                route.stop_along[stop_id] = route.geometry.along_of_point(stop.lat, stop.lng)
            self.routes[route.id] = route

        self.schedules = []
        for e in self._read("schedule.json")["schedules"]:
            deps = []
            for d in e["departures"]:
                if isinstance(d, str):
                    deps.append(Departure(d, False))
                else:
                    deps.append(Departure(d["time"], bool(d.get("somsVariant", False))))
            self.schedules.append(
                ScheduleEntry(
                    bus_id=e["busId"],
                    route_id=e["routeId"],
                    origin=e["origin"],
                    departures=tuple(sorted(deps, key=lambda x: x.minutes_of_day)),
                )
            )

        blob = json.dumps(
            {k: self._raw[k] for k in sorted(self._raw)}, sort_keys=True, separators=(",", ":")
        )
        self.version = hashlib.sha256(blob.encode()).hexdigest()[:12]

    # ---------------------------------------------------------------- queries

    def routes_for_bus(self, bus_id: str) -> list[Route]:
        return [r for r in self.routes.values() if bus_id in r.buses]

    def usable_routes_for_bus(self, bus_id: str) -> list[Route]:
        return [r for r in self.routes_for_bus(bus_id) if r.geometry.usable]

    def terminals(self) -> list[Stop]:
        return [s for s in self.stops.values() if s.is_terminal]

    def nearest_stop(self, lat: float, lng: float, terminals_only: bool = False):
        pool = self.terminals() if terminals_only else list(self.stops.values())
        best: tuple[Stop, float] | None = None
        for s in pool:
            d = haversine_m(lat, lng, s.lat, s.lng)
            if best is None or d < best[1]:
                best = (s, d)
        return best

    def schedule_for(self, bus_id: str, route_id: str) -> ScheduleEntry | None:
        for e in self.schedules:
            if e.bus_id == bus_id and e.route_id == route_id:
                return e
        return None

    def next_departure(self, bus_id: str, route_id: str, after_minutes: int) -> Departure | None:
        entry = self.schedule_for(bus_id, route_id)
        if entry is None:
            return None
        for d in entry.departures:
            if d.minutes_of_day >= after_minutes:
                return d
        return None

    def config_payload(self) -> dict:
        return {
            "version": self.version,
            "stops": self._raw["stops.json"]["stops"],
            "buses": self._raw["buses.json"]["buses"],
            "routes": self._raw["routes.json"]["routes"],
            "schedules": self._raw["schedule.json"]["schedules"],
        }
