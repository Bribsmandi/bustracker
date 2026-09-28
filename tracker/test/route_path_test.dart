import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tracker/geo.dart';

/// The surveyed MBH -> East Campus path (outbound side of the one-way loop).
final outbound = <LatLng>[
  const LatLng(11.317194, 75.937560), // MBH
  const LatLng(11.317845, 75.937762),
  const LatLng(11.318555, 75.937940),
  const LatLng(11.318817, 75.936666),
  const LatLng(11.318680, 75.936515),
  const LatLng(11.318522, 75.936282),
  const LatLng(11.318522, 75.936165),
  const LatLng(11.318598, 75.936137),
  const LatLng(11.318757, 75.935764),
  const LatLng(11.318712, 75.935637),
  const LatLng(11.318671, 75.935603), // junction
  const LatLng(11.318748, 75.935358),
  const LatLng(11.318803, 75.934986),
  const LatLng(11.318946, 75.934493),
  const LatLng(11.319686, 75.934562),
  const LatLng(11.319904, 75.934558),
  const LatLng(11.320429, 75.934506),
  const LatLng(11.320989, 75.934530), // ~ATM Circle
  const LatLng(11.321137, 75.934562),
  const LatLng(11.321649, 75.935001), // ~Library
  const LatLng(11.321693, 75.935073),
  const LatLng(11.322135, 75.935460),
  const LatLng(11.322345, 75.935575),
  const LatLng(11.322658, 75.935830),
  const LatLng(11.322787, 75.936077), // ~Architecture
  const LatLng(11.322871, 75.936436),
  const LatLng(11.323224, 75.937195),
  const LatLng(11.323174, 75.937238), // East Campus
];

const mbh = LatLng(11.317194, 75.937560);
const eastCampus = LatLng(11.323114, 75.937258);
const architecture = LatLng(11.322796, 75.936170);
const library = LatLng(11.321631, 75.934986);
const atmCircle = LatLng(11.320985, 75.934536);

void main() {
  final geom = RouteGeometry(outbound, stopPositions: {
    'mbh': mbh,
    'atm_circle': atmCircle,
    'library': library,
    'architecture': architecture,
    'east_campus': eastCampus,
  });

  group('Surveyed path geometry', () {
    test('follows the road, so it is longer than the straight line', () {
      final crow = haversineMeters(mbh, eastCampus);
      expect(geom.totalLength, greaterThan(1100));
      expect(geom.totalLength, lessThan(1300));
      expect(geom.totalLength, greaterThan(crow * 1.5),
          reason: 'the loop road is far longer than the direct line');
    });

    test('stops sit along the path in the correct travel order', () {
      final mbhAt = geom.stopAlong['mbh']!;
      final atm = geom.stopAlong['atm_circle']!;
      final lib = geom.stopAlong['library']!;
      final arch = geom.stopAlong['architecture']!;
      final east = geom.stopAlong['east_campus']!;

      expect(mbhAt, lessThan(atm));
      expect(atm, lessThan(lib));
      expect(lib, lessThan(arch));
      expect(arch, lessThan(east));

      expect(mbhAt, closeTo(0, 5), reason: 'MBH is the start of this path');
      expect(east, closeTo(geom.totalLength, 30),
          reason: 'East Campus is at the far end');
    });

    test('every stop lies close to the surveyed road', () {
      for (final entry in {
        'atm_circle': atmCircle,
        'library': library,
        'architecture': architecture,
        'east_campus': eastCampus,
      }.entries) {
        final off = geom.project(entry.value).offRouteMeters;
        expect(off, lessThan(15),
            reason: '${entry.key} should be within 15 m of the path');
      }
    });

    test('a bus on the road snaps onto the path, not across campus', () {
      // A point taken directly from the surveyed path.
      final p = geom.project(const LatLng(11.320429, 75.934506));
      expect(p.offRouteMeters, lessThan(1));
      expect(p.distanceAlong, greaterThan(0));
      expect(p.distanceAlong, lessThan(geom.totalLength));
    });
  });

  group('splitAt — covered vs remaining route', () {
    test('nothing covered at the start', () {
      final s = geom.splitAt(0);
      expect(s.covered, isEmpty);
      expect(s.remaining.length, outbound.length);
    });

    test('everything covered at the end', () {
      final s = geom.splitAt(geom.totalLength);
      expect(s.covered.length, outbound.length);
      expect(s.remaining, isEmpty);
    });

    test('splits at the halfway point and the pieces rejoin', () {
      final half = geom.totalLength / 2;
      final s = geom.splitAt(half);

      expect(s.covered.length, greaterThan(1));
      expect(s.remaining.length, greaterThan(1));

      // The two halves must meet exactly at the cut.
      expect(haversineMeters(s.covered.last, s.remaining.first), lessThan(0.5));

      // The covered piece must actually measure about half the route.
      final coveredLen = RouteGeometry(s.covered).totalLength;
      expect(coveredLen, closeTo(half, 5));
    });

    test('a bus partway along yields a covered piece ending at the bus', () {
      const busOnRoad = LatLng(11.320429, 75.934506);
      final along = geom.project(busOnRoad).distanceAlong;
      final s = geom.splitAt(along);

      expect(haversineMeters(s.covered.last, busOnRoad), lessThan(5),
          reason: 'the dark blue line should end where the bus is');
      expect(s.remaining.first, s.covered.last,
          reason: 'remaining route starts where covered route stopped');
    });
  });

  group('One-way loop safety', () {
    test('outbound path stays clear of the return road near the junction', () {
      // The return road begins here. It is deliberately NOT part of the
      // outbound polyline — the two directions use different roads.
      const returnStart = LatLng(11.318571, 75.935555);
      final off = geom.project(returnStart).offRouteMeters;

      // Close enough that a naive radius trigger would misfire on the way out,
      // which is exactly why direction comes from the journey, not proximity.
      expect(off, lessThan(20));
      expect(off, greaterThan(5));
    });
  });
}
