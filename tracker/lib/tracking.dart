import 'config.dart';
import 'app_data.dart';
import 'geo.dart';
import 'models.dart';

/// A bus as shown on the map: its live position plus the route it appears to be
/// travelling on, so the marker can point the right way.
class BusOnMap {
  final BusDef def;
  final BusPosition position;
  final RouteDef? route; // inferred current route
  final RouteProjection? projection;
  final double bearing; // marker rotation in degrees

  BusOnMap({
    required this.def,
    required this.position,
    this.route,
    this.projection,
    required this.bearing,
  });

  bool get stale => position.isStale;
}

/// The plan for a selected boarding -> destination trip.
class TripPlan {
  final BusDef bus;
  final BusPosition position;

  /// The leg the bus is running right now — what the map draws and what the
  /// progress bar measures. Not necessarily the leg you will ride.
  final RouteDef route;

  /// The leg that actually carries you from boarding to destination.
  final RouteDef travelRoute;

  /// 0..1 — how far along the (origin -> boarding) leg the incoming bus is.
  final double progressToBoarding;

  /// Estimated seconds until the bus reaches the boarding point.
  final int etaToBoardingSec;

  /// True when the bus is currently waiting at your boarding point.
  final bool waitingAtTerminal;

  /// True when the bus is inbound to your stop and will turn around there.
  final bool arrivingToTurnAround;

  /// True when this bus has no scheduled departure left today for your trip.
  /// Such a bus is only offered when nothing better exists.
  final bool finishedForToday;

  /// Non-null when the bus must first drive to this stop (the far terminus of
  /// its current leg) and turn around before it can come back and pick you up.
  final String? viaStopId;

  /// Scheduled departure "HH:MM" used, when the bus is waiting at a terminal.
  final String? scheduledDeparture;

  /// Rough seconds for the ride from boarding to destination.
  final int rideSec;

  /// How far along the route polyline the bus currently is, in metres. Used to
  /// draw the covered portion of the route on the map.
  final double busDistanceAlong;

  /// Ordered stops of the incoming leg (origin..boarding) for the progress bar.
  final List<Stop> legStops;

  /// Fractional position (0..1) of each leg stop along the origin..boarding leg.
  final List<double> legStopFractions;

  TripPlan({
    required this.bus,
    required this.position,
    required this.route,
    required this.travelRoute,
    required this.progressToBoarding,
    required this.etaToBoardingSec,
    required this.waitingAtTerminal,
    required this.arrivingToTurnAround,
    required this.finishedForToday,
    this.viaStopId,
    required this.scheduledDeparture,
    required this.rideSec,
    required this.busDistanceAlong,
    required this.legStops,
    required this.legStopFractions,
  });
}

/// The four ways a bus can end up picking you up.
enum ApproachKind {
  /// Driving towards your stop on the leg that carries you to your destination.
  direct,

  /// Standing at your stop, waiting for its departure time.
  parked,

  /// Inbound to your stop as its terminus; it will turn around there.
  turnaround,

  /// On the wrong-direction leg: it must finish that leg, turn around at the
  /// far terminus, and come back to your stop before you can board.
  viaTerminus,
}

/// How one bus will get to your boarding point.
class _Approach {
  final ApproachKind kind;
  final RouteDef route; // the leg the bus is running right now
  final RouteDef travelRoute; // the leg that will actually carry the rider
  final RouteGeometry geom; // geometry of [route]
  final double distanceAlong; // where the bus is on [route]
  final double targetAlong; // bar target on [route]: your stop, or the terminus
  final int driveSec; // to your stop (direct/turnaround) or to the terminus
  final double fromTerminusM; // viaTerminus only: terminus -> your stop

  _Approach({
    required this.kind,
    required this.route,
    required this.travelRoute,
    required this.geom,
    required this.distanceAlong,
    required this.targetAlong,
    required this.driveSec,
    this.fromTerminusM = 0,
  });
}

class PlanResult {
  final TripPlan? plan;
  final String message;
  PlanResult(this.plan, this.message);
}

/// One scheduled departure that serves a selected boarding -> destination pair.
class UpcomingDeparture {
  final String time; // "HH:MM"
  final int minutesOfDay;
  final BusDef bus;
  final String originId; // terminal the printed time refers to
  final String routeId;

