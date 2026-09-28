import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Colours for the route line. Standard "how far along am I" convention:
/// the whole route in a light tint, the part already covered in solid dark blue.
const Color kRouteRemaining = Color(0x558FB6E8); // light, translucent blue
const Color kRouteCovered = Color(0xFF0D47A1); // dark blue

/// How to draw a side-view bus so its nose points along [bearing] without the
/// bus ever being upside down.
///
/// The sprite faces right (east). For eastward headings we rotate it directly;
/// for westward headings we mirror it (nose now faces west) and rotate from
/// there. Either way the rotation stays within +-90 degrees, so the wheels
/// always point roughly down.
({bool mirrored, double angleRad}) busOrientation(double bearing) {
  final b = ((bearing % 360) + 360) % 360;
  if (b <= 180) {
    // Eastward half (incl. due north/south): nose starts at bearing 90.
    return (mirrored: false, angleRad: (b - 90) * math.pi / 180.0);
  }
  // Westward half: mirrored nose starts at bearing 270.
  return (mirrored: true, angleRad: (b - 270) * math.pi / 180.0);
}

/// A bus on the map, drawn in side view. The front of the bus (windscreen and
/// headlight) shows the direction of travel; the number badge stays upright.
class BusMarker extends StatelessWidget {
  final String label;
  final Color color;
  final double bearing; // degrees, 0 = north
  final bool stale;
  final bool parked;

  const BusMarker({
    super.key,
    required this.label,
    required this.color,
    required this.bearing,
    this.stale = false,
    this.parked = false,
  });

  /// Short form for the badge: "Bus 1" -> "1", "AC Bus (MBH)" -> "AC".
  String get _short {
    final digits = RegExp(r'\d+').firstMatch(label)?.group(0);
    if (digits != null) return digits;
    if (label.toUpperCase().contains('AC')) return 'AC';
    return label.characters.take(2).toString();
  }

  @override
  Widget build(BuildContext context) {
    final c = stale ? Colors.grey.shade600 : color;
    final o = busOrientation(bearing);
    return Opacity(
      opacity: stale ? 0.4 : 1.0,
      child: SizedBox(
        width: 74,
        height: 74,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Transform.rotate(
              angle: o.angleRad,
              child: CustomPaint(
                size: const Size(74, 74),
                painter: _BusPainter(color: c, mirrored: o.mirrored),
              ),
            ),
            // Number badge: a Stack sibling, so it never rotates with the bus.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c, width: 1.5),
              ),
              child: Text(
                _short,
                style: TextStyle(
                  color: stale ? Colors.grey.shade700 : Colors.black87,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                ),
              ),
            ),
            if (parked)
              Positioned(
                right: 10,
                top: 10,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    color: Colors.orange,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.local_parking,
                      size: 10, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Draws a side-view bus facing right; [mirrored] flips it to face left.
class _BusPainter extends CustomPainter {
  final Color color;
  final bool mirrored;

  _BusPainter({required this.color, required this.mirrored});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    if (mirrored) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }

    // Body: 12..62 x 26..47, nose on the right.
    final body = Path()
      ..moveTo(15, 26)
      ..lineTo(56, 26)
      // Sloped windscreen down to the nose.
      ..quadraticBezierTo(62, 26, 63, 33)
      ..lineTo(63, 43)
      ..quadraticBezierTo(63, 47, 59, 47)
      ..lineTo(15, 47)
      ..quadraticBezierTo(11, 47, 11, 43)
      ..lineTo(11, 30)
      ..quadraticBezierTo(11, 26, 15, 26)
      ..close();

    // White casing first so the bus reads against any map tile.
    canvas.drawPath(
      body,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(body, Paint()..color = color);

    // Windows: two side windows + the windscreen marking the front.
    final glass = Paint()..color = Colors.white.withValues(alpha: 0.9);
    RRect win(double x, double w) => RRect.fromRectAndRadius(
        Rect.fromLTWH(x, 29.5, w, 8), const Radius.circular(2));
    canvas.drawRRect(win(15, 12), glass);
    canvas.drawRRect(win(30, 12), glass);
    // Windscreen: slanted, hugging the nose.
    final windscreen = Path()
      ..moveTo(52, 29.5)
      ..lineTo(58, 29.5)
      ..quadraticBezierTo(60.5, 30, 61, 34)
      ..lineTo(61, 37.5)
      ..lineTo(52, 37.5)
      ..close();
    canvas.drawPath(windscreen, glass);

    // Headlight at the nose.
    canvas.drawCircle(const Offset(61, 43), 1.8,
        Paint()..color = const Color(0xFFFFF3B0));

    // Wheels, half-proud of the body.
    final tyre = Paint()..color = const Color(0xFF212121);
    final rim = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    for (final cx in const [21.0, 52.0]) {
      canvas.drawCircle(Offset(cx, 47), 5, tyre);
      canvas.drawCircle(Offset(cx, 47), 5, rim);
      canvas.drawCircle(Offset(cx, 47), 1.6, Paint()..color = Colors.white70);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BusPainter old) =>
      old.color != color || old.mirrored != mirrored;
}
