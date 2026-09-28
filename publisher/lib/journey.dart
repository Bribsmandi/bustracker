import 'dart:math' as math;

import 'config.dart';

/// Great-circle distance in metres.
double distMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180.0;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
}

class StopPoint {
  final String id;
  final String name;
  final bool isTerminal;
  final double lat;
  final double lng;

  /// Optional override for when the return journey begins. When set, the bus is
  /// considered to have started the return trip once it comes within
  /// [Config.returnTriggerRadiusM] of this point, instead of using the
  /// "moved N metres from where it parked" rule.
  final double? triggerLat;
  final double? triggerLng;

  StopPoint({
    required this.id,
    required this.name,
    required this.isTerminal,
    required this.lat,
    required this.lng,
    this.triggerLat,
    this.triggerLng,
  });

  bool get hasReturnTrigger => triggerLat != null && triggerLng != null;
}

class RouteOption {
  final String id;
  final String originId;
  final String destinationId;
  RouteOption(this.id, this.originId, this.destinationId);
}

enum JourneyState {
  /// Driving from [origin] towards [destination].
  outbound,

  /// Arrived at [destination] and waiting/parked there.
  parked,
}

/// One GPS sample, kept briefly so we can reason about movement over time
/// rather than trusting a single noisy fix.
class Fix {
  final double lat;
  final double lng;
  final double speed; // m/s
  final DateTime at;
  Fix(this.lat, this.lng, this.speed, this.at);
}

/// Tracks which way round the bus is currently going, and flips the direction
/// automatically once it parks at one end and then pulls away again.
///
/// The driver only ever picks the two endpoints; everything after that is
/// derived from GPS.
class Journey {
  String originId;
  String destinationId;
  JourneyState state;

  /// Where the bus came to rest at the destination. The return trip is detected
  /// as movement away from this anchor, not from the stop's nominal centre,
  /// because buses park in slightly different spots each time.
  double? _parkLat;
  double? _parkLng;

  /// Set once per park so we don't spam direction flips.
  bool _flippedSincePark = false;

  /// Recent fixes, trimmed to just longer than [Config.parkedWindow].
  final List<Fix> _history = [];

  /// How many consecutive fixes have satisfied the "moving" speed test.
  int _movingStreak = 0;

  /// Server id of the trip currently being recorded, if any.
  int? tripId;

  Journey({
    required this.originId,
    required this.destinationId,
    this.state = JourneyState.outbound,
  });

  String get stateLabel {
    switch (state) {
      case JourneyState.outbound:
        return 'En route';
      case JourneyState.parked:
        return 'Parked at $destinationId';
    }
  }

  /// Feed a new GPS fix. Returns true if the direction flipped this update.
  ///
  /// [stops] must contain the origin and destination. [now] is injectable so
  /// the time-window logic can be tested without waiting 30 real seconds.
  bool update(
    double lat,
    double lng,
    Map<String, StopPoint> stops, {
    double speed = 0,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final dest = stops[destinationId];
    if (dest == null) return false;

    _record(lat, lng, speed, clock);

    switch (state) {
      case JourneyState.outbound:
        // Two signals must agree: near the terminal AND genuinely settled.
        final near =
            distMeters(lat, lng, dest.lat, dest.lng) <= Config.arriveRadiusM;
        if (near && _hasSettled(clock)) {
          state = JourneyState.parked;
          _parkLat = lat;
          _parkLng = lng;
          _flippedSincePark = false;
          _movingStreak = 0;
        }
        return false;

      case JourneyState.parked:
        if (_flippedSincePark) return false;
        if (!_hasLeftParking(lat, lng, dest)) return false;

        // Pulling away from the terminal means the return journey has begun:
        // the destination we just reached becomes the new origin.
        final wasOrigin = originId;
        originId = destinationId;
        destinationId = wasOrigin;
        state = JourneyState.outbound;
        _flippedSincePark = true;
        _parkLat = null;
        _parkLng = null;
        _movingStreak = 0;
        return true;
    }
  }

  /// Append a fix and drop anything too old to matter.
  void _record(double lat, double lng, double speed, DateTime at) {
    _history.add(Fix(lat, lng, speed, at));

    // Keep a little more than the settle window so _hasSettled has full cover.
    final cutoff = at.subtract(Config.parkedWindow * 2);
    _history.removeWhere((f) => f.at.isBefore(cutoff));

    _movingStreak =
        speed >= Config.departMinSpeedMps ? _movingStreak + 1 : 0;
  }

  /// Has the bus stayed put for the whole settle window?
  ///
  /// Requires genuine coverage of the window — a bus that has only just come
  /// into range has not yet proved it is stopping rather than passing through.
  bool _hasSettled(DateTime now) {
    final windowStart = now.subtract(Config.parkedWindow);
    final inWindow = _history.where((f) => !f.at.isBefore(windowStart)).toList();
    if (inWindow.length < 2) return false;

    // Only trust the verdict if the samples actually span the window.
    final span = now.difference(inWindow.first.at);
    if (span < Config.parkedWindow) return false;

    for (final f in inWindow) {
      for (final g in inWindow) {
        if (distMeters(f.lat, f.lng, g.lat, g.lng) > Config.parkedMaxDriftM) {
          return false;
        }
      }
    }
    return true;
  }

  /// Has the bus pulled away from where it parked?
  ///
  /// Needs distance AND sustained speed to agree, so neither GPS drift (which
  /// gives distance without speed) nor a single bad speed sample (speed without
  /// distance) can flip the journey on its own.
  ///
  /// A surveyed trigger point, where one exists, is an additional way in — it
  /// answers the "which road" question that motion cannot.
  bool _hasLeftParking(double lat, double lng, StopPoint dest) {
    if (dest.hasReturnTrigger) {
      final d = distMeters(lat, lng, dest.triggerLat!, dest.triggerLng!);
      if (d <= Config.returnTriggerRadiusM) return true;
    }

    final pl = _parkLat, pg = _parkLng;
    if (pl == null || pg == null) return false;

    final farEnough =
        distMeters(lat, lng, pl, pg) > Config.departMinDistanceM;
    final movingEnough = _movingStreak >= Config.departMinConsecutiveFixes;
    return farEnough && movingEnough;
  }

  /// The route whose endpoints match the current direction, if one exists.
  String? routeIdFrom(List<RouteOption> routes) {
    for (final r in routes) {
      if (r.originId == originId && r.destinationId == destinationId) {
        return r.id;
      }
    }
    return null;
  }

  String get wireState =>
      state == JourneyState.parked ? 'parked' : 'outbound';
}
