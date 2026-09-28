import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tracker/app_data.dart';
import 'package:tracker/bus_marker.dart';
import 'package:tracker/tracking.dart';

double deg(double rad) => rad * 180 / math.pi;

void main() {
  group('Side-view bus orientation', () {
    test('east: faces right, no rotation', () {
      final o = busOrientation(90);
      expect(o.mirrored, isFalse);
      expect(deg(o.angleRad), closeTo(0, 0.01));
    });

    test('west: mirrored, no rotation', () {
      final o = busOrientation(270);
      expect(o.mirrored, isTrue);
      expect(deg(o.angleRad), closeTo(0, 0.01));
    });

    test('north and south stay within a quarter turn', () {
      expect(deg(busOrientation(0).angleRad), closeTo(-90, 0.01));
      expect(deg(busOrientation(180).angleRad), closeTo(90, 0.01));
    });

    test('diagonals rotate the correct way', () {
      // North-east: nose up-right.
      final ne = busOrientation(45);
      expect(ne.mirrored, isFalse);
      expect(deg(ne.angleRad), closeTo(-45, 0.01));
      // South-west: mirrored, nose down-left.
      final sw = busOrientation(225);
      expect(sw.mirrored, isTrue);
      expect(deg(sw.angleRad), closeTo(-45, 0.01));
    });

    test('never rotates beyond +-90 degrees, so wheels stay down', () {
      for (var b = 0.0; b < 360; b += 5) {
        final o = busOrientation(b);
        expect(deg(o.angleRad).abs(), lessThanOrEqualTo(90.01),
            reason: 'bearing $b would draw the bus upside down');
      }
    });

    test('normalises out-of-range bearings', () {
      expect(busOrientation(450).mirrored, busOrientation(90).mirrored);
      expect(busOrientation(-90).mirrored, busOrientation(270).mirrored);
    });
  });

  group('Upcoming departures for a trip', () {
    late AppData data;
    late Tracker tracker;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      data = await AppData.load();
      tracker = Tracker(data);
    });

    test('MBH -> East Campus at 17:25 lists the remaining runs in order', () {
      final deps = tracker.upcomingDepartures('mbh', 'east_campus',
          now: DateTime(2026, 1, 5, 17, 25));
      // bus1: 17:30, 17:50. bus2: 17:40, 18:00.
      expect(deps.map((d) => d.time).toList(),
          ['17:30', '17:40', '17:50', '18:00']);
      expect(deps.first.bus.id, 'bus1');
      expect(deps.every((d) => d.originId == 'mbh'), isTrue);
    });

    test('MBH -> Architecture includes the AC bus times too', () {
      final deps = tracker.upcomingDepartures('mbh', 'architecture',
          now: DateTime(2026, 1, 5, 16, 45));
      final buses = deps.map((d) => d.bus.id).toSet();
      expect(buses.contains('ac_mbh'), isTrue, reason: 'AC serves this trip');
      expect(buses.contains('bus1'), isTrue);
      // Sorted throughout.
      for (var i = 1; i < deps.length; i++) {
        expect(deps[i].minutesOfDay, greaterThanOrEqualTo(deps[i - 1].minutesOfDay));
      }
    });

    test('a mid-route boarding still shows origin-terminal times, labelled', () {
      final deps = tracker.upcomingDepartures('atm_circle', 'east_campus',
          now: DateTime(2026, 1, 5, 12, 0));
      expect(deps, isNotEmpty);
      // Times come from more than one terminal (MBH, LH, SOMS routes all
      // pass ATM Circle) — the origin id is what lets the UI say which.
      expect(deps.map((d) => d.originId).toSet().length, greaterThan(1));
    });

    test('late at night the list is empty', () {
      final deps = tracker.upcomingDepartures('mbh', 'east_campus',
          now: DateTime(2026, 1, 5, 23, 30));
      expect(deps, isEmpty);
    });

    test('never lists a departure in the past', () {
      final deps = tracker.upcomingDepartures('mbh', 'east_campus',
          now: DateTime(2026, 1, 5, 12, 45));
      expect(deps.every((d) => d.minutesOfDay >= 12 * 60 + 45), isTrue);
    });
  });
}
