#!/usr/bin/env python3
"""Trace a bus route along real OpenStreetMap road geometry.

Given a handful of waypoints, snap each onto the mapped road network and walk
the actual OSM ways between them, producing a dense polyline that follows the
road rather than cutting across campus.

This is deliberately NOT a routing engine. OSRM was tried and rejected: it
optimises for driving time, ignores which roads buses actually use, and returns
identical geometry in both directions so it cannot express a one-way loop. Here
the waypoints decide the road and the graph only fills in the curves between
them, so the result stays faithful to the surveyed route.
"""
import json
import math
import heapq
import sys

# Roads a bus can use. Footpaths and steps are excluded so a shortcut across a
# pedestrian route is never chosen.
DRIVABLE = {
    'service', 'residential', 'unclassified', 'tertiary', 'tertiary_link',
    'secondary', 'secondary_link', 'primary', 'primary_link', 'living_street',
    'road', 'trunk', 'trunk_link',
}


def haversine(a, b):
    r = 6371000.0
    la1, lo1 = math.radians(a[0]), math.radians(a[1])
    la2, lo2 = math.radians(b[0]), math.radians(b[1])
    h = (math.sin((la2 - la1) / 2) ** 2
         + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(h))


class RoadGraph:
    def __init__(self, osm_path):
        data = json.load(open(osm_path))
        self.pos = {e['id']: (e['lat'], e['lon'])
                    for e in data['elements'] if e['type'] == 'node'}
        self.adj = {}
        kept = 0
        for e in data['elements']:
            if e['type'] != 'way':
                continue
            if e.get('tags', {}).get('highway') not in DRIVABLE:
                continue
            kept += 1
            refs = [n for n in e['nodes'] if n in self.pos]
            for u, v in zip(refs, refs[1:]):
                w = haversine(self.pos[u], self.pos[v])
                # Undirected: the waypoints, not oneway tags, decide direction.
                self.adj.setdefault(u, []).append((v, w))
                self.adj.setdefault(v, []).append((u, w))
        self.ways_kept = kept
        self.node_ids = list(self.adj.keys())

    def nearest_node(self, pt):
        best, bestd = None, float('inf')
        for nid in self.node_ids:
            d = haversine(pt, self.pos[nid])
            if d < bestd:
                best, bestd = nid, d
        return best, bestd

    def shortest_path(self, src, dst):
        """Dijkstra. Returns (list of node ids, length) or (None, inf)."""
        dist = {src: 0.0}
        prev = {}
        pq = [(0.0, src)]
        seen = set()
        while pq:
            d, u = heapq.heappop(pq)
            if u in seen:
                continue
            seen.add(u)
            if u == dst:
                break
            for v, w in self.adj.get(u, ()):
                nd = d + w
                if nd < dist.get(v, float('inf')):
                    dist[v] = nd
                    prev[v] = u
                    heapq.heappush(pq, (nd, v))
        if dst not in dist:
            return None, float('inf')
        path, cur = [dst], dst
        while cur != src:
            cur = prev[cur]
            path.append(cur)
        return path[::-1], dist[dst]

    def trace(self, waypoints):
        """Walk the road network through every waypoint in order."""
        snapped = []
        for wp in waypoints:
            nid, d = self.nearest_node(wp)
            snapped.append((nid, d))

        coords = []
        total = 0.0
        for (a, _), (b, _) in zip(snapped, snapped[1:]):
            nodes, length = self.shortest_path(a, b)
            if nodes is None:
                raise RuntimeError(f'no road path between nodes {a} and {b}')
            total += length
            pts = [self.pos[n] for n in nodes]
            if coords and coords[-1] == pts[0]:
                pts = pts[1:]
            coords.extend(pts)
        return coords, total, [d for _, d in snapped]


def simplify(points, tolerance=2.0):
    """Ramer-Douglas-Peucker, so the stored path is not needlessly dense."""
    if len(points) < 3:
        return points

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
    for i in range(1, len(points) - 1):
        d = perp(points[i], points[0], points[-1])
        if d > dmax:
            dmax, idx = d, i
    if dmax <= tolerance:
        return [points[0], points[-1]]
    return simplify(points[:idx + 1], tolerance)[:-1] + \
        simplify(points[idx:], tolerance)


if __name__ == '__main__':
    graph = RoadGraph(sys.argv[1])
    print(f'graph: {graph.ways_kept} drivable ways, {len(graph.node_ids)} nodes')
