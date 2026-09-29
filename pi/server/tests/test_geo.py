from __future__ import annotations

import math

from app.geo import Plane, RouteGeometry, bearing_diff, haversine_m


def test_plane_roundtrip_is_exact_at_campus_scale():
    plane = Plane(11.318, 75.934)
    lat, lng = 11.3215, 75.9370
    back = plane.to_latlng(*plane.to_xy(lat, lng))
    assert math.isclose(back[0], lat, abs_tol=1e-9)
    assert math.isclose(back[1], lng, abs_tol=1e-9)


def test_plane_distance_matches_haversine():
    plane = Plane(11.318, 75.934)
    a = (11.317194, 75.937560)
    b = (11.323114, 75.937258)
    ax, ay = plane.to_xy(*a)
    bx, by = plane.to_xy(*b)
    planar = math.hypot(bx - ax, by - ay)
    assert abs(planar - haversine_m(*a, *b)) < 0.5


def test_bearing_diff_wraps():
    assert bearing_diff(350, 10) == 20
    assert bearing_diff(10, 350) == 20
    assert bearing_diff(0, 180) == 180


def _line() -> RouteGeometry:
    plane = Plane(11.318, 75.934)
    pts = [(11.318, 75.934), (11.318, 75.935), (11.319, 75.935)]
    return RouteGeometry(plane, pts)


def test_projection_on_segment():
    g = _line()
    # A point just north of the first segment's midpoint.
    proj = g.project(11.31805, 75.9345)
    assert proj.offset_m < 10
    assert 0 < proj.along_m < g.length_m


def test_position_at_is_inverse_of_projection():
    g = _line()
    for along in (0.0, g.length_m * 0.25, g.length_m * 0.9, g.length_m):
        lat, lng, _ = g.position_at(along)
        assert abs(g.project(lat, lng).along_m - along) < 0.5


def test_degenerate_geometry_is_not_usable():
    g = RouteGeometry(Plane(11.318, 75.934), [(11.318, 75.934)])
    assert not g.usable