  UpcomingDeparture({
    required this.time,
    required this.minutesOfDay,
    required this.bus,
    required this.originId,
    required this.routeId,
  });
}

/// All the trip-planning / ETA maths.
class Tracker {
  final AppData data;
  Tracker(this.data);

  // ---- Marker orientation for every live bus -------------------------------

  List<BusOnMap> busesOnMap(Map<String, BusPosition> live) {
    final result = <BusOnMap>[];
    for (final entry in live.entries) {
      final def = data.buses[entry.key];
      if (def == null) continue;
      final pos = entry.value;
      final inferred = _inferRoute(def, pos);
      double bearing;
      if (inferred != null) {
        bearing = inferred.projection.routeBearing;
      } else if (pos.heading != null && pos.heading! >= 0) {
        bearing = pos.heading!;
      } else {
        bearing = 0;
      }
      result.add(BusOnMap(
        def: def,
        position: pos,
        route: inferred?.route,
        projection: inferred?.projection,
        bearing: bearing,
      ));
    }
    return result;
  }

  ({RouteDef route, RouteProjection projection})? _inferRoute(
      BusDef def, BusPosition pos) {
    // If the publisher told us the route explicitly, trust it.
    if (pos.routeId != null) {
      final r = data.routes[pos.routeId];
      final g = data.geometry[pos.routeId];
      if (r != null && g != null && g.isUsable) {
        return (route: r, projection: g.project(pos.pos));
      }
    }

    ({RouteDef route, RouteProjection projection})? best;
    double bestScore = double.infinity;
    for (final route in data.routesForBus(def.id)) {
      final geom = data.geometry[route.id];
      if (geom == null || !geom.isUsable) continue;
      final proj = geom.project(pos.pos);
      // Opposite-direction routes overlap on the road, so distance alone can't
      // separate them — use GPS heading vs the route's travel direction.
      var score = proj.offRouteMeters;
      if (pos.heading != null && pos.heading! >= 0) {
        score += bearingDiff(pos.heading!, proj.routeBearing) * 2.0;
      }
      if (score < bestScore) {
        bestScore = score;
        best = (route: route, projection: proj);
      }
    }
    return best;
  }

  // ---- Distance of a stop along a route ------------------------------------

  /// Distance (m) along [route]'s polyline at [stopId], or null if the stop
  /// isn't on the route or has no coordinates.
  ///
  /// Pre-computed by snapping each stop onto the path, so this stays correct
  /// for surveyed routes where the polyline has many more points than stops.
  double? _stopDistanceAlong(RouteDef route, RouteGeometry geom, String stopId) {
    if (!route.stops.contains(stopId)) return null;
    return geom.stopAlong[stopId];
  }

  // ---- Schedule ------------------------------------------------------------

  /// Next scheduled departure at/after [nowMinutes] for this bus+route.
  Departure? _nextDeparture(String busId, String routeId, int nowMinutes) {
    final entry = data.scheduleFor(busId, routeId);
    if (entry == null || entry.departures.isEmpty) return null;
    Departure? next;
    for (final d in entry.departures) {
      if (d.minutesOfDay >= nowMinutes) {
        if (next == null || d.minutesOfDay < next.minutesOfDay) next = d;
      }
    }
    return next; // null if the service day is over
  }

