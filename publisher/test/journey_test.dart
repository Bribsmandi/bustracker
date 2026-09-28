import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:publisher/config.dart';
import 'package:publisher/journey.dart';

/// Real campus coordinates so the distances under test are realistic.
final mbh = StopPoint(
    id: 'mbh', name: 'MBH', isTerminal: true, lat: 11.317194, lng: 75.937560);
final east = StopPoint(
    id: 'east_campus',
    name: 'East Campus',
    isTerminal: true,
    lat: 11.323114,
    lng: 75.937258);

final stops = {'mbh': mbh, 'east_campus': east};

/// Offset a coordinate by roughly [metres] northwards.
double latPlus(double lat, double metres) => lat + metres / 111320.0;

final t0 = DateTime.utc(2026, 1, 1, 8, 0, 0);
DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

/// Drive a bus to its destination and let it settle into the parked state.
/// Returns the journey and the timestamp reached.
({Journey j, int t}) parkedAtEast() {
  final j = Journey(originId: 'mbh', destinationId: 'east_campus');
  var t = 0;
  // Arrive and sit still for longer than the settle window.
  for (; t <= 40; t += Config.fixInterval.inSeconds) {
    j.update(east.lat, east.lng, stops, speed: 0, now: at(t));
  }
  return (j: j, t: t);
}

