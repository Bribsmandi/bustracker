import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'config.dart';

/// A campus bus stop. Coordinates are null until filled in stops.json.
class Stop {
  final String id;
  final String name;
  final String fullName;
  final bool isTerminal;
  final double? lat;
  final double? lng;

  Stop({
    required this.id,
    required this.name,
    required this.fullName,
    required this.isTerminal,
    this.lat,
    this.lng,
  });

  bool get hasCoords => lat != null && lng != null;
  LatLng? get pos => hasCoords ? LatLng(lat!, lng!) : null;

  factory Stop.fromJson(Map<String, dynamic> j) => Stop(
        id: j['id'] as String,
        name: j['name'] as String,
        fullName: (j['fullName'] ?? j['name']) as String,
        isTerminal: (j['isTerminal'] ?? false) as bool,
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
      );
}

/// One of the 6 physical buses.
class BusDef {
  final String id;
  final String label;
  final String type; // "regular" | "ac"
  final String homeTerminal;
  final String colorHex;

  BusDef({
    required this.id,
    required this.label,
    required this.type,
    required this.homeTerminal,
    required this.colorHex,
  });

  Color get color {
    var hex = colorHex.replaceFirst('#', '');
    if (hex.length == 6) hex = 'FF$hex';
    return Color(int.parse(hex, radix: 16));
  }

  factory BusDef.fromJson(Map<String, dynamic> j) => BusDef(
        id: j['id'] as String,
        label: j['label'] as String,
        type: (j['type'] ?? 'regular') as String,
        homeTerminal: (j['homeTerminal'] ?? '') as String,
        colorHex: (j['color'] ?? '#3366cc') as String,
      );
}

/// A directed route: an ordered list of stop ids.
class RouteDef {
  final String id;
  final String name;
  final List<String> buses;
  final String origin;
  final String destination;
  final List<String> stops;

  /// The exact road polyline the bus drives, when it has been surveyed.
  /// Empty means "fall back to straight lines between stops".
  final List<LatLng> path;

  RouteDef({
    required this.id,
    required this.name,
    required this.buses,
    required this.origin,
    required this.destination,
    required this.stops,
    this.path = const [],
  });

  factory RouteDef.fromJson(Map<String, dynamic> j) => RouteDef(
        id: j['id'] as String,
        name: j['name'] as String,
        buses: (j['buses'] as List).cast<String>(),
        origin: j['origin'] as String,
        destination: j['destination'] as String,
        stops: (j['stops'] as List).cast<String>(),
        path: (j['path'] as List?)
                ?.map((p) => LatLng(
                      (p[0] as num).toDouble(),
                      (p[1] as num).toDouble(),
                    ))
                .toList() ??
            const [],
      );
}

/// A scheduled departure time from a terminal.
class Departure {
  final String time; // "HH:MM" 24h
  final bool somsVariant;
  Departure(this.time, {this.somsVariant = false});

  /// Minutes since midnight, for easy comparison with "now".
  int get minutesOfDay {
    final parts = time.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }
}

class ScheduleEntry {
  final String busId;
  final String routeId;
  final String origin;
  final List<Departure> departures;

  ScheduleEntry({
    required this.busId,
    required this.routeId,
    required this.origin,
    required this.departures,
  });

  factory ScheduleEntry.fromJson(Map<String, dynamic> j) {
    final deps = (j['departures'] as List).map((d) {
      if (d is String) return Departure(d);
      final m = d as Map<String, dynamic>;
      return Departure(m['time'] as String,
          somsVariant: (m['somsVariant'] ?? false) as bool);
    }).toList();
    return ScheduleEntry(
      busId: j['busId'] as String,
      routeId: j['routeId'] as String,
      origin: j['origin'] as String,
      departures: deps,
    );
  }
}

/// One bus as the Raspberry Pi has already worked it out.
///
/// Everything here arrives pre-computed: the Pi validated and smoothed the raw
/// GPS, matched it to a route, and derived the next stop and ETA. The app renders
/// this rather than recalculating it, so every phone agrees and the maths lives
/// in one place that can be fixed without an app release.
class BusPosition {
  final String busId;
  final double lat;
  final double lng;
  final double? speed; // m/s
  final double? heading; // degrees, route-matched where possible
  final String? routeId;

  /// Server-side status: `live`, `delayed`, `stale` or `offline`.
  final String? serverStatus;

  /// Seconds since the server last accepted a fix from this bus.
  final double? ageSec;

