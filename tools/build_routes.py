#!/usr/bin/env python3
"""Fill in the missing route paths in data/routes.json.

Strategy, in order of trustworthiness:
  1. Hand-surveyed geometry, spliced where a route shares road with one that
     was already walked (highest fidelity - these are real GPS points).
  2. OSM road tracing through the waypoints supplied for that route.
  3. A straight segment, used only where OSM has no road at all (the SOMS
     access road is unmapped) - and reported loudly so it is never mistaken
     for surveyed data.
"""
import json
import math
import sys
import collections

sys.path.insert(0, 'tools')
from trace_osm import RoadGraph, haversine, simplify  # noqa: E402

OSM = sys.argv[1]

# ---------------------------------------------------------------- waypoints
LH = (11.318375936974471, 75.93097413326315)
MID_LH = (11.319299803667986, 75.93209652608522)
MAIN_GATE = (11.320062928218942, 75.93285026418218)
CENTRE = (11.321459083780518, 75.93408687633065)
SOMS = (11.314811401038035, 75.93245214275552)
SOMS_A = (11.318719232046407, 75.93333218783121)
SOMS_B = (11.316563233161814, 75.9339143425876)

doc = json.load(open('data/routes.json'), object_pairs_hook=collections.OrderedDict)
routes = {r['id']: r for r in doc['routes']}
stops = {s['id']: (s['lat'], s['lng'])
         for s in json.load(open('data/stops.json'))['stops']}

graph = RoadGraph(OSM)
notes = []


def slice_from(path, stop_id, direction):
    """Cut a surveyed path at a stop. direction 'after' keeps the tail
    (stop -> end); 'before' keeps the head (start -> stop)."""
    pt = stops[stop_id]
    best_i, best_snap, best_d = None, None, 1e9
    for i in range(len(path) - 1):
        a, b = path[i], path[i + 1]
        lat0 = math.radians(pt[0])

        def xy(q):
            return (math.radians(q[1] - pt[1]) * math.cos(lat0) * 6371000,
                    math.radians(q[0] - pt[0]) * 6371000)
        (x1, y1), (x2, y2) = xy(a), xy(b)
        dx, dy = x2 - x1, y2 - y1
        L2 = dx * dx + dy * dy
        t = 0 if L2 == 0 else max(0, min(1, (-x1 * dx - y1 * dy) / L2))
        d = math.hypot(x1 + t * dx, y1 + t * dy)
        if d < best_d:
            best_d = d
            best_i = i
            best_snap = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
    if direction == 'after':
        return [best_snap] + path[best_i + 1:], best_d
    return path[:best_i + 1] + [best_snap], best_d


def trace(waypoints, label):
    pts, length, snaps = graph.trace(waypoints)
    worst = max(snaps)
    if worst > 20:
        notes.append(f'{label}: a waypoint snapped {worst:.0f} m from any road')
    return simplify(pts, 2.0)


def length_of(p):
    return sum(haversine(p[i], p[i + 1]) for i in range(len(p) - 1))


def join(*segments):
    out = []
    for seg in segments:
        if out and haversine(out[-1], seg[0]) < 5:
            seg = seg[1:]
        out.extend(seg)
    return out


mbh_east = [tuple(p) for p in routes['mbh_to_east']['path']]
east_mbh = [tuple(p) for p in routes['east_to_mbh']['path']]

# --------------------------------------------------- LH <-> East Campus
# LH end is traced from the supplied waypoints; the shared stretch from ATM
# Circle onward is spliced from the hand survey.
lh_to_atm = trace([LH, MID_LH, MAIN_GATE, CENTRE, stops['atm_circle']], 'lh->atm')
atm_to_east, snap1 = slice_from(mbh_east, 'atm_circle', 'after')
lh_east = join(lh_to_atm, atm_to_east)

east_to_atm, snap2 = slice_from(east_mbh, 'atm_circle', 'before')
east_lh = join(east_to_atm, list(reversed(lh_to_atm)))

# --------------------------------------------------- AC: LH <-> Architecture
arch_from_lh, snap3 = slice_from(lh_east, 'architecture', 'before')
arch_to_lh, snap4 = slice_from(east_lh, 'architecture', 'after')

# --------------------------------------------------- SOMS <-> East Campus
# OSM has no road to SOMS (it snaps 73 m away), so the last leg is drawn
# straight. Everything before it is traced.
lh_to_somsB = trace([LH, SOMS_A, SOMS_B], 'lh->soms')
lh_soms = lh_to_somsB + [SOMS]
notes.append(
    f'SOMS: final {haversine(SOMS_B, SOMS):.0f} m drawn STRAIGHT - '
    'no road to SOMS exists in OpenStreetMap')

soms_east = join(list(reversed(lh_soms)), lh_east)
east_soms = join(east_lh, lh_soms)

built = {
    'lh_to_east': lh_east,
    'east_to_lh': east_lh,
    'ac_lh_out': arch_from_lh,
    'ac_arch_to_lh': arch_to_lh,
    'soms_to_east': soms_east,
    'east_to_soms': east_soms,
}

print(f'{"route":16s} {"pts":>4} {"length":>9}   endpoints check')
for rid, pts in built.items():
    r = routes[rid]
    o, d = stops[r['origin']], stops[r['destination']]
    eo, ed = haversine(pts[0], o), haversine(pts[-1], d)
    ok = 'ok' if eo < 40 and ed < 40 else f'OFF start {eo:.0f}m end {ed:.0f}m'
    print(f'{rid:16s} {len(pts):4d} {length_of(pts):7.0f} m   {ok}')
    r['path'] = [[round(a, 6), round(b, 6)] for a, b in pts]

print('\nsplice accuracy (surveyed path cut at a stop):')
for name, v in (('atm after', snap1), ('atm before', snap2),
                ('arch before', snap3), ('arch after', snap4)):
    print(f'  {name:12s} {v:5.1f} m')

if notes:
    print('\nNOTES:')
    for n in notes:
        print('  - ' + n)

doc['_pathProvenance'] = (
    'mbh_to_east / east_to_mbh: hand-surveyed GPS points. '
    'ac_mbh_out / ac_arch_to_mbh: sliced from those surveys. '
    'LH and SOMS routes: traced along OpenStreetMap road geometry through '
    'supplied waypoints, with the ATM-Circle-to-East-Campus stretch spliced '
    'from the hand survey. The final ~250 m into SOMS is a straight line '
    'because no road to SOMS is mapped in OSM.')

json.dump(doc, open('data/routes.json', 'w'), indent=2)
open('data/routes.json', 'a').write('\n')
print('\nwritten to data/routes.json')
