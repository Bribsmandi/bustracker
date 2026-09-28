import 'package:flutter_test/flutter_test.dart';
import 'package:tracker/app_data.dart';
import 'package:tracker/models.dart';
import 'package:tracker/tracking.dart';

/// "I'm getting on at Architecture, a bus comes from ATM Circle — it says
/// arrived, but it has to go to East Campus first and back."
///
/// A bus passing your stop on the wrong-direction leg must be offered with an
/// ETA that includes going to the far terminus, waiting for its departure
/// slot, and driving back — never as "arriving".

void main() {
  late AppData data;
  late Tracker tracker;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    data = await AppData.load();
    tracker = Tracker(data);
  });

  BusPosition at(String id, double lat, double lng,
          {double speed = 6,
          String? routeId,
          String? o,
          String? d,
          String? js,
          bool sim = false}) =>
      BusPosition(
          busId: id,
          lat: lat,
          lng: lng,
          speed: speed,
          routeId: routeId,
          originId: o,
          destinationId: d,
          journeyState: js,
          simulated: sim,
          updatedAt: DateTime.now().toUtc());

  group('Architecture -> MBH with an outbound bus (the reported bug)', () {
    // bus1 outbound between Library and Architecture, heading to East Campus.
    final outbound = at('bus1', 11.322135, 75.935460,
        routeId: 'mbh_to_east', o: 'mbh', d: 'east_campus');

    test('the bus is offered via East Campus, not as "arriving"', () {
      final r = tracker.planTrip('architecture', 'mbh', {'bus1': outbound},
          now: DateTime(2026, 1, 5, 12, 30));
      expect(r.plan, isNotNull);
      expect(r.plan!.viaStopId, 'east_campus',
          reason: 'it must go to East Campus and turn around first');
      expect(r.plan!.etaToBoardingSec, greaterThan(600),
          reason: 'ETA must include the trip to East Campus, the wait for the '
              '12:50 departure, and the drive back — not "arriving now"');
      expect(r.plan!.scheduledDeparture, '12:50',
          reason: 'next East Campus -> MBH departure after it arrives there');
    });

    test('a bus already PAST Architecture heading east is also offered via',
        () {
      // Between Architecture and East Campus — previously invisible entirely.
      final past = at('bus1', 11.322871, 75.936436,
          routeId: 'mbh_to_east', o: 'mbh', d: 'east_campus');
      final r = tracker.planTrip('architecture', 'mbh', {'bus1': past},
          now: DateTime(2026, 1, 5, 12, 30));
      expect(r.plan, isNotNull);
      expect(r.plan!.viaStopId, 'east_campus');
    });

    test('same bus, but going the way you want: direct, no via', () {
      // Architecture -> East Campus rides the leg the bus is already on.
      final r = tracker.planTrip('architecture', 'east_campus',
          {'bus1': outbound}, now: DateTime(2026, 1, 5, 12, 30));
      expect(r.plan, isNotNull);
      expect(r.plan!.viaStopId, isNull);
      expect(r.plan!.etaToBoardingSec, lessThan(300),
          reason: 'genuinely a short direct approach');
    });

    test('via bus loses to a direct bus when one exists', () {
      // bus2 coming back from East Campus will reach Architecture directly.
      final direct = at('bus2', 11.323174, 75.937238,
          routeId: 'east_to_mbh', o: 'east_campus', d: 'mbh');
      final r = tracker.planTrip('architecture', 'mbh',
          {'bus1': outbound, 'bus2': direct},
          now: DateTime(2026, 1, 5, 12, 30));
      expect(r.plan!.bus.id, 'bus2',
          reason: 'the bus already heading the right way arrives first');
      expect(r.plan!.viaStopId, isNull);
    });
  });

  group('Simulated buses ignore the timetable', () {
    test('a sim AC bus parked at MBH is offered even late at night', () {
      // 23:30 — the real AC schedule ended at 16:55. A simulated bus must not
      // be demoted by a timetable it does not follow.
      final ac = at('ac_mbh', 11.317194, 75.937560,
          speed: 0,
          routeId: 'ac_arch_to_mbh',
          o: 'architecture',
          d: 'mbh',
          js: 'parked',
          sim: true);
      final r = tracker.planTrip('mbh', 'architecture', {'ac_mbh': ac},
          now: DateTime(2026, 1, 5, 23, 30));
      expect(r.plan, isNotNull);
      expect(r.plan!.finishedForToday, isFalse,
          reason: 'simulated buses have no "end of service"');
      expect(r.plan!.etaToBoardingSec, lessThan(60));
    });

    test('among sim buses, the one that truly arrives first wins', () {
      final acParked = at('ac_mbh', 11.317194, 75.937560,
          speed: 0, routeId: 'ac_arch_to_mbh',
          o: 'architecture', d: 'mbh', js: 'parked', sim: true);
      final bus1Inbound = at('bus1', 11.316650, 75.937166,
          routeId: 'east_to_mbh', o: 'east_campus', d: 'mbh', sim: true);

      final r = tracker.planTrip('mbh', 'architecture',
          {'bus1': bus1Inbound, 'ac_mbh': acParked},
          now: DateTime(2026, 1, 5, 12, 30));
      expect(r.plan!.bus.id, 'ac_mbh',
          reason: 'parked at the stop beats still-driving-there');
    });

    test('...and the other way round', () {
      final bus1Parked = at('bus1', 11.317194, 75.937560,
          speed: 0, routeId: 'east_to_mbh',
          o: 'east_campus', d: 'mbh', js: 'parked', sim: true);
      final acFar = at('ac_mbh', 11.318946, 75.934493,
          speed: 5, routeId: 'ac_arch_to_mbh',
          o: 'architecture', d: 'mbh', sim: true);

      final r = tracker.planTrip('mbh', 'architecture',
          {'bus1': bus1Parked, 'ac_mbh': acFar},
          now: DateTime(2026, 1, 5, 12, 30));
      expect(r.plan!.bus.id, 'bus1');
    });

    test('real (non-simulated) buses still follow the timetable', () {
      final acReal = at('ac_mbh', 11.317194, 75.937560,
          speed: 0, routeId: 'ac_arch_to_mbh',
          o: 'architecture', d: 'mbh', js: 'parked');
      final r = tracker.planTrip('mbh', 'architecture', {'ac_mbh': acReal},
          now: DateTime(2026, 1, 5, 23, 30));
      expect(r.plan!.finishedForToday, isTrue,
          reason: 'a real AC bus at 23:30 genuinely has no departures left');
    });
  });
}
