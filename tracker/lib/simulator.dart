import 'dart:async';

import 'app_data.dart';
import 'models.dart';

/// Drives all six buses around their routes locally, so the map, markers,
/// progress bar and ETAs can be exercised without any bus, phone or backend.
///
/// This is a development aid. It never talks to Supabase and never writes
/// anything; it just produces the same [BusPosition] objects the realtime
/// stream would, so everything downstream is the real code path.
class BusSimulator {
  BusSimulator(this.data);

  final AppData data;
  Timer? _timer;
  final List<_SimBus> _buses = [];

  /// How often the simulation steps. Faster than the real 5 s publish interval
  /// so the markers glide instead of hopping.
  static const Duration tick = Duration(milliseconds: 500);

  /// Seconds a simulated bus waits at a terminal before turning around.
  static const double dwellSeconds = 12;

  /// Speeds offered in the UI. 1x is roughly real bus pace, so a full MBH to
  /// East Campus leg takes about 3.5 minutes; 20x gets you a round trip,
  /// including the turnaround, in well under a minute.
  static const List<double> speedSteps = [1, 2, 5, 10, 20];

  /// Time multiplier. Scales distance covered and the terminal wait together,
  /// so the rhythm of the route stays the same, just faster.
  double speed = 1.0;

  bool get isRunning => _timer != null;

  /// Start simulating. [onUpdate] receives the full position map each tick,
  /// exactly like the Supabase stream would deliver it.
  void start(void Function(Map<String, BusPosition>) onUpdate) {
    stop();
    _buses
      ..clear()
      ..addAll(_seed());
    _timer = Timer.periodic(tick, (_) {
      final dt = tick.inMilliseconds / 1000.0 * speed;
      final out = <String, BusPosition>{};
      for (final b in _buses) {
        b.step(dt, data);
        final p = b.toPosition(data, speed);
        if (p != null) out[b.busId] = p;
      }
      onUpdate(out);
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Put each bus on one of its own routes, spread out so they are not all
  /// nose to tail, and at slightly different speeds so they drift apart.
  List<_SimBus> _seed() {
    final result = <_SimBus>[];
    var i = 0;
    for (final bus in data.buses.values) {
      final routes = data.routesForBus(bus.id)
          .where((r) => (data.geometry[r.id]?.isUsable ?? false))
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      if (routes.isEmpty) continue;

      // Alternate direction so some buses are outbound and some returning.
      final route = routes[i % routes.length];
      final len = data.geometry[route.id]!.totalLength;

      result.add(_SimBus(
        busId: bus.id,
        routeId: route.id,
        // Spread them along the route: 0%, 17%, 34%, ...
        along: len * ((i * 0.17) % 0.9),
        speedMps: 5.0 + (i % 3), // 5-7 m/s, ~18-25 km/h
      ));
      i++;
    }
    return result;
  }
}

class _SimBus {
  _SimBus({
    required this.busId,
    required this.routeId,
    required this.along,
    required this.speedMps,
  });

  final String busId;
  String routeId;
  double along;
  double speedMps;

  /// Seconds left waiting at a terminal; 0 means driving.
  double dwellLeft = 0;

  bool get parked => dwellLeft > 0;

  void step(double dt, AppData data) {
    final geom = data.geometry[routeId];
    if (geom == null || !geom.isUsable) return;

    if (parked) {
      dwellLeft -= dt;
      if (dwellLeft <= 0) {
        dwellLeft = 0;
        _turnAround(data);
      }
      return;
    }

    along += speedMps * dt;
    if (along >= geom.totalLength) {
      along = geom.totalLength;
      dwellLeft = BusSimulator.dwellSeconds;
    }
  }

  /// Switch to the route that runs back the other way, mirroring what the
  /// publisher's journey state machine does when a bus pulls out of a terminal.
  void _turnAround(AppData data) {
    final current = data.routes[routeId];
    if (current == null) return;
    for (final r in data.routesForBus(busId)) {
      if (r.origin == current.destination &&
          r.destination == current.origin &&
          (data.geometry[r.id]?.isUsable ?? false)) {
        routeId = r.id;
        along = 0;
        return;
      }
    }
    // No return route defined — just run the same one again.
    along = 0;
  }

  /// [timeScale] is the simulation speed multiplier. The reported speed is the
  /// effective ground speed, so ETAs computed from it match what you watch on
  /// screen at 10x rather than being 10x too long.
  BusPosition? toPosition(AppData data, double timeScale) {
    final geom = data.geometry[routeId];
    final route = data.routes[routeId];
    if (geom == null || route == null || !geom.isUsable) return null;
    final at = geom.positionAt(along);
    return BusPosition(
      busId: busId,
      lat: at.point.latitude,
      lng: at.point.longitude,
      speed: parked ? 0 : speedMps * timeScale,
      heading: at.bearing,
      simulated: true,
      routeId: routeId,
      originId: route.origin,
      destinationId: route.destination,
      journeyState: parked ? 'parked' : 'outbound',
      // Always fresh: the staleness rule is real code and would grey these out.
      updatedAt: DateTime.now().toUtc(),
    );
  }
}
