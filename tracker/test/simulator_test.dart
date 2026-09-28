import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tracker/geo.dart';

/// The simulator's correctness rests on RouteGeometry.positionAt: if that walks
/// the polyline properly, a bus driven by increasing `along` follows the road.
/// These tests cover it directly, since driving the full BusSimulator needs
/// asset loading and a live Timer.

final path = <LatLng>[
  const LatLng(11.317194, 75.937560), // MBH
  const LatLng(11.317845, 75.937762),
  const LatLng(11.318555, 75.937940),
  const LatLng(11.318817, 75.936666),
  const LatLng(11.318680, 75.936515),
  const LatLng(11.318522, 75.936282),
  const LatLng(11.320989, 75.934530),
  const LatLng(11.321649, 75.935001),
  const LatLng(11.322787, 75.936077),
  const LatLng(11.323174, 75.937238), // East Campus
];

void main() {
  final geom = RouteGeometry(path);

  group('positionAt walks the route', () {
    test('starts at the origin and ends at the destination', () {
      expect(haversineMeters(geom.positionAt(0).point, path.first),
          lessThan(0.5));
      expect(haversineMeters(geom.positionAt(geom.totalLength).point, path.last),
          lessThan(0.5));
    });

    test('clamps rather than running off either end', () {
      expect(haversineMeters(geom.positionAt(-500).point, path.first),
          lessThan(0.5));
      expect(
          haversineMeters(
              geom.positionAt(geom.totalLength + 5000).point, path.last),
          lessThan(0.5));
    });

    test('every sampled point lies on the road, never cutting across', () {
      for (var d = 0.0; d <= geom.totalLength; d += 10) {
        final off = geom.project(geom.positionAt(d).point).offRouteMeters;
        expect(off, lessThan(1.0),
            reason: 'point at ${d}m drifted off the polyline');
      }
    });

    test('distance along advances monotonically with the parameter', () {
      var prev = -1.0;
      for (var d = 0.0; d <= geom.totalLength; d += 25) {
        final along = geom.project(geom.positionAt(d).point).distanceAlong;
        expect(along, greaterThanOrEqualTo(prev - 1.0),
            reason: 'bus went backwards at ${d}m');
        prev = along;
      }
    });

    test('a simulated bus covers ground at the speed it was given', () {
      // 6 m/s for 10 s should move ~60 m along the route.
      const speed = 6.0;
      final a = geom.positionAt(100);
      final b = geom.positionAt(100 + speed * 10);
      final moved = haversineMeters(a.point, b.point);
      // Straight-line distance is <= path distance, and this stretch is fairly
      // direct, so allow a generous lower bound for curvature.
      expect(moved, greaterThan(40));
      expect(moved, lessThan(61));
    });

    test('bearing points along the direction of travel', () {
      final here = geom.positionAt(200);
      final ahead = geom.positionAt(230);
      final actual = bearingDegrees(here.point, ahead.point);
      expect(bearingDiff(here.bearing, actual), lessThan(30),
          reason: 'marker would point the wrong way');
    });
  });

  group('Degenerate geometry does not crash', () {
    test('single point route', () {
      final g = RouteGeometry([path.first]);
      expect(g.positionAt(50).point, path.first);
      expect(g.isUsable, isFalse);
    });

    test('empty route', () {
      final g = RouteGeometry(const []);
      expect(g.positionAt(10).point, const LatLng(0, 0));
      expect(g.isUsable, isFalse);
    });
  });
}
