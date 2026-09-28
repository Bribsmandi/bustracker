import 'dart:math' as math;
import 'package:latlong2/latlong.dart';

/// Geometry helpers for placing a bus on its route and measuring distances.
///
/// Distances are in metres. We use an equirectangular local projection around
/// the route, which is more than accurate enough at campus scale and lets us do
/// fast point-to-segment projection in a flat metric space.

const double _earthRadius = 6371000.0;

double _deg2rad(double d) => d * math.pi / 180.0;
double _rad2deg(double r) => r * 180.0 / math.pi;

/// Great-circle distance between two lat/lng points, in metres.
double haversineMeters(LatLng a, LatLng b) {
  final dLat = _deg2rad(b.latitude - a.latitude);
  final dLng = _deg2rad(b.longitude - a.longitude);
  final la1 = _deg2rad(a.latitude);
  final la2 = _deg2rad(b.latitude);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(la1) * math.cos(la2) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * _earthRadius * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Initial compass bearing from `a` to `b`, in degrees (0 = North, clockwise).
double bearingDegrees(LatLng a, LatLng b) {
  final la1 = _deg2rad(a.latitude);
  final la2 = _deg2rad(b.latitude);
  final dLng = _deg2rad(b.longitude - a.longitude);
  final y = math.sin(dLng) * math.cos(la2);
  final x = math.cos(la1) * math.sin(la2) -
      math.sin(la1) * math.cos(la2) * math.cos(dLng);
  return (_rad2deg(math.atan2(y, x)) + 360.0) % 360.0;
}

/// Smallest absolute difference between two bearings, in degrees (0..180).
double bearingDiff(double a, double b) {
  final d = (a - b).abs() % 360.0;
  return d > 180.0 ? 360.0 - d : d;
}

/// The result of snapping a bus location onto a route polyline.
class RouteProjection {
  /// Index of the segment (points[i] -> points[i+1]) the bus is on.
  final int segmentIndex;

  /// The snapped location on the route.
  final LatLng snapped;

  /// Distance travelled from the route start to the snapped point, metres.
  final double distanceAlong;

  /// How far the bus is from the route line, metres (fit quality).
  final double offRouteMeters;

  /// Direction of travel along the route at this point, degrees.
  final double routeBearing;

  RouteProjection({
    required this.segmentIndex,
    required this.snapped,
    required this.distanceAlong,
    required this.offRouteMeters,
    required this.routeBearing,
  });
}

/// Pre-computed metric geometry for one route.
///
/// [points] is the polyline the bus actually drives: either the surveyed road
/// path from routes.json, or — when no path was surveyed — a straight line
/// through the route's stops.
class RouteGeometry {
  final List<LatLng> points;
  final List<double> cumulative; // cumulative distance at each point (metres)
  final LatLng origin; // reference for the local flat projection

  /// How far along the polyline each stop sits, in metres. Computed by snapping
  /// the stop onto the path, so it stays correct when the path has far more
  /// points than the route has stops.
  final Map<String, double> stopAlong;

  RouteGeometry._(this.points, this.cumulative, this.origin, this.stopAlong);

  double get totalLength => cumulative.isEmpty ? 0 : cumulative.last;
  bool get isUsable => points.length >= 2;

  /// [stopPositions] maps stopId -> coordinate, for stops on this route.
  factory RouteGeometry(List<LatLng> pts,
      {Map<String, LatLng> stopPositions = const {}}) {
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + haversineMeters(pts[i - 1], pts[i]));
    }
    final ref = pts.isNotEmpty ? pts.first : const LatLng(0, 0);
    final geom = RouteGeometry._(pts, cum, ref, {});
    if (pts.length >= 2) {
      stopPositions.forEach((id, p) {
        geom.stopAlong[id] = geom.project(p).distanceAlong;
      });
    }
    return geom;
  }

  /// The point [along] metres down the polyline, and the direction of travel
  /// there. Used by the simulator to drive a bus along its route.
  ({LatLng point, double bearing}) positionAt(double along) {
    if (points.isEmpty) {
      return (point: const LatLng(0, 0), bearing: 0);
    }
    if (points.length == 1 || along <= 0) {
      return (point: points.first, bearing: 0);
    }
    if (along >= totalLength) {
      return (
        point: points.last,
        bearing: bearingDegrees(points[points.length - 2], points.last),
      );
    }

    for (var i = 1; i < points.length; i++) {
      if (cumulative[i] < along) continue;
      final prev = points[i - 1];
      final segLen = cumulative[i] - cumulative[i - 1];
      final t = segLen == 0 ? 0.0 : (along - cumulative[i - 1]) / segLen;
      return (
        point: LatLng(
          prev.latitude + (points[i].latitude - prev.latitude) * t,
          prev.longitude + (points[i].longitude - prev.longitude) * t,
        ),
        bearing: bearingDegrees(prev, points[i]),
      );
    }
    return (point: points.last, bearing: 0);
  }

  /// The polyline split at [along] metres: the part already covered and the
  /// part still ahead. Used to draw travelled vs remaining route.
  ({List<LatLng> covered, List<LatLng> remaining}) splitAt(double along) {
    if (points.length < 2) return (covered: const [], remaining: points);
    if (along <= 0) return (covered: const [], remaining: points);
    if (along >= totalLength) return (covered: points, remaining: const []);

    final covered = <LatLng>[];
    for (var i = 0; i < points.length; i++) {
      if (cumulative[i] <= along) {
        covered.add(points[i]);
      } else {
        // Interpolate the exact split point on this segment.
        final prev = points[i - 1];
        final segLen = cumulative[i] - cumulative[i - 1];
        final t = segLen == 0 ? 0.0 : (along - cumulative[i - 1]) / segLen;
        final cut = LatLng(
          prev.latitude + (points[i].latitude - prev.latitude) * t,
          prev.longitude + (points[i].longitude - prev.longitude) * t,
        );
        covered.add(cut);
        return (covered: covered, remaining: [cut, ...points.sublist(i)]);
      }
    }
    return (covered: points, remaining: const []);
  }

  /// Convert lat/lng to local flat metres relative to [origin].
  ({double x, double y}) _toXY(LatLng p) {
    final x = _deg2rad(p.longitude - origin.longitude) *
        math.cos(_deg2rad(origin.latitude)) *
        _earthRadius;
    final y = _deg2rad(p.latitude - origin.latitude) * _earthRadius;
    return (x: x, y: y);
  }

  /// Snap [bus] to the nearest point on the route polyline.
  RouteProjection project(LatLng bus) {
    final b = _toXY(bus);
    double best = double.infinity;
    int bestSeg = 0;
    double bestT = 0;

    for (var i = 0; i < points.length - 1; i++) {
      final p1 = _toXY(points[i]);
      final p2 = _toXY(points[i + 1]);
      final dx = p2.x - p1.x;
      final dy = p2.y - p1.y;
      final segLen2 = dx * dx + dy * dy;
      double t = segLen2 == 0
          ? 0
          : (((b.x - p1.x) * dx + (b.y - p1.y) * dy) / segLen2);
      t = t.clamp(0.0, 1.0);
      final projX = p1.x + t * dx;
      final projY = p1.y + t * dy;
      final d2 = (b.x - projX) * (b.x - projX) + (b.y - projY) * (b.y - projY);
      if (d2 < best) {
        best = d2;
        bestSeg = i;
        bestT = t;
      }
    }

    final segStart = points[bestSeg];
    final segEnd = points[bestSeg + 1];
    final snapped = LatLng(
      segStart.latitude + (segEnd.latitude - segStart.latitude) * bestT,
      segStart.longitude + (segEnd.longitude - segStart.longitude) * bestT,
    );
    final along = cumulative[bestSeg] + haversineMeters(segStart, snapped);

    return RouteProjection(
      segmentIndex: bestSeg,
      snapped: snapped,
      distanceAlong: along,
      offRouteMeters: math.sqrt(best),
      routeBearing: bearingDegrees(segStart, segEnd),
    );
  }
}
