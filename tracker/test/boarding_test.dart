import 'package:flutter_test/flutter_test.dart';
import 'package:tracker/app_data.dart';
import 'package:tracker/models.dart';
import 'package:tracker/tracking.dart';

/// "When the boarding point is MBH, show the next bus available to board, not
/// the bus going through that route."
///
/// The bus you board at MBH is usually one currently driving *back* to MBH, not
/// one already on the MBH -> East leg. These tests pin that behaviour down.

void main() {
  late AppData data;
  late Tracker tracker;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    data = await AppData.load();
    tracker = Tracker(data);
  });

  BusPosition at(
    String busId,
    double lat,
    double lng, {
    double speed = 6,
    String? routeId,
    String? journeyState,
    String? originId,
    String? destinationId,
  }) =>
      BusPosition(
        busId: busId,
        lat: lat,
        lng: lng,
        speed: speed,
        heading: null,
        routeId: routeId,
        originId: originId,
        destinationId: destinationId,
        journeyState: journeyState,
        updatedAt: DateTime.now().toUtc(),
      );

  group('Boarding at MBH', () {
    test('offers a bus that is on its way back to MBH', () {
      // bus1 partway along East -> MBH. It has not reached MBH yet, so under
      // the old logic it was invisible to someone standing at MBH.
      final inbound = at('bus1', 11.318282, 75.935702,
          routeId: 'east_to_mbh',
          originId: 'east_campus',
          destinationId: 'mbh');

      final r = tracker.planTrip('mbh', 'east_campus', {'bus1': inbound});

      expect(r.plan, isNotNull,
          reason: 'a bus inbound to MBH is the next boardable bus there');
      expect(r.plan!.bus.id, 'bus1');
      expect(r.plan!.arrivingToTurnAround, isTrue);
      expect(r.plan!.route.id, 'east_to_mbh',
          reason: 'progress should track the leg it is actually driving');
      expect(r.plan!.travelRoute.id, 'mbh_to_east',
          reason: 'the leg you will ride is the outbound one');
    });

    test('ETA to board includes the wait at MBH, not just the drive there', () {
      final inbound = at('bus1', 11.318282, 75.935702,
          routeId: 'east_to_mbh',
          originId: 'east_campus',
          destinationId: 'mbh');
      // Pinned clock: 12:41, so bus1's next MBH departure is 13:00.
      final r = tracker.planTrip('mbh', 'east_campus', {'bus1': inbound},
          now: DateTime(2026, 1, 5, 12, 41));
      expect(r.plan, isNotNull);
      // ~19 minutes: the drive to MBH is short, the wait dominates.
      expect(r.plan!.etaToBoardingSec, greaterThan(600));
      expect(r.plan!.etaToBoardingSec, lessThanOrEqualTo(1140));
      expect(r.plan!.scheduledDeparture, '13:00');
    });

    test('offers a bus parked at MBH', () {
      final parked = at('bus1', 11.317194, 75.937560,
          speed: 0,
          routeId: 'mbh_to_east',
          journeyState: 'parked',
          originId: 'east_campus',
          destinationId: 'mbh');
      final r = tracker.planTrip('mbh', 'east_campus', {'bus1': parked});
      expect(r.plan, isNotNull);
      expect(r.plan!.waitingAtTerminal, isTrue);
    });

    test('does NOT offer a bus that has already left MBH', () {
      // Near East Campus on the outbound leg — long past MBH.
      final gone = at('bus1', 11.322871, 75.936436,
          routeId: 'mbh_to_east',
          originId: 'mbh',
          destinationId: 'east_campus');
      final r = tracker.planTrip('mbh', 'east_campus', {'bus1': gone});
      expect(r.plan, isNull,
          reason: 'you cannot board a bus that already passed your stop');
    });

    test('prefers the sooner bus when several are coming', () {
      // bus1 just left East Campus (far); bus2 nearly back at MBH (near).
      final far = at('bus1', 11.322871, 75.936436,
          routeId: 'east_to_mbh',
          originId: 'east_campus',
          destinationId: 'mbh');
      final near = at('bus2', 11.316997, 75.937475,
          routeId: 'east_to_mbh',
          originId: 'east_campus',
          destinationId: 'mbh');

      // Pinned clock 12:44: bus2 arrives ~12:44 and departs 12:50; bus1
      // arrives ~12:46 but its next departure is 13:00. Schedules, not just
      // distance, decide "sooner" — and here they agree with distance.
      final r = tracker.planTrip('mbh', 'east_campus',
          {'bus1': far, 'bus2': near}, now: DateTime(2026, 1, 5, 12, 44));
      expect(r.plan, isNotNull);
      expect(r.plan!.bus.id, 'bus2', reason: 'bus2 departs MBH first (12:50)');
    });
  });

  group('MBH -> Architecture: East Campus bus vs AC bus', () {
    // Both serve Architecture from MBH, so the one departing soonest must win.
    // Previously the AC bus was always chosen, for two reasons fixed here.

    test('a bus still rolling into MBH counts its turnaround wait', () {
      // 24 m short of MBH, still moving. It cannot pick you up in 4 seconds —
      // it has to stop and wait for its departure slot first.
      final rolling = at('bus1', 11.316997, 75.937475,
          speed: 6, routeId: 'east_to_mbh',
          originId: 'east_campus', destinationId: 'mbh');

      final r = tracker.planTrip('mbh', 'architecture', {'bus1': rolling},
          now: DateTime(2026, 1, 5, 16, 38));

      expect(r.plan, isNotNull);
      expect(r.plan!.arrivingToTurnAround, isTrue,
          reason: 'inside the terminal radius but still moving = turning around');
      expect(r.plan!.etaToBoardingSec, greaterThan(60),
          reason: 'must include the wait before departure, not just the drive');
    });

    test('picks the East Campus bus when it departs before the AC bus', () {
      final bus1 = at('bus1', 11.316997, 75.937475,
          routeId: 'east_to_mbh', originId: 'east_campus', destinationId: 'mbh');
      final ac = at('ac_mbh', 11.317194, 75.937560,
          speed: 0, routeId: 'ac_arch_to_mbh', journeyState: 'parked',
          originId: 'architecture', destinationId: 'mbh');

      // 16:38 — bus1's next MBH departure is 16:50, the AC bus's is 16:55.
      final r = tracker.planTrip('mbh', 'architecture',
          {'bus1': bus1, 'ac_mbh': ac}, now: DateTime(2026, 1, 5, 16, 38));

      expect(r.plan!.bus.id, 'bus1',
          reason: 'the East Campus bus leaves first, so it is the one to catch');
    });

    test('a bus finished for the day never beats one still running', () {
      // 17:05: the AC bus has no departures left (last is 16:55) but bus1 does.
      final acDone = at('ac_mbh', 11.317194, 75.937560,
          speed: 0, routeId: 'ac_arch_to_mbh', journeyState: 'parked',
          originId: 'architecture', destinationId: 'mbh');
      // bus1 is much further away — mid-route, not near MBH at all.
      final bus1Far = at('bus1', 11.322871, 75.936436,
          routeId: 'east_to_mbh', originId: 'east_campus', destinationId: 'mbh');

      final r = tracker.planTrip('mbh', 'architecture',
          {'bus1': bus1Far, 'ac_mbh': acDone}, now: DateTime(2026, 1, 5, 17, 5));

      expect(r.plan!.bus.id, 'bus1',
          reason: 'a parked-but-finished AC bus must not out-rank a running bus');
      expect(r.plan!.finishedForToday, isFalse);
    });

    test('a finished bus is still offered when it is the only option', () {
      final acDone = at('ac_mbh', 11.317194, 75.937560,
          speed: 0, routeId: 'ac_arch_to_mbh', journeyState: 'parked',
          originId: 'architecture', destinationId: 'mbh');
      final r = tracker.planTrip('mbh', 'architecture', {'ac_mbh': acDone},
          now: DateTime(2026, 1, 5, 23, 30));
      expect(r.plan, isNotNull, reason: 'better than showing nothing at all');
      expect(r.plan!.finishedForToday, isTrue);
      expect(r.plan!.scheduledDeparture, isNull);
    });

    test('the AC bus still wins when it genuinely leaves first', () {
      // 12:30 — AC departs 12:35; bus1's next MBH departure is 12:40.
      final bus1 = at('bus1', 11.317194, 75.937560,
          speed: 0, routeId: 'east_to_mbh', journeyState: 'parked',
          originId: 'east_campus', destinationId: 'mbh');
      final ac = at('ac_mbh', 11.317194, 75.937560,
          speed: 0, routeId: 'ac_arch_to_mbh', journeyState: 'parked',
          originId: 'architecture', destinationId: 'mbh');

      final r = tracker.planTrip('mbh', 'architecture',
          {'bus1': bus1, 'ac_mbh': ac}, now: DateTime(2026, 1, 5, 12, 30));
      expect(r.plan!.bus.id, 'ac_mbh',
          reason: 'the fix must not invert the bias, only remove it');
    });
  });

  group('General planner behaviour', () {
    test('a stale bus is never offered', () {
      final stale = BusPosition(
        busId: 'bus1',
        lat: 11.318282,
        lng: 75.935702,
        speed: 6,
        routeId: 'east_to_mbh',
        originId: 'east_campus',
        destinationId: 'mbh',
        updatedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 20)),
      );
      final r = tracker.planTrip('mbh', 'east_campus', {'bus1': stale});
      expect(r.plan, isNull);
      expect(stale.isStale, isTrue);
    });

    test('same boarding and destination is rejected', () {
      final r = tracker.planTrip('mbh', 'mbh', {});
      expect(r.plan, isNull);
      expect(r.message, contains('same stop'));
    });

    test('no buses at all yields no plan but a sensible message', () {
      final r = tracker.planTrip('mbh', 'east_campus', {});
      expect(r.plan, isNull);
      expect(r.message, isNotEmpty);
    });

    test('mid-route boarding still works (ATM Circle towards East)', () {
      // bus1 outbound, before ATM Circle.
      final b = at('bus1', 11.318946, 75.934493,
          routeId: 'mbh_to_east',
          originId: 'mbh',
          destinationId: 'east_campus');
      final r = tracker.planTrip('atm_circle', 'east_campus', {'bus1': b});
      expect(r.plan, isNotNull);
      expect(r.plan!.arrivingToTurnAround, isFalse,
          reason: 'ATM Circle is a through stop, not a turnaround');
    });
  });
}