void main() {
  group('Parking requires the bus to actually settle', () {
    test('passing through the terminal at speed does not park it', () {
      final j = Journey(originId: 'mbh', destinationId: 'east_campus');
      // Right on top of the terminal, but moving and never lingering.
      var t = 0;
      for (var i = 0; i < 5; i++, t += 3) {
        j.update(latPlus(east.lat, i * 12.0), east.lng, stops,
            speed: 8, now: at(t));
      }
      expect(j.state, JourneyState.outbound,
          reason: 'a bus driving past must not be recorded as parked');
    });

    test('parks once it has been stationary for the settle window', () {
      final r = parkedAtEast();
      expect(r.j.state, JourneyState.parked);
      expect(r.j.originId, 'mbh');
      expect(r.j.destinationId, 'east_campus');
    });

    test('does not park on the very first fix in range', () {
      final j = Journey(originId: 'mbh', destinationId: 'east_campus');
      j.update(east.lat, east.lng, stops, speed: 0, now: at(0));
      expect(j.state, JourneyState.outbound,
          reason: 'one fix cannot prove the bus has stopped');
    });
  });

  group('GPS jitter must not fake a departure', () {
    test('a parked bus drifting +/-12 m never starts the return trip', () {
      final r = parkedAtEast();
      final j = r.j;
      var t = r.t;

      // 5 minutes of realistic stationary drift: wanders up to ~12 m, and the
      // fused-location speed occasionally reports a spurious 1-3 m/s.
      final rnd = math.Random(42);
      for (var i = 0; i < 100; i++) {
        t += Config.fixInterval.inSeconds;
        final driftM = (rnd.nextDouble() * 24) - 12; // -12..+12 m
        final noisySpeed = rnd.nextDouble() * 3; // 0..3 m/s, below the 2 m/s bar much of the time
        j.update(latPlus(east.lat, driftM), east.lng, stops,
            speed: noisySpeed, now: at(t));
      }

      expect(j.state, JourneyState.parked,
          reason: 'drift alone must never be read as departure');
      expect(j.originId, 'mbh');
      expect(j.destinationId, 'east_campus');
    });

    test('distance without sustained speed is not a departure', () {
      final r = parkedAtEast();
      final j = r.j;
      // Well beyond 25 m, but stationary — e.g. a bad fix.
      final flipped = j.update(latPlus(east.lat, 60), east.lng, stops,
          speed: 0, now: at(r.t + 3));
      expect(flipped, isFalse);
      expect(j.state, JourneyState.parked);
    });

    test('speed without distance is not a departure', () {
      final r = parkedAtEast();
      final j = r.j;
      var t = r.t;
      // Reporting motion while staying in the bay (idling, bad speed samples).
      for (var i = 0; i < 6; i++) {
        t += 3;
        j.update(east.lat, east.lng, stops, speed: 9, now: at(t));
      }
      expect(j.state, JourneyState.parked);
    });
  });

  group('Genuine departure flips the direction', () {
    test('driving away starts the return journey and swaps endpoints', () {
      final r = parkedAtEast();
      final j = r.j;
      var t = r.t;
      var flipped = false;

      // Pull away properly: increasing distance at road speed.
      for (var i = 1; i <= 6 && !flipped; i++) {
        t += 3;
        flipped = j.update(latPlus(east.lat, 15.0 * i), east.lng, stops,
            speed: 6, now: at(t));
      }

      expect(flipped, isTrue);
      expect(j.state, JourneyState.outbound);
      expect(j.originId, 'east_campus', reason: 'destination becomes origin');
      expect(j.destinationId, 'mbh', reason: 'heading back where it came from');
    });

    test('flips only once per park — no repeated swapping', () {
      final r = parkedAtEast();
      final j = r.j;
      var t = r.t;
      for (var i = 1; i <= 6; i++) {
        t += 3;
        j.update(latPlus(east.lat, 15.0 * i), east.lng, stops,
            speed: 6, now: at(t));
      }
      expect(j.originId, 'east_campus');

      // Continuing to drive must not flip it back.
      for (var i = 7; i <= 14; i++) {
        t += 3;
        expect(
            j.update(latPlus(east.lat, 15.0 * i), east.lng, stops,
                speed: 6, now: at(t)),
            isFalse);
      }
      expect(j.originId, 'east_campus');
      expect(j.destinationId, 'mbh');
    });

    test('a surveyed trigger point also starts the return', () {
      final eastWithTrigger = StopPoint(
        id: 'east_campus',
        name: 'East Campus',
        isTerminal: true,
        lat: east.lat,
        lng: east.lng,
        triggerLat: latPlus(east.lat, 100),
        triggerLng: east.lng,
      );
      final s = {'mbh': mbh, 'east_campus': eastWithTrigger};

      final j = Journey(originId: 'mbh', destinationId: 'east_campus');
      var t = 0;
      for (; t <= 40; t += 3) {
        j.update(east.lat, east.lng, s, speed: 0, now: at(t));
      }
      expect(j.state, JourneyState.parked);

      // Reaching the trigger flips it even without a long speed streak.
      final flipped =
          j.update(latPlus(east.lat, 95), east.lng, s, speed: 0, now: at(t + 3));
      expect(flipped, isTrue);
      expect(j.originId, 'east_campus');
    });
  });

  group('Route selection', () {
    final routes = [
      RouteOption('mbh_to_east', 'mbh', 'east_campus'),
      RouteOption('east_to_mbh', 'east_campus', 'mbh'),
    ];

    test('picks the route matching the current direction, and follows a flip',
        () {
      final r = parkedAtEast();
      final j = r.j;
      expect(j.routeIdFrom(routes), 'mbh_to_east');

      var t = r.t;
      for (var i = 1; i <= 6; i++) {
        t += 3;
        j.update(latPlus(east.lat, 15.0 * i), east.lng, stops,
            speed: 6, now: at(t));
      }
      expect(j.routeIdFrom(routes), 'east_to_mbh');
    });

    test('returns null for an endpoint pair with no scheduled route', () {
      final j = Journey(originId: 'mbh', destinationId: 'soms');
      expect(j.routeIdFrom(routes), isNull);
    });
  });

  test('thresholds are the agreed values', () {
    expect(Config.arriveRadiusM, 40.0);
    expect(Config.parkedWindow, const Duration(seconds: 30));
    expect(Config.parkedMaxDriftM, 15.0);
    expect(Config.departMinDistanceM, 25.0);
    expect(Config.departMinSpeedMps, 2.0);
    expect(Config.departMinConsecutiveFixes, 3);
  });
}
