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

/// A live position row from Supabase.
class BusPosition {
  final String busId;
  final double lat;
  final double lng;
  final double? speed; // m/s
  final double? heading; // degrees from GPS (may be null)
  final String? routeId;

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
    this.originId,
    this.destinationId,
    this.journeyState,
    this.simulated = false,
    required this.updatedAt,
  });

  LatLng get pos => LatLng(lat, lng);

  Duration get age => DateTime.now().toUtc().difference(updatedAt.toUtc());
  bool get isStale => age > Config.staleAfter;
  bool get isMoving => (speed ?? 0) >= Config.stoppedSpeedMps;

  /// True when the driver's app says the bus is sitting at its terminal.
  bool get isParked => journeyState == 'parked';

  factory BusPosition.fromJson(Map<String, dynamic> j) => BusPosition(
        busId: j['bus_id'] as String,
        lat: (j['lat'] as num).toDouble(),
        lng: (j['lng'] as num).toDouble(),
        speed: (j['speed'] as num?)?.toDouble(),
        heading: (j['heading'] as num?)?.toDouble(),
        routeId: j['route_id'] as String?,
        originId: j['origin_id'] as String?,
        destinationId: j['destination_id'] as String?,
        journeyState: j['journey_state'] as String?,
        updatedAt: DateTime.parse(j['updated_at'] as String).toUtc(),
      );
}
