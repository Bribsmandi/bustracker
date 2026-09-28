#!/usr/bin/env python3
"""Bake a campus vector basemap into data/basemap.json.

Fetches roads, buildings, green areas and water for the campus bounding box
from OpenStreetMap (Overpass), simplifies the geometry, and writes a compact
JSON asset. The tracker renders this itself instead of loading raster tiles:
crisp at every zoom, works offline, and shows only what a bus rider needs.

Run whenever the campus changes materially. Data (c) OpenStreetMap
contributors, ODbL — the app must show attribution.
"""
import json
import math
import sys
import urllib.request

# Slightly larger than the map's pan bounds so edges never show blank.
S, W, N, E = 11.3110, 75.9270, 11.3270, 75.9420

DRIVABLE = {
    'service', 'residential', 'unclassified', 'tertiary', 'tertiary_link',
    'secondary', 'secondary_link', 'primary', 'primary_link', 'living_street',
    'road', 'trunk', 'trunk_link',
}
MAJOR = {'secondary', 'secondary_link', 'primary', 'primary_link',
         'trunk', 'trunk_link', 'tertiary', 'tertiary_link'}
GREEN_LANDUSE = {'forest', 'grass', 'meadow', 'recreation_ground', 'orchard',
                 'village_green'}
GREEN_LEISURE = {'park', 'pitch', 'garden', 'playground', 'sports_centre'}


def fetch():
    q = (f'[out:json][timeout:90];('
         f'way["highway"]({S},{W},{N},{E});'
         f'way["building"]({S},{W},{N},{E});'
         f'way["landuse"]({S},{W},{N},{E});'
         f'way["leisure"]({S},{W},{N},{E});'
         f'way["natural"]({S},{W},{N},{E});'
         f');out geom;')
    req = urllib.request.Request(
        'https://overpass-api.de/api/interpreter',
        data=('data=' + urllib.parse.quote(q)).encode(),
        headers={'User-Agent': 'bustracker-basemap-bake'})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def haversine(a, b):
    r = 6371000.0
    la1, lo1 = math.radians(a[0]), math.radians(a[1])
    la2, lo2 = math.radians(b[0]), math.radians(b[1])
    h = (math.sin((la2 - la1) / 2) ** 2
         + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(h))


def simplify(pts, tol=1.5):
    """Ramer-Douglas-Peucker in metres."""
    if len(pts) < 3:
        return pts

    def perp(p, a, b):
        if a == b:
            return haversine(p, a)
        lat0 = math.radians(p[0])

        def xy(q):
            return (math.radians(q[1] - p[1]) * math.cos(lat0) * 6371000,
                    math.radians(q[0] - p[0]) * 6371000)
        (x1, y1), (x2, y2) = xy(a), xy(b)
        dx, dy = x2 - x1, y2 - y1
        L2 = dx * dx + dy * dy
        t = 0 if L2 == 0 else max(0, min(1, (-x1 * dx - y1 * dy) / L2))
        return math.hypot(x1 + t * dx, y1 + t * dy)

    dmax, idx = 0.0, 0
    for i in range(1, len(pts) - 1):
        d = perp(pts[i], pts[0], pts[-1])
        if d > dmax:
            dmax, idx = d, i
    if dmax <= tol:
        return [pts[0], pts[-1]]
    return simplify(pts[:idx + 1], tol)[:-1] + simplify(pts[idx:], tol)


def rd(pts):
    return [[round(la, 6), round(lo, 6)] for la, lo in pts]


def inside(p):
    return S <= p[0] <= N and W <= p[1] <= E


def cut(a, b):
    """Point where segment a->b crosses the bbox border (one endpoint in)."""
    for _ in range(40):  # bisection: plenty for cm precision
        m = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)
        if inside(m) == inside(a):
            a = m
        else:
            b = m
    return ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)


