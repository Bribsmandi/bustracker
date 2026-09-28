import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

import 'geo.dart';
import 'models.dart';

/// Loads the static campus data (stops, buses, routes, schedule) from the
/// bundled JSON assets and exposes convenient lookups for the rest of the app.
class AppData {
  final Map<String, Stop> stops;
  final Map<String, BusDef> buses;
  final Map<String, RouteDef> routes;
  final List<ScheduleEntry> schedules;
  final Map<String, RouteGeometry> geometry; // routeId -> geometry

  AppData._(
      this.stops, this.buses, this.routes, this.schedules, this.geometry);

  List<Stop> get orderedStops => stops.values.toList();

  /// Stops that have coordinates filled in — usable on the map.
  List<Stop> get locatedStops =>
      stops.values.where((s) => s.hasCoords).toList();

  List<RouteDef> routesForBus(String busId) =>
      routes.values.where((r) => r.buses.contains(busId)).toList();

  ScheduleEntry? scheduleFor(String busId, String routeId) {
    for (final s in schedules) {
      if (s.busId == busId && s.routeId == routeId) return s;
    }
    return null;
  }

  static Future<Map<String, dynamic>> _load(String name) async {
    final raw = await rootBundle.loadString('assets/data/$name');
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  static Future<AppData> load() async {
    final stopsJson = await _load('stops.json');
    final busesJson = await _load('buses.json');
    final routesJson = await _load('routes.json');
    final scheduleJson = await _load('schedule.json');

    final stops = <String, Stop>{};
    for (final s in stopsJson['stops'] as List) {
      final stop = Stop.fromJson(s as Map<String, dynamic>);
      stops[stop.id] = stop;
    }

    final buses = <String, BusDef>{};
    for (final b in busesJson['buses'] as List) {
      final bus = BusDef.fromJson(b as Map<String, dynamic>);
      buses[bus.id] = bus;
    }

    final routes = <String, RouteDef>{};
    for (final r in routesJson['routes'] as List) {
      final route = RouteDef.fromJson(r as Map<String, dynamic>);
      routes[route.id] = route;
    }

    final schedules = (scheduleJson['schedules'] as List)
        .map((s) => ScheduleEntry.fromJson(s as Map<String, dynamic>))
        .toList();

    // Build metric geometry for each route. A surveyed road path wins over
    // straight lines between stops, because the bus follows the road — and on
    // the MBH loop the outbound and return trips use different roads entirely.
    final geometry = <String, RouteGeometry>{};
    for (final route in routes.values) {
      final pts = route.path.isNotEmpty
          ? route.path
          : [
              for (final stopId in route.stops)
                if (stops[stopId]?.pos != null) stops[stopId]!.pos!
            ];

      final stopPositions = <String, LatLng>{};
      for (final stopId in route.stops) {
        final p = stops[stopId]?.pos;
        if (p != null) stopPositions[stopId] = p;
      }

      geometry[route.id] = RouteGeometry(pts, stopPositions: stopPositions);
    }

    return AppData._(stops, buses, routes, schedules, geometry);
  }
}
