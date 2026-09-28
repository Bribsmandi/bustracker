import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tracker/app_data.dart';
import 'package:tracker/geo.dart';
import 'package:tracker/models.dart';
import 'package:tracker/simulator.dart';

/// The speed control must actually change how fast buses move, and must not
/// change anything else — same routes, same buses, same road.

void main() {
  late AppData data;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    data = await AppData.load();
  });

  /// Run the simulator for [seconds] at [speed] and report the ground distance
  /// each bus covered.
  ///
  /// This accumulates distance between consecutive samples rather than
  /// measuring start-to-end displacement: at high speed a bus can finish a leg,
  /// turn around and come back, ending up near where it started despite having
  /// driven a long way.
  Map<String, double> runFor(double speed, int seconds) {
    final travelled = <String, double>{};
    final previous = <String, BusPosition>{};
    fakeAsync((async) {
      final sim = BusSimulator(data)..speed = speed;
      sim.start((positions) {
        for (final e in positions.entries) {
          final prev = previous[e.key];
          if (prev != null) {
            travelled[e.key] = (travelled[e.key] ?? 0) +
                haversineMeters(prev.pos, e.value.pos);
          } else {
            travelled[e.key] = 0;
          }
          previous[e.key] = e.value;
        }
      });
      async.elapse(Duration(seconds: seconds));
      sim.stop();
    });
    return travelled;
  }

  test('all six buses are simulated', () {
    final moved = runFor(1, 10);
    expect(moved.length, data.buses.length,
        reason: 'every bus in buses.json should appear');
    expect(moved.length, 6);
  });

  test('10x moves buses substantially further than 1x in the same wall time',
      () {
    final slow = runFor(1, 20);
    final fast = runFor(10, 20);

    for (final id in slow.keys) {
      // Not exactly 10x: buses pause at terminals, and dwell scales too.
      // But each must clearly cover much more ground.
      expect(fast[id]!, greaterThan(slow[id]! * 3),
          reason: '$id barely moved faster at 10x '
              '(1x: ${slow[id]!.toStringAsFixed(0)} m, '
              '10x: ${fast[id]!.toStringAsFixed(0)} m)');
    }
  });

  test('buses still move at 1x — the baseline is not stalled', () {
    final moved = runFor(1, 20);
    // ~6 m/s for 20 s is ~120 m of road covered; allow slack for parked buses.
    expect(moved.values.where((m) => m > 30).length, greaterThan(3),
        reason: 'most buses should be driving, not all parked');
  });

  test('changing speed mid-run takes effect immediately', () {
    final samples = <BusPosition>[];
    fakeAsync((async) {
      final sim = BusSimulator(data)..speed = 1;
      sim.start((p) {
        final b = p['bus1'];
        if (b != null) samples.add(b);
      });
      async.elapse(const Duration(seconds: 10));
      final beforeCount = samples.length;
      sim.speed = 20;
      async.elapse(const Duration(seconds: 10));
      sim.stop();
      expect(samples.length, greaterThan(beforeCount));
    });

    // Distance covered in the second half must exceed the first half.
    final mid = samples.length ~/ 2;
    var firstHalf = 0.0, secondHalf = 0.0;
    for (var i = 1; i < mid; i++) {
      firstHalf += haversineMeters(samples[i - 1].pos, samples[i].pos);
    }
    for (var i = mid + 1; i < samples.length; i++) {
      secondHalf += haversineMeters(samples[i - 1].pos, samples[i].pos);
    }
    expect(secondHalf, greaterThan(firstHalf * 2),
        reason: 'speeding up mid-run should visibly accelerate the bus');
  });

  test('speed does not change which routes buses run', () {
    final routesAt1 = <String, String>{};
    final routesAt10 = <String, String>{};
    fakeAsync((async) {
      final sim = BusSimulator(data)..speed = 1;
      sim.start((p) {
        for (final e in p.entries) {
          routesAt1.putIfAbsent(e.key, () => e.value.routeId ?? '');
        }
      });
      async.elapse(const Duration(seconds: 2));
      sim.stop();
    });
    fakeAsync((async) {
      final sim = BusSimulator(data)..speed = 10;
      sim.start((p) {
        for (final e in p.entries) {
          routesAt10.putIfAbsent(e.key, () => e.value.routeId ?? '');
        }
      });
      async.elapse(const Duration(seconds: 2));
      sim.stop();
    });
    expect(routesAt10, routesAt1,
        reason: 'the speed control must only change pace, nothing else');
  });

  test('offered speed steps are sane', () {
    expect(BusSimulator.speedSteps.first, 1);
    expect(BusSimulator.speedSteps, isNotEmpty);
    for (final s in BusSimulator.speedSteps) {
      expect(s, greaterThan(0));
    }
  });
}
