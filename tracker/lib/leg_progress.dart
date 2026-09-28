import 'package:flutter/material.dart';
import 'models.dart';

/// A "where is my train" style 1-D progress bar for the incoming leg
/// (origin terminal -> your boarding point), with a bus marker at the bus's
/// current progress and ticks for each intermediate stop.
class LegProgress extends StatelessWidget {
  final List<Stop> stops; // origin .. boarding
  final List<double> stopFractions; // 0..1 for each stop
  final double progress; // 0..1 current bus position
  final Color busColor;

  const LegProgress({
    super.key,
    required this.stops,
    required this.stopFractions,
    required this.progress,
    required this.busColor,
  });

  @override
  Widget build(BuildContext context) {
    const trackHeight = 6.0;
    const busSize = 26.0;
    const rowHeight = 64.0;

    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      // Keep the bus icon fully inside the track horizontally.
      double x(double frac) => (frac.clamp(0.0, 1.0)) * (w - busSize) + busSize / 2;

      return SizedBox(
        height: rowHeight,
        width: w,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Base track
            Positioned(
              left: 0,
              right: 0,
              top: rowHeight / 2 - trackHeight / 2,
              child: Container(
                height: trackHeight,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(trackHeight),
                ),
              ),
            ),
            // Filled portion up to the bus
            Positioned(
              left: 0,
              width: x(progress),
              top: rowHeight / 2 - trackHeight / 2,
              child: Container(
                height: trackHeight,
                decoration: BoxDecoration(
                  color: busColor,
                  borderRadius: BorderRadius.circular(trackHeight),
                ),
              ),
            ),
            // Stop ticks
            for (var i = 0; i < stops.length; i++)
              Positioned(
                left: x(stopFractions[i]) - 5,
                top: rowHeight / 2 - 5,
                child: _tick(i == stops.length - 1),
              ),
            // Stop labels: first (origin) left-aligned, last (boarding) right.
            if (stops.isNotEmpty)
              Positioned(
                left: 0,
                top: rowHeight / 2 + 10,
                child: Text(stops.first.name,
                    style: const TextStyle(fontSize: 11, color: Colors.black54)),
              ),
            if (stops.length > 1)
              Positioned(
                right: 0,
                top: rowHeight / 2 + 10,
                child: Text(stops.last.name,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: busColor)),
              ),
            // The bus
            Positioned(
              left: x(progress) - busSize / 2,
              top: rowHeight / 2 - busSize / 2,
              child: Container(
                width: busSize,
                height: busSize,
                decoration: BoxDecoration(
                  color: busColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 4)
                  ],
                ),
                child: const Icon(Icons.directions_bus,
                    size: 15, color: Colors.white),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _tick(bool isBoarding) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(
            color: isBoarding ? busColor : Colors.grey,
            width: 2,
          ),
        ),
      );
}
