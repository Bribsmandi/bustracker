import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tracker/app_data.dart';
import 'package:tracker/basemap.dart';
import 'package:tracker/geo.dart';

void main() {
  late Basemap bm;
  late AppData data;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    bm = await Basemap.load();
    data = await AppData.load();
  });

  test('loads a sensible number of features', () {
    expect(bm.roadsMinor.length, greaterThan(50));
    expect(bm.roadsMajor.length, greaterThan(2));
    expect(bm.buildings.length, greaterThan(30));
    expect(bm.featureCount, greaterThan(150));
  });

  test('every point lies inside the baked bounding box', () {
    const s = 11.3110, w = 75.9270, n = 11.3270, e = 75.9420;
    for (final group in [
      bm.roadsMajor, bm.roadsMinor, bm.buildings, bm.green, bm.water
    ]) {
      for (final line in group) {
        expect(line.length, greaterThanOrEqualTo(2));
        for (final p in line) {
          expect(p.latitude, inInclusiveRange(s, n));
          expect(p.longitude, inInclusiveRange(w, e));
        }
      }
    }
  });

  test('the drawn roads actually pass the bus stops', () {
    // If the vector roads were misaligned, buses would appear to drive on
    // grass. Every stop must sit within ~25 m of some drawn road line.
    double nearestRoad(LatLng pt) {
      var best = double.infinity;
      for (final group in [bm.roadsMajor, bm.roadsMinor]) {
        for (final line in group) {
          final d = RouteGeometry(line).project(pt).offRouteMeters;
          if (d < best) best = d;
        }
      }
      return best;
    }

    for (final stop in data.locatedStops) {
      // SOMS's access road is not mapped in OSM (known gap) — allow more.
      final limit = stop.id == 'soms' ? 90.0 : 25.0;
      expect(nearestRoad(stop.pos!), lessThan(limit),
          reason: '${stop.id} is far from every drawn road');
    }
  });

  test('attribution is present for ODbL compliance', () {
    expect(bm.attribution.toLowerCase(), contains('openstreetmap'));
  });
}