def clip_line(pts):
    """Split a polyline into the runs that lie inside the bbox, ending each
    run exactly at the border. Overpass returns whole ways, so a road crossing
    the campus can drag kilometres of geometry with it otherwise."""
    runs, cur = [], []
    for i, p in enumerate(pts):
        if inside(p):
            if not cur and i > 0:
                cur.append(cut(pts[i - 1], p))
            cur.append(p)
        elif cur:
            cur.append(cut(cur[-1], p))
            if len(cur) >= 2:
                runs.append(cur)
            cur = []
    if len(cur) >= 2:
        runs.append(cur)
    return runs


def clip_poly(pts):
    """Sutherland-Hodgman clip of a polygon to the bbox."""
    def clip_edge(poly, keep, crossing):
        out = []
        for i, cur in enumerate(poly):
            prev = poly[i - 1]
            if keep(cur):
                if not keep(prev):
                    out.append(crossing(prev, cur))
                out.append(cur)
            elif keep(prev):
                out.append(crossing(prev, cur))
        return out

    def x_at(a, b, lat):
        t = (lat - a[0]) / (b[0] - a[0])
        return (lat, a[1] + (b[1] - a[1]) * t)

    def y_at(a, b, lon):
        t = (lon - a[1]) / (b[1] - a[1])
        return (a[0] + (b[0] - a[0]) * t, lon)

    poly = list(pts)
    poly = clip_edge(poly, lambda p: p[0] >= S, lambda a, b: x_at(a, b, S))
    if len(poly) < 3:
        return []
    poly = clip_edge(poly, lambda p: p[0] <= N, lambda a, b: x_at(a, b, N))
    if len(poly) < 3:
        return []
    poly = clip_edge(poly, lambda p: p[1] >= W, lambda a, b: y_at(a, b, W))
    if len(poly) < 3:
        return []
    poly = clip_edge(poly, lambda p: p[1] <= E, lambda a, b: y_at(a, b, E))
    return poly if len(poly) >= 3 else []


def main():
    data = fetch()
    roads_major, roads_minor, buildings, green, water = [], [], [], [], []

    for e in data.get('elements', []):
        if e.get('type') != 'way' or 'geometry' not in e:
            continue
        tags = e.get('tags', {})
        pts = [(g['lat'], g['lon']) for g in e['geometry']]
        closed = len(pts) > 3 and pts[0] == pts[-1]

        hw = tags.get('highway')
        if hw in DRIVABLE:
            target = roads_major if hw in MAJOR else roads_minor
            for run in clip_line(pts):
                target.append(rd(simplify(run, 1.5)))
        elif 'building' in tags and closed:
            clipped = clip_poly(pts[:-1])
            if clipped:
                buildings.append(rd(simplify(clipped, 1.0)))
        elif closed and (tags.get('landuse') in GREEN_LANDUSE
                         or tags.get('leisure') in GREEN_LEISURE
                         or tags.get('natural') in ('wood', 'scrub')):
            clipped = clip_poly(pts[:-1])
            if clipped:
                green.append(rd(simplify(clipped, 2.0)))
        elif closed and tags.get('natural') == 'water':
            clipped = clip_poly(pts[:-1])
            if clipped:
                water.append(rd(simplify(clipped, 2.0)))

    out = {
        '_attribution': 'Map data (c) OpenStreetMap contributors (ODbL)',
        '_bbox': [S, W, N, E],
        'roadsMajor': roads_major,
        'roadsMinor': roads_minor,
        'buildings': buildings,
        'green': green,
        'water': water,
    }
    with open('data/basemap.json', 'w') as f:
        json.dump(out, f, separators=(',', ':'))
        f.write('\n')

    total = sum(len(v) for v in
                (roads_major, roads_minor, buildings, green, water))
    size = len(json.dumps(out, separators=(",", ":"))) / 1024
    print(f'roadsMajor={len(roads_major)} roadsMinor={len(roads_minor)} '
          f'buildings={len(buildings)} green={len(green)} water={len(water)} '
          f'total={total} features, {size:.0f} KB')
    if not roads_minor:
        sys.exit('ERROR: no minor roads — Overpass result looks wrong')


if __name__ == '__main__':
    main()
