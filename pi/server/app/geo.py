"""Geometry on a local metric plane.

Campus extent is under 1 km, so an equirectangular projection around a fixed
origin is accurate to a few centimetres — far below GPS noise — and lets every
downstream stage work in plain metres.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

EARTH_R = 6371000.0


def haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = (
        math.sin(dlat / 2) ** 2
        + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlng / 2) ** 2
    )
    return 2 * EARTH_R * math.asin(math.sqrt(min(1.0, a)))


def bearing_deg(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lng2 - lng1)
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360.0) % 360.0


def bearing_diff(a: float, b: float) -> float:
    d = abs((a - b) % 360.0)
    return min(d, 360.0 - d)


class Plane:
    """Equirectangular projection anchored at a campus origin."""

    def __init__(self, origin_lat: float, origin_lng: float):
        self.lat0 = origin_lat
        self.lng0 = origin_lng
        self._kx = EARTH_R * math.cos(math.radians(origin_lat))
        self._ky = EARTH_R

    def to_xy(self, lat: float, lng: float) -> tuple[float, float]:
        return (
            math.radians(lng - self.lng0) * self._kx,
            math.radians(lat - self.lat0) * self._ky,
        )

    def to_latlng(self, x: float, y: float) -> tuple[float, float]:
        return (
            self.lat0 + math.degrees(y / self._ky),
            self.lng0 + math.degrees(x / self._kx),
        )


@dataclass(frozen=True)
class Projection:
    """Where a point falls on a polyline."""

    along_m: float
    offset_m: float
    seg_index: int
    bearing: float


class RouteGeometry:
    """A route polyline in plane coordinates, indexed by distance along it."""

    def __init__(self, plane: Plane, latlngs: list[tuple[float, float]]):
        self.plane = plane
        self.latlngs = latlngs
        self.xy = [plane.to_xy(lat, lng) for lat, lng in latlngs]
        self.cum: list[float] = [0.0]
        for i in range(1, len(self.xy)):
            (x0, y0), (x1, y1) = self.xy[i - 1], self.xy[i]
            self.cum.append(self.cum[-1] + math.hypot(x1 - x0, y1 - y0))
        self.length_m = self.cum[-1] if self.cum else 0.0
        self.bearings: list[float] = []
        for i in range(1, len(latlngs)):
            self.bearings.append(bearing_deg(*latlngs[i - 1], *latlngs[i]))

    @property
    def usable(self) -> bool:
        return len(self.xy) >= 2 and self.length_m > 0

    def project(self, lat: float, lng: float) -> Projection:
        px, py = self.plane.to_xy(lat, lng)
        best = (math.inf, 0.0, 0)
        for i in range(len(self.xy) - 1):
            ax, ay = self.xy[i]
            bx, by = self.xy[i + 1]
            dx, dy = bx - ax, by - ay
            seg2 = dx * dx + dy * dy
            t = 0.0 if seg2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / seg2))
            cx, cy = ax + t * dx, ay + t * dy
            d2 = (px - cx) ** 2 + (py - cy) ** 2
            if d2 < best[0]:
                best = (d2, self.cum[i] + t * math.sqrt(seg2), i)
        d2, along, idx = best
        return Projection(
            along_m=along,
            offset_m=math.sqrt(d2),
            seg_index=idx,
            bearing=self.bearings[idx] if idx < len(self.bearings) else 0.0,
        )

    def position_at(self, along_m: float) -> tuple[float, float, float]:
        """Interpolated (lat, lng, bearing) at a distance along the route."""
        if not self.usable:
            lat, lng = self.latlngs[0] if self.latlngs else (0.0, 0.0)
            return lat, lng, 0.0
        if along_m <= 0:
            return (*self.latlngs[0], self.bearings[0])
        if along_m >= self.length_m:
            return (*self.latlngs[-1], self.bearings[-1])
        for i in range(1, len(self.cum)):
            if self.cum[i] < along_m:
                continue
            span = self.cum[i] - self.cum[i - 1]
            t = 0.0 if span == 0 else (along_m - self.cum[i - 1]) / span
            (ax, ay), (bx, by) = self.xy[i - 1], self.xy[i]
            lat, lng = self.plane.to_latlng(ax + (bx - ax) * t, ay + (by - ay) * t)
            return lat, lng, self.bearings[i - 1]
        return (*self.latlngs[-1], self.bearings[-1])

    def along_of_point(self, lat: float, lng: float) -> float:
        return self.project(lat, lng).along_m
