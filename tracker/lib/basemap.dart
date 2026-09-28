import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';

/// The baked campus vector basemap (see tools/bake_basemap.py).
///
/// Rendered directly by flutter_map instead of raster tiles: only roads,
/// buildings, green areas and water — none of the label clutter — crisp at
/// every zoom, and fully offline. Derived from OpenStreetMap, so the map must
/// display [attribution].
class Basemap {
  final List<List<LatLng>> roadsMajor;
  final List<List<LatLng>> roadsMinor;
  final List<List<LatLng>> buildings;
  final List<List<LatLng>> green;
  final List<List<LatLng>> water;
  final String attribution;

  Basemap._({
    required this.roadsMajor,
    required this.roadsMinor,
    required this.buildings,
    required this.green,
    required this.water,
    required this.attribution,
  });

  int get featureCount =>
      roadsMajor.length +
      roadsMinor.length +
      buildings.length +
      green.length +
      water.length;

  static List<List<LatLng>> _lines(dynamic raw) => (raw as List)
      .map((line) => (line as List)
          .map((p) => LatLng((p[0] as num).toDouble(), (p[1] as num).toDouble()))
          .toList())
      .toList();

  factory Basemap.fromJson(Map<String, dynamic> j) => Basemap._(
        roadsMajor: _lines(j['roadsMajor'] ?? []),
        roadsMinor: _lines(j['roadsMinor'] ?? []),
        buildings: _lines(j['buildings'] ?? []),
        green: _lines(j['green'] ?? []),
        water: _lines(j['water'] ?? []),
        attribution:
            j['_attribution'] as String? ?? '© OpenStreetMap contributors',
      );

  static Future<Basemap> load() async {
    final raw = await rootBundle.loadString('assets/data/basemap.json');
    return Basemap.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }
}
