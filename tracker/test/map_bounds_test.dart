import 'dart:ui' show Size;

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tracker/config.dart';

/// Regression guard for a blank map.
///
/// CameraConstraint.contain() constrains the camera EDGES and returns null when
/// the viewport is larger than the bounds. flutter_map then has no valid camera
/// and renders nothing. That is exactly what happened with contain() + a 1.3 km
/// box, so these tests assert the constraint always yields a usable camera at
/// every zoom and screen size we support.

final campusBounds = LatLngBounds(
  const LatLng(Config.boundsSouth, Config.boundsWest),
  const LatLng(Config.boundsNorth, Config.boundsEast),
);

final contentBounds = LatLngBounds(
  const LatLng(Config.contentSouth, Config.contentWest),
  const LatLng(Config.contentNorth, Config.contentEast),
);

/// Screen sizes to check: small phone, large phone, tablet, and landscape.
const screens = <(String, Size)>[
  ('small phone', Size(360, 380)),
  ('large phone', Size(412, 460)),
  ('tablet', Size(800, 900)),
  ('landscape', Size(900, 380)),
];

MapCamera cameraAt(double zoom, Size size, LatLng center) => MapCamera(
      crs: const Epsg3857(),
      center: center,
      zoom: zoom,
      rotation: 0,
      nonRotatedSize: size,
      size: size,
    );

void main() {
  final center = LatLng(
    (Config.contentSouth + Config.contentNorth) / 2,
    (Config.contentWest + Config.contentEast) / 2,
  );

  group('Camera constraint never blanks the map', () {
    test('containCenter yields a camera at every zoom and screen size', () {
      final constraint = CameraConstraint.containCenter(bounds: campusBounds);
      for (final (name, size) in screens) {
        for (var z = Config.minZoom; z <= Config.maxZoom; z += 0.5) {
          final result = constraint.constrain(cameraAt(z, size, center));
          expect(result, isNotNull,
              reason: 'blank map at zoom $z on $name ($size)');
        }
      }
    });

    test('contain() blanks the map — the bug this replaced', () {
      final constraint = CameraConstraint.contain(bounds: campusBounds);

      // The original bug: minZoom was 15, where a phone viewport (~1930 m) is
      // far wider than the 1259 m box, so contain() returned null every frame.
      expect(
        constraint.constrain(cameraAt(15, const Size(412, 460), center)),
        isNull,
        reason: 'zoom 15 on a phone is what produced the blank map',
      );

      // And it still fails on a big screen even at the current minZoom, which
      // is why raising minZoom alone was not a sufficient fix.
      expect(
        constraint.constrain(cameraAt(Config.minZoom, const Size(800, 900), center)),
        isNull,
        reason: 'a tablet at minZoom would blank under contain()',
      );
    });
  });

  group('Zoom limits', () {
    test('minZoom frames the campus without showing the whole town', () {
      // At minZoom a large phone should see roughly the campus, not multiples
      // of it. Campus content is ~760 m x ~935 m.
      final camera = cameraAt(Config.minZoom, const Size(412, 460), center);
      final visible = camera.visibleBounds;
      const distance = Distance();
      final widthM = distance.as(
        LengthUnit.Meter,
        LatLng(visible.south, visible.west),
        LatLng(visible.south, visible.east),
      );
      expect(widthM, greaterThan(700),
          reason: 'must be wide enough to see the campus');
      expect(widthM, lessThan(1600),
          reason: 'must not be so wide that the campus is a dot');
    });

    test('minZoom is below maxZoom and both are sane for OSM', () {
      expect(Config.minZoom, lessThan(Config.maxZoom));
      expect(Config.maxZoom, lessThanOrEqualTo(19),
          reason: 'OSM has no tiles beyond z19');
    });
  });

  group('Bounds', () {
    test('pan bounds fully contain the campus content', () {
      expect(campusBounds.contains(contentBounds.northEast), isTrue);
      expect(campusBounds.contains(contentBounds.southWest), isTrue);
    });

    test('opening view is framed on the content, not the padded box', () {
      // Fitting the padded box would waste screen on empty margin.
      expect(contentBounds.north, lessThan(campusBounds.north));
      expect(contentBounds.south, greaterThan(campusBounds.south));
    });
  });
}
