#!/usr/bin/env python3
"""Generate ROUTES.md from the canonical data files.

Written rather than hand-typed so the document cannot drift from what the apps
actually use: every stop, coordinate and departure below is read straight out
of data/*.json.
"""
import json
import math

R = json.load(open('data/routes.json'))['routes']
S = {s['id']: s for s in json.load(open('data/stops.json'))['stops']}
B = {b['id']: b for b in json.load(open('data/buses.json'))['buses']}
C = json.load(open('data/schedule.json'))['schedules']


def metres(a, b):
    r = 6371000
    la1, lo1 = math.radians(a[0]), math.radians(a[1])
    la2, lo2 = math.radians(b[0]), math.radians(b[1])
    return 2 * r * math.asin(math.sqrt(
        math.sin((la2 - la1) / 2) ** 2 +
        math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2))


def length(p):
    return sum(metres(p[i], p[i + 1]) for i in range(len(p) - 1))


def deps_for(route_id):
    out = []
    for s in C:
        if s['routeId'] != route_id:
            continue
        for d in s['departures']:
            t = d if isinstance(d, str) else d['time']
            soms = isinstance(d, dict) and d.get('somsVariant')
            out.append((t, s['busId'], soms))
    return sorted(out)


L = []
w = L.append

w('# Campus bus routes')
w('')
w('Every route the six buses run, with the exact road path each one follows.')
w('Generated from the tracker\'s own data files, so this document and the app '
  'can never disagree.')
w('')

w('## Stops')
w('')
w('| Stop | Terminal? | Latitude | Longitude |')
w('|---|---|---|---|')
for s in S.values():
    w(f"| {s['name']} | {'yes' if s['isTerminal'] else 'no'} | "
      f"{s['lat']:.6f} | {s['lng']:.6f} |")
w('')
w('*Terminal* means buses wait there and turn around. Main Gate is driven past '
  'but is not a halt, so it is not a stop.')
w('')

w('## Routes at a glance')
w('')
w('| Route | Buses | Length | Path points | Scheduled runs/day |')
w('|---|---|---|---|---|')
for r in R:
    p = [tuple(x) for x in r.get('path', [])]
    buses = ', '.join(B[b]['label'] for b in r['buses'])
    w(f"| {r['name']} | {buses} | {length(p):.0f} m | {len(p)} | "
      f"{len(deps_for(r['id']))} |")
w('')

total_pts = sum(len(r.get('path', [])) for r in R)
total_deps = sum(len(s['departures']) for s in C)
w(f'{len(R)} routes, {total_pts} surveyed path points, '
  f'{total_deps} scheduled departures.')
w('')
w('> **MBH runs a one-way loop.** `MBH -> East Campus` and `East Campus -> MBH` '
  'use *different roads* at the MBH end, so they are not reverses of each '
  'other. Every other route retraces its outbound path.')
w('')

for r in R:
    p = [tuple(x) for x in r.get('path', [])]
    w('---')
    w('')
    w(f"## {r['name']}")
    w('')
    w(f"`{r['id']}` &nbsp;&nbsp; **Buses:** "
      f"{', '.join(B[b]['label'] for b in r['buses'])} &nbsp;&nbsp; "
      f"**Length:** {length(p):.0f} m")
    w('')
    w('**Stops in order**')
    w('')
    for i, sid in enumerate(r['stops'], 1):
        st = S[sid]
        w(f"{i}. {st['name']} — `{st['lat']:.6f}, {st['lng']:.6f}`")
    w('')

    d = deps_for(r['id'])
    if d:
        w(f"**Departures from {S[r['origin']]['name']}** "
          f"({len(d)} per day)")
        w('')
        by_bus = {}
        for t, bus, soms in d:
            by_bus.setdefault(bus, []).append(t + ('*' if soms else ''))
        for bus, times in by_bus.items():
            w(f"- {B[bus]['label']}: {', '.join(times)}")
        if any(x[2] for x in d):
            w('')
            w('\\* detours via SOMS')
        w('')
    else:
        w('**Departures:** none printed in the timetable for this direction.')
        w('')

    w(f'**Road path** ({len(p)} points, lat/lng)')
    w('')
    w('```')
    for a, b in p:
        w(f'{a:.6f}, {b:.6f}')
    w('```')
    w('')

open('ROUTES.md', 'w').write('\n'.join(L) + '\n')
print(f'ROUTES.md written: {len(R)} routes, {total_pts} points, '
      f'{total_deps} departures')