  /// Every remaining scheduled departure today that serves a trip from
  /// [boardingId] to [destId], sorted by time.
  ///
  /// The printed timetable lists departures from route ORIGINS (terminals), so
  /// each entry carries its origin: for a mid-route boarding point the time is
  /// "leaves the origin terminal at", not "reaches you at" — the UI labels it.
  List<UpcomingDeparture> upcomingDepartures(
    String boardingId,
    String destId, {
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final nowMinutes = clock.hour * 60 + clock.minute;

    final out = <UpcomingDeparture>[];
    for (final route in data.routes.values) {
      final bi = route.stops.indexOf(boardingId);
      final di = route.stops.indexOf(destId);
      if (bi == -1 || di == -1 || bi >= di) continue;

      for (final entry in data.schedules) {
        if (entry.routeId != route.id) continue;
        final bus = data.buses[entry.busId];
        if (bus == null) continue;
        for (final d in entry.departures) {
          if (d.minutesOfDay < nowMinutes) continue;
          out.add(UpcomingDeparture(
            time: d.time,
            minutesOfDay: d.minutesOfDay,
            bus: bus,
            originId: route.origin,
            routeId: route.id,
          ));
        }
      }
    }
    out.sort((a, b) => a.minutesOfDay.compareTo(b.minutesOfDay));
    return out;
  }

  // ---- Trip planning -------------------------------------------------------

  PlanResult planTrip(
    String boardingId,
    String destId,
    Map<String, BusPosition> live, {
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final nowMinutes = clock.hour * 60 + clock.minute;

    if (boardingId == destId) {
      return PlanResult(null, 'Boarding and destination are the same stop.');
    }

    // Routes that visit boarding then destination, in that order.
    final candidateRoutes = data.routes.values.where((r) {
      final bi = r.stops.indexOf(boardingId);
      final di = r.stops.indexOf(destId);
      return bi != -1 && di != -1 && bi < di;
    }).toList();

    if (candidateRoutes.isEmpty) {
      return PlanResult(
          null, 'No bus route goes from there to your destination.');
    }

    TripPlan? bestPlan;
    var sawLiveBus = false;
    var missingCoords = false;

    // Which buses could take you from boarding to destination at all?
    final servingBuses = <String, RouteDef>{};
    for (final route in candidateRoutes) {
      final geom = data.geometry[route.id];
      if (geom == null || !geom.isUsable) {
        missingCoords = true;
        continue;
      }
      if (_stopDistanceAlong(route, geom, boardingId) == null ||
          _stopDistanceAlong(route, geom, destId) == null) {
        missingCoords = true;
        continue;
      }
      for (final busId in route.buses) {
        servingBuses.putIfAbsent(busId, () => route);
      }
    }

    // Now look at where each of those buses actually is. The question is not
    // "is it already on the route I want" — a bus on its way back to MBH is the
    // one you will board at MBH next — but "when can it pick me up".
    for (final entry in servingBuses.entries) {
      final busId = entry.key;
      final travelRoute = entry.value;
      final pos = live[busId];
      final def = data.buses[busId];
      if (pos == null || def == null || pos.isStale) continue;

      final approach =
          _approachToBoarding(def, pos, boardingId, destId, travelRoute);
      if (approach == null) continue; // this bus is not coming to your stop
      sawLiveBus = true;

      // The leg the rider will actually sit on. For a direct approach this is
      // the bus's current leg (which may differ from the pre-assigned
      // travelRoute when a bus serves several overlapping routes).
      final effTravel = approach.travelRoute;
      final travelGeom = data.geometry[effTravel.id]!;
      final boardAlongTravel =
          _stopDistanceAlong(effTravel, travelGeom, boardingId)!;
      final destAlong = _stopDistanceAlong(effTravel, travelGeom, destId)!;

      // Time until the bus is standing at your stop, ready to board.
      int etaSec;
      String? schedTime;
      // True when the bus must depart from a terminal but has no departure
      // left on the timetable today — it has finished this route for the day.
      var finishedForToday = false;

      switch (approach.kind) {
        case ApproachKind.direct:
          etaSec = approach.driveSec;

        case ApproachKind.parked:
        case ApproachKind.turnaround:
          if (pos.simulated) {
            // Simulated buses ignore the timetable — their dwell is seconds,
            // not a scheduled slot. Rank them purely by approach time, or the
            // wall-clock schedule picks the wrong fake bus (and after the last
            // scheduled run of the day, hides it entirely).
            etaSec = approach.driveSec;
          } else {
            final arrivalMinutes = nowMinutes + (approach.driveSec ~/ 60);
            final dep = _nextDeparture(busId, effTravel.id, arrivalMinutes);
            schedTime = dep?.time;
            if (dep != null) {
              etaSec = (dep.minutesOfDay - nowMinutes) * 60;
              if (etaSec < approach.driveSec) etaSec = approach.driveSec;
            } else {
              // No fabricated short wait: a bus with no departures left would
              // otherwise advertise a few minutes and beat a bus that is
              // genuinely coming. Kept only as a last resort (see ranking).
              finishedForToday = true;
              etaSec = approach.driveSec + Config.terminalDwellSec;
            }
          }

        case ApproachKind.viaTerminus:
          // It must reach the far terminus, wait for its departure slot, then
          // drive back to you. Saying "arriving" when it rolls past your stop
          // in the wrong direction is exactly the bug this case fixes.
          final backSec = (approach.fromTerminusM / Config.avgSpeedMps).round();
          if (pos.simulated) {
            etaSec = approach.driveSec + backSec;
          } else {
            final arrivalMinutes = nowMinutes + (approach.driveSec ~/ 60);
            final dep = _nextDeparture(busId, effTravel.id, arrivalMinutes);
            schedTime = dep?.time;
            if (dep != null) {
              var leaveSec = (dep.minutesOfDay - nowMinutes) * 60;
              if (leaveSec < approach.driveSec) leaveSec = approach.driveSec;
              etaSec = leaveSec + backSec;
            } else {
              finishedForToday = true;
              etaSec = approach.driveSec + Config.terminalDwellSec + backSec;
            }
          }
      }

      // Rank: a bus that will actually run today always beats one that will
      // not, regardless of how close the finished one happens to be parked.
      if (bestPlan != null) {
        final betterClass = !finishedForToday && bestPlan.finishedForToday;
        final worseClass = finishedForToday && !bestPlan.finishedForToday;
        if (worseClass) continue;
        if (!betterClass && etaSec >= bestPlan.etaToBoardingSec) continue;
      }

      final progress = approach.targetAlong <= 0
          ? 1.0
          : (approach.distanceAlong / approach.targetAlong);

      // For a via-terminus bus the progress bar shows its journey to the far
      // terminus (that is the leg it is visibly driving); the subtitle then
      // explains the turnaround. Pretending it was progress towards you would
      // repeat the "arrived but hasn't" lie in bar form.
      final barTargetStop = approach.kind == ApproachKind.viaTerminus
          ? approach.route.destination
          : boardingId;

      bestPlan = TripPlan(
        bus: def,
        position: pos,
        route: approach.route,
        travelRoute: effTravel,
        progressToBoarding: progress.clamp(0.0, 1.0),
        etaToBoardingSec: etaSec,
        waitingAtTerminal: approach.kind == ApproachKind.parked,
        arrivingToTurnAround: approach.kind == ApproachKind.turnaround,
        viaStopId: approach.kind == ApproachKind.viaTerminus
            ? approach.route.destination
            : null,
        finishedForToday: finishedForToday,
        scheduledDeparture: schedTime,
        rideSec: ((destAlong - boardAlongTravel) / Config.avgSpeedMps).round(),
        busDistanceAlong: approach.distanceAlong,
        legStops: _legStops(approach.route, barTargetStop),
        legStopFractions: _legStopFractions(
            approach.route, approach.geom, barTargetStop, approach.targetAlong),
      );
    }

    if (bestPlan != null) return PlanResult(bestPlan, 'On the way');
    if (missingCoords && !sawLiveBus) {
      return PlanResult(null,
          'Add stop coordinates in stops.json to enable live tracking here.');
    }
    return PlanResult(null, 'No bus is currently heading to this stop.');
  }

  /// How a given bus will reach [boardingId] for a trip towards [destId],
  /// if it will at all.
  ///
  /// Four ways a bus can pick you up, and the planner must consider all of
  /// them or it will either miss the right bus or lie about the wrong one:
  ///   1. parked at your stop, waiting for its departure time;
  ///   2. driving towards your stop on a leg that carries you to [destId];
  ///   3. inbound to your stop as its terminus — it turns around there;
  ///   4. passing your stop on the WRONG-direction leg — it must go to the far
  ///      terminus, turn around, and come back before you can board. Without
  ///      this case a bus rolling past Architecture towards East Campus reads
  ///      as "arriving" for a Architecture -> MBH trip, which is a lie.
  _Approach? _approachToBoarding(BusDef def, BusPosition pos, String boardingId,
      String destId, RouteDef fallbackTravel) {
    final inferred = _inferRoute(def, pos);
    if (inferred == null) return null;

    final route = inferred.route;
    final geom = data.geometry[route.id];
    if (geom == null || !geom.isUsable) return null;
    final proj = inferred.projection;
    final speed = pos.isMoving ? pos.speed! : Config.avgSpeedMps;

    final boardingStop = data.stops[boardingId];
    final atBoarding = boardingStop?.pos != null &&
        haversineMeters(pos.pos, boardingStop!.pos!) < Config.atTerminalRadiusM;

    // 1. Standing at your stop. Only trust "not moving" as parked when the
    // stop is a leg endpoint — a bus idling in traffic at a through-stop is
    // just a slow direct approach, not a terminal wait.
    final isLegEndHere =
        route.origin == boardingId || route.destination == boardingId;
    if (atBoarding && (pos.isParked || (!pos.isMoving && isLegEndHere))) {
      return _Approach(
        kind: ApproachKind.parked,
        route: route,
        travelRoute: fallbackTravel,
        geom: geom,
        distanceAlong: proj.distanceAlong,
        targetAlong:
            _stopDistanceAlong(route, geom, boardingId) ?? proj.distanceAlong,
        driveSec: 0,
      );
    }

    // 2. Its current leg carries you boarding -> destination, in that order.
    final bi = route.stops.indexOf(boardingId);
    final di = route.stops.indexOf(destId);
    if (bi != -1 && di != -1 && bi < di) {
      final along = _stopDistanceAlong(route, geom, boardingId);
      if (along != null) {
        final remaining = along - proj.distanceAlong;
        if (remaining < -Config.atTerminalRadiusM) {
          // Passed you on the leg you wanted: catching it again would take two
          // turnarounds. The bus behind it is always sooner — don't offer it.
          return null;
        }
        final rem = remaining < 0 ? 0.0 : remaining;
        return _Approach(
          kind: ApproachKind.direct,
          route: route,
          // The current leg IS the ride — even if the pre-assigned travel
          // route was a different one serving the same pair of stops.
          travelRoute: route,
          geom: geom,
          distanceAlong: proj.distanceAlong,
          targetAlong: along,
          driveSec: (rem / speed).round(),
        );
      }
    }

    final toTerminusM =
        (geom.totalLength - proj.distanceAlong).clamp(0.0, double.infinity);

    // 3. Your stop is this leg's terminus: it arrives, waits, sets off again.
    if (route.destination == boardingId) {
      return _Approach(
        kind: ApproachKind.turnaround,
        route: route,
        travelRoute: fallbackTravel,
        geom: geom,
        distanceAlong: proj.distanceAlong,
        targetAlong: geom.totalLength,
        driveSec: (toTerminusM / speed).round(),
      );
    }

    // 4. Wrong direction. It only helps you if, after turning around at its
    // terminus, the leg it comes back on is the one that serves your trip.
    if (fallbackTravel.origin == route.destination) {
      final tGeom = data.geometry[fallbackTravel.id];
      final backM = tGeom == null
          ? null
          : _stopDistanceAlong(fallbackTravel, tGeom, boardingId);
      if (backM != null) {
        return _Approach(
          kind: ApproachKind.viaTerminus,
          route: route,
          travelRoute: fallbackTravel,
          geom: geom,
          distanceAlong: proj.distanceAlong,
          targetAlong: geom.totalLength,
          driveSec: (toTerminusM / speed).round(),
          fromTerminusM: backM,
        );
      }
    }
    return null;
  }

  List<Stop> _legStops(RouteDef route, String boardingId) {
    final result = <Stop>[];
    for (final sid in route.stops) {
      final s = data.stops[sid];
      if (s != null) result.add(s);
      if (sid == boardingId) break;
    }
    return result;
  }

  List<double> _legStopFractions(
      RouteDef route, RouteGeometry geom, String boardingId, double boardingAlong) {
    final fractions = <double>[];
    for (final sid in route.stops) {
      final along = _stopDistanceAlong(route, geom, sid);
      if (along != null) {
        fractions.add(boardingAlong <= 0 ? 0.0 : (along / boardingAlong).clamp(0.0, 1.0));
      } else {
        fractions.add(0.0);
      }
      if (sid == boardingId) break;
    }
    return fractions;
  }
}