  /// Fraction of the current route covered, 0..1.
  final double? progress;

  /// The next stop on the route, and when the server expects to reach it.
  final String? nextStop;
  final int? etaSec;

  /// False when the ETA is a timetable guess rather than a tracked estimate.
  final bool etaConfident;

  /// The stop the bus is standing at right now, if any.
  final String? atStop;

  /// Endpoints the driver selected, and where the bus is in that trip.
  /// The publisher flips these itself when the bus turns around, so the tracker
  /// can trust them rather than guessing direction from geometry.
  final String? originId;
  final String? destinationId;
  final String? journeyState; // 'outbound' | 'parked'

  /// True only for positions produced by the local debug simulator. Simulated
  /// buses ignore the printed timetable, so the planner must not apply it to
  /// them. Never set for rows read from the backend.
  final bool simulated;

  final DateTime updatedAt; // UTC

  BusPosition({
    required this.busId,
    required this.lat,
    required this.lng,
    this.speed,
    this.heading,
    this.routeId,
    this.serverStatus,
    this.ageSec,
    this.progress,
    this.nextStop,
    this.etaSec,
    this.etaConfident = false,
    this.atStop,
    this.originId,
    this.destinationId,
    this.journeyState,
    this.simulated = false,
    required this.updatedAt,
  });

  LatLng get pos => LatLng(lat, lng);

  /// Prefer the server's own measurement: it knows when it last heard from the
  /// bus, whereas a clock difference between phone and server would distort a
  /// locally computed age.
  Duration get age => ageSec != null
      ? Duration(milliseconds: (ageSec! * 1000).round())
      : DateTime.now().toUtc().difference(updatedAt.toUtc());

  /// Greyed out on the map. The server decides this where it can; the duration
  /// check is the fallback when we are reading a simulated or legacy position.
  bool get isStale => serverStatus != null
      ? (serverStatus == 'stale' || serverStatus == 'offline')
      : age > Config.staleAfter;

  /// Shown with a "last seen" label: still trusted, but a fix has been missed.
  bool get isDelayed => serverStatus == 'delayed';

  bool get isMoving => (speed ?? 0) >= Config.stoppedSpeedMps;

  /// True when the bus is sitting at a terminal waiting to depart.
  bool get isParked => journeyState == 'parked';

  /// The same bus, but no longer to be believed.
  ///
  /// Used when the server has stopped publishing: the position came from a
  /// retained message whose `status` was frozen at publish time, so the bus
  /// must be shown greyed out however live it claims to be.
  BusPosition asStale() => BusPosition(
        busId: busId,
        lat: lat,
        lng: lng,
        speed: speed,
        heading: heading,
        routeId: routeId,
        serverStatus: 'stale',
        ageSec: ageSec,
        progress: progress,
        nextStop: nextStop,
        etaSec: etaSec,
        etaConfident: false,
        atStop: atStop,
        originId: originId,
        destinationId: destinationId,
        journeyState: journeyState,
        simulated: simulated,
        updatedAt: updatedAt,
      );

  /// Parses one entry of the Pi's `campus/live/buses` snapshot.
  ///
  /// Returns null for a bus the server has never had a fix from: it has no
  /// coordinates, so there is nothing to place on the map.
  static BusPosition? fromLive(Map<String, dynamic> j) {
    final lat = (j['lat'] as num?)?.toDouble();
    final lng = (j['lng'] as num?)?.toDouble();
    final id = j['id'] as String?;
    if (id == null || lat == null || lng == null) return null;

    final age = (j['age'] as num?)?.toDouble();
    return BusPosition(
      busId: id,
      lat: lat,
      lng: lng,
      speed: (j['speed'] as num?)?.toDouble(),
      heading: (j['heading'] as num?)?.toDouble(),
      routeId: j['route'] as String?,
      serverStatus: j['status'] as String?,
      ageSec: age,
      progress: (j['progress'] as num?)?.toDouble(),
      nextStop: j['next_stop'] as String?,
      etaSec: (j['eta_s'] as num?)?.round(),
      etaConfident: (j['eta_confident'] ?? false) as bool,
      atStop: j['at_stop'] as String?,
      originId: j['origin'] as String?,
      destinationId: j['destination'] as String?,
      journeyState: j['journey_state'] as String?,
      updatedAt: DateTime.now()
          .toUtc()
          .subtract(Duration(milliseconds: ((age ?? 0) * 1000).round())),
    );
  }
}
