import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tracker/models.dart';

/// The contract between the Raspberry Pi and this app.
///
/// This payload is a verbatim capture from the Python processor's snapshot(), not
/// a hand-written guess, so a change on the server that would break the app fails
/// here rather than on a phone.
const String _snapshot = '''
{
  "type": "snapshot",
  "ts": 1790000040,
  "config_version": "f488a2475304",
  "buses": [
    {
      "id": "bus1", "lat": 11.318808, "lng": 75.93671,
      "heading": 281.8, "speed": 8.0,
      "route": "mbh_to_east", "progress": 0.2455, "progress_m": 294.0,
      "status": "live", "age": 3.0,
      "journey_state": "outbound", "origin": null, "destination": null,
      "next_stop": "atm_circle", "next_stop_m": 497.5,
      "eta_s": 62, "eta_confident": true, "at_stop": null
    },
    {
      "id": "bus2", "lat": null, "lng": null,
      "heading": null, "speed": 0.0,
      "route": null, "progress": null, "progress_m": 0.0,
      "status": "offline", "age": null,
      "journey_state": "outbound", "origin": null, "destination": null,
      "next_stop": null, "next_stop_m": null,
      "eta_s": null, "eta_confident": false, "at_stop": null
    }
  ]
}
''';

List<BusPosition> _parse(String raw) {
  final body = jsonDecode(raw) as Map<String, dynamic>;
  final out = <BusPosition>[];
  for (final entry in body['buses'] as List) {
    final bp = BusPosition.fromLive(entry as Map<String, dynamic>);
    if (bp != null) out.add(bp);
  }
  return out;
}

void main() {
  group('server snapshot parsing', () {
    test('a tracked bus keeps every field the server computed', () {
      final buses = _parse(_snapshot);
      final bus1 = buses.firstWhere((b) => b.busId == 'bus1');

      expect(bus1.lat, 11.318808);
      expect(bus1.lng, 75.93671);
      expect(bus1.heading, 281.8);
      expect(bus1.speed, 8.0);
      expect(bus1.routeId, 'mbh_to_east');
      expect(bus1.progress, 0.2455);
      expect(bus1.nextStop, 'atm_circle');
      expect(bus1.etaSec, 62);
      expect(bus1.etaConfident, isTrue);
      expect(bus1.serverStatus, 'live');
      expect(bus1.atStop, isNull);
    });

    test('a bus the server has no fix for is dropped, not drawn at (0,0)', () {
      final buses = _parse(_snapshot);
      expect(buses.map((b) => b.busId), ['bus1']);
      expect(buses.length, 1);
    });

    test('status from the server decides staleness, not a local clock', () {
      final live = BusPosition.fromLive({
        'id': 'bus1', 'lat': 11.3, 'lng': 75.9, 'status': 'live', 'age': 3.0,
      })!;
      final stale = BusPosition.fromLive({
        'id': 'bus2', 'lat': 11.3, 'lng': 75.9, 'status': 'stale', 'age': 80.0,
      })!;
      final offline = BusPosition.fromLive({
        'id': 'bus3', 'lat': 11.3, 'lng': 75.9, 'status': 'offline', 'age': 900.0,
      })!;
      final delayed = BusPosition.fromLive({
        'id': 'bus4', 'lat': 11.3, 'lng': 75.9, 'status': 'delayed', 'age': 20.0,
      })!;

      expect(live.isStale, isFalse);
      expect(stale.isStale, isTrue);
      expect(offline.isStale, isTrue);
      expect(delayed.isStale, isFalse, reason: 'delayed is still trusted');
      expect(delayed.isDelayed, isTrue);
    });

    test('age comes from the server, so a wrong phone clock cannot skew it', () {
      final bus = BusPosition.fromLive({
        'id': 'bus1', 'lat': 11.3, 'lng': 75.9, 'status': 'live', 'age': 7.5,
      })!;
      expect(bus.age.inMilliseconds, 7500);
    });

    test('a parked bus is reported as such', () {
      final bus = BusPosition.fromLive({
        'id': 'bus1', 'lat': 11.3, 'lng': 75.9,
        'journey_state': 'parked', 'destination': 'mbh', 'status': 'live',
      })!;
      expect(bus.isParked, isTrue);
      expect(bus.destinationId, 'mbh');
    });

    test('malformed or partial entries do not throw', () {
      expect(BusPosition.fromLive({}), isNull);
      expect(BusPosition.fromLive({'id': 'bus1'}), isNull);
      expect(BusPosition.fromLive({'lat': 11.3, 'lng': 75.9}), isNull);
      // Missing optional fields must simply be absent, not fatal.
      final bare = BusPosition.fromLive({'id': 'bus1', 'lat': 11.3, 'lng': 75.9})!;
      expect(bare.etaSec, isNull);
      expect(bare.serverStatus, isNull);
      expect(bare.etaConfident, isFalse);
    });

    test('integer coordinates from JSON are accepted as doubles', () {
      final bus = BusPosition.fromLive({'id': 'bus1', 'lat': 11, 'lng': 75})!;
      expect(bus.lat, 11.0);
      expect(bus.lng, 75.0);
    });
    test('a stale-marked bus is greyed out whatever the payload claimed', () {
      // The bug this guards: every live topic is retained, so a snapshot
      // outlives the server that published it. Its `status` says "live"
      // forever, frozen at publish time. Once the app decides the server has
      // gone quiet it must stop believing that field.
      final fresh = BusPosition.fromLive({
        'id': 'bus1', 'lat': 11.3185, 'lng': 75.9379,
        'status': 'live', 'age': 0.4, 'eta_s': 62, 'eta_confident': true,
      })!;
      expect(fresh.isStale, isFalse, reason: 'claims live, and we believe it');

      final stale = fresh.asStale();
      expect(stale.isStale, isTrue);
      expect(stale.serverStatus, 'stale');
      // An ETA from a dead server is not a confident one.
      expect(stale.etaConfident, isFalse);
      // The position itself is kept: the bus was there, we just cannot vouch
      // for when.
      expect(stale.lat, fresh.lat);
      expect(stale.lng, fresh.lng);
      expect(stale.busId, fresh.busId);
      expect(stale.routeId, fresh.routeId);
    });
  });
}
