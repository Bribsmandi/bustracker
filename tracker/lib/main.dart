import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_data.dart';
import 'basemap.dart';
import 'bus_marker.dart';
import 'config.dart';
import 'simulator.dart';
import 'leg_progress.dart';
import 'models.dart';
import 'tracking.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: Config.supabaseUrl,
    publishableKey: Config.supabaseAnonKey,
  );
  runApp(const TrackerApp());
}

class TrackerApp extends StatelessWidget {
  const TrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Campus Bus Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final SupabaseClient _supabase = Supabase.instance.client;
  final MapController _mapController = MapController();

  AppData? _data;
  Tracker? _tracker;
  Basemap? _basemap;
  final Map<String, BusPosition> _live = {};
  StreamSubscription<List<Map<String, dynamic>>>? _sub;
  Timer? _ticker;
  Timer? _resync;

  /// Debug: drive six fake buses locally instead of reading the backend.
  BusSimulator? _sim;
  bool get _simulating => _sim?.isRunning ?? false;

  /// Remembered across simulator restarts so the chosen pace sticks.
  double _simSpeed = 1.0;

  String? _boardingId;
  String? _destId;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    _resync?.cancel();
    _sim?.stop();
    super.dispose();
  }

  Future<void> _boot() async {
    final data = await AppData.load();
    final basemap = await Basemap.load();
    setState(() {
      _data = data;
      _tracker = Tracker(data);
      _basemap = basemap;
    });

    // Live positions via Supabase realtime.
    _sub = _supabase
        .from('bus_positions')
        .stream(primaryKey: ['bus_id']).listen((rows) {
      if (_simulating) return; // simulator owns _live while it is running
      _live.clear();
      for (final r in rows) {
        final bp = BusPosition.fromJson(r);
        _live[bp.busId] = bp;
      }
      if (mounted) setState(() {});
    });

    // Re-evaluate staleness + ETAs on a timer even without new data.
    _ticker = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });

    // Safety net: the realtime socket can drop silently (backgrounded app,
    // flaky campus wifi). Re-fetch periodically so a dropped subscription
    // shows up as stale-then-recovered rather than frozen-forever data.
    _resync = Timer.periodic(Config.resyncInterval, (_) => _refetch());
    await _refetch();
  }

  /// Amber banner plus the speed control, shown only while simulating.
  Widget _simulationBar() {
    return Container(
      width: double.infinity,
      color: Colors.amber.shade700,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'SIMULATION — these buses are fake, not live data',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.black, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.speed, size: 15, color: Colors.black87),
              const SizedBox(width: 6),
              for (final s in BusSimulator.speedSteps) _speedChip(s),
            ],
          ),
        ],
      ),
    );
  }

  Widget _speedChip(double s) {
    final selected = _simSpeed == s;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: GestureDetector(
        onTap: () => setState(() {
          _simSpeed = s;
          _sim?.speed = s;
        }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: selected ? Colors.black87 : Colors.black12,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Text(
            '${s.toInt()}×',
            style: TextStyle(
              color: selected ? Colors.amberAccent : Colors.black87,
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  /// Toggle the local bus simulator. While simulating, live data is ignored
  /// entirely so the two can never be mixed up.
  void _toggleSimulation() {
    final data = _data;
    if (data == null) return;

    if (_simulating) {
      _sim?.stop();
      _sim = null;
      _live.clear();
      _refetch(); // fall back to whatever is really out there
      setState(() {});
      return;
    }

    _sim = BusSimulator(data)
      ..speed = _simSpeed
      ..start((positions) {
        if (!mounted) return;
        _live
          ..clear()
          ..addAll(positions);
        setState(() {});
      });
    setState(() {});
  }

  /// Pull the full position table once, outside the realtime stream.
  Future<void> _refetch() async {
    if (_simulating) return; // never let live data overwrite the simulation
    try {
      final rows = await _supabase.from('bus_positions').select();
      for (final r in rows) {
        final bp = BusPosition.fromJson(r);
        // Never let a slow poll response overwrite fresher realtime data.
        final existing = _live[bp.busId];
        if (existing == null || bp.updatedAt.isAfter(existing.updatedAt)) {
          _live[bp.busId] = bp;
        }
      }
      // Drop buses that no longer have a row at all (driver released the bus).
      final ids = rows.map((r) => r['bus_id'] as String).toSet();
      _live.removeWhere((k, _) => !ids.contains(k));
      if (mounted) setState(() {});
    } catch (_) {
      // Offline — the staleness rule will grey the buses out on its own.
    }
  }

  /// Where the campus actually is — used to frame the opening view.
  static final LatLngBounds _contentBounds = LatLngBounds(
    const LatLng(Config.contentSouth, Config.contentWest),
    const LatLng(Config.contentNorth, Config.contentEast),
  );

  /// How far the map centre may roam.
  static final LatLngBounds _campusBounds = LatLngBounds(
    const LatLng(Config.boundsSouth, Config.boundsWest),
    const LatLng(Config.boundsNorth, Config.boundsEast),
  );

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final tracker = _tracker;
    if (data == null || tracker == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final busesOnMap = tracker.busesOnMap(_live);
    final availableCount = busesOnMap.where((b) => !b.stale).length;

    PlanResult? plan;
    if (_boardingId != null && _destId != null) {
      plan = tracker.planTrip(_boardingId!, _destId!, _live);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Campus Bus Tracker'),
        actions: [
          IconButton(
            onPressed: _toggleSimulation,
            tooltip: _simulating
                ? 'Stop simulation (use live data)'
                : 'Simulate 6 buses (debug)',
            icon: Icon(
              _simulating ? Icons.bug_report : Icons.bug_report_outlined,
              color: _simulating ? Colors.amberAccent : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Row(children: [
                const Icon(Icons.directions_bus, size: 18),
                const SizedBox(width: 4),
                Text('$availableCount/${data.buses.length} live'),
              ]),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_simulating) _simulationBar(),
          Expanded(child: _buildMap(data, tracker, busesOnMap, plan?.plan)),
          _buildControls(data, plan),
        ],
      ),
    );
  }

  Widget _buildMap(AppData data, Tracker tracker, List<BusOnMap> buses,
      TripPlan? activePlan) {
    final stopMarkers = <Marker>[];
    for (final s in data.locatedStops) {
      final isSel = s.id == _boardingId || s.id == _destId;
      stopMarkers.add(Marker(
        point: s.pos!,
        width: 90,
        height: 44,
        alignment: Alignment.topCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_on,
                color: s.id == _boardingId
                    ? Colors.green
                    : s.id == _destId
                        ? Colors.red
                        : Colors.blueGrey,
                size: isSel ? 30 : 22),
            Text(s.name,
                style: const TextStyle(fontSize: 10, color: Colors.black87),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ));
    }

    final busMarkers = <Marker>[];
    for (final b in buses) {
      busMarkers.add(Marker(
        point: b.position.pos,
        width: 74,
        height: 74,
        child: BusMarker(
          label: b.def.label,
          color: b.def.color,
          bearing: b.bearing,
          stale: b.stale,
          parked: b.position.isParked,
        ),
      ));
    }

    // Draw the active route: the whole way in a light tint, and the part the
    // bus has already covered in solid dark blue on top of it.
    final polylines = <Polyline>[];
    if (activePlan != null) {
      final geom = data.geometry[activePlan.route.id];
      if (geom != null && geom.isUsable) {
        final along = activePlan.busDistanceAlong;
        final split = geom.splitAt(along);

        // Full route underneath, faint.
        polylines.add(Polyline(
          points: geom.points,
          strokeWidth: 7,
          color: kRouteRemaining,
        ));
        // Covered portion on top, solid.
        if (split.covered.length >= 2) {
          polylines.add(Polyline(
            points: split.covered,
            strokeWidth: 7,
            color: kRouteCovered,
          ));
        }
      }
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: _contentBounds,
              padding: const EdgeInsets.all(16),
            ),
            // Keep the map on campus by clamping the centre. Do NOT use
            // CameraConstraint.contain here: it constrains the camera EDGES and
            // returns null whenever the viewport is larger than the box, which
            // leaves flutter_map with no valid camera and a blank screen.
            cameraConstraint:
                CameraConstraint.containCenter(bounds: _campusBounds),
            minZoom: Config.minZoom,
            maxZoom: Config.maxZoom,
            // Land colour behind the vector features.
            backgroundColor: const Color(0xFFF4F2ED),
          ),
          // Our own vector basemap instead of raster tiles: no label clutter,
          // crisp at any zoom, and the map keeps working with no connection.
          children: [
            ..._basemapLayers(),
            if (polylines.isNotEmpty) PolylineLayer(polylines: polylines),
            MarkerLayer(markers: stopMarkers),
            MarkerLayer(markers: busMarkers),
          ],
        ),
        // Required: the basemap geometry is derived from OpenStreetMap data.
        Positioned(
          right: 4,
          bottom: 2,
          child: Text(
            '© OpenStreetMap contributors',
            style: TextStyle(fontSize: 9, color: Colors.black.withValues(alpha: 0.45)),
          ),
        ),
        if (data.locatedStops.isEmpty)
          const Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: _Banner(
              'No stop coordinates yet. Fill lat/lng in assets/data/stops.json '
              'to place stops and buses on the map.',
            ),
          ),
      ],
    );
  }

  /// The campus drawn from baked vector data: water and green under buildings,
  /// roads on top as white fills over grey casings (the classic map look).
  List<Widget> _basemapLayers() {
    final bm = _basemap;
    if (bm == null) return const [];

    Polygon poly(List<LatLng> pts, Color fill, Color border) => Polygon(
        points: pts,
        color: fill,
        borderColor: border,
        borderStrokeWidth: 0.8);

    Polyline line(List<LatLng> pts, double w, Color c) =>
        Polyline(points: pts, strokeWidth: w, color: c);

    return [
      PolygonLayer(polygons: [
        for (final p in bm.green)
          poly(p, const Color(0xFFDDE8D2), const Color(0xFFD0DEC3)),
        for (final p in bm.water)
          poly(p, const Color(0xFFC9DEEC), const Color(0xFFB4CFE2)),
        for (final p in bm.buildings)
          poly(p, const Color(0xFFE3E0D8), const Color(0xFFCFCBC1)),
      ]),
      // Road casings first, fills on top, majors widest.
      PolylineLayer(polylines: [
        for (final r in bm.roadsMinor) line(r, 5.5, const Color(0xFFD4D0C8)),
        for (final r in bm.roadsMajor) line(r, 8, const Color(0xFFCDC9C0)),
        for (final r in bm.roadsMinor) line(r, 3.5, Colors.white),
        for (final r in bm.roadsMajor) line(r, 5.5, Colors.white),
      ]),
    ];
  }

  Widget _buildControls(AppData data, PlanResult? plan) {
    final stops = data.orderedStops;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)],
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(
              child: _stopDropdown(
                label: 'Boarding point',
                icon: Icons.my_location,
                value: _boardingId,
                stops: stops,
                onChanged: (v) => setState(() => _boardingId = v),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _stopDropdown(
                label: 'Destination',
                icon: Icons.flag,
                value: _destId,
                stops: stops,
                onChanged: (v) => setState(() => _destId = v),
              ),
            ),
          ]),
          const SizedBox(height: 14),
          if (plan != null) _planCard(plan),
          if (_boardingId != null && _destId != null && _boardingId != _destId)
            _scheduleStrip(data),
        ],
      ),
    );
  }

  /// The rest of today's printed departures for the selected trip, grouped by
  /// the terminal each time refers to.
  Widget _scheduleStrip(AppData data) {
    final deps = _tracker!.upcomingDepartures(_boardingId!, _destId!);

    if (deps.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 10),
        child: Text('No more scheduled departures today.',
            style: TextStyle(fontSize: 12, color: Colors.black54)),
      );
    }

    // Group by origin terminal, keeping overall time order within each group.
    final byOrigin = <String, List<UpcomingDeparture>>{};
    for (final d in deps) {
      byOrigin.putIfAbsent(d.originId, () => []).add(d);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        for (final entry in byOrigin.entries) ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Departures from ${data.stops[entry.key]?.name ?? entry.key}',
              style: const TextStyle(
                  fontSize: 11,
                  color: Colors.black54,
                  fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 26,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final d in entry.value) _departureChip(d),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  Widget _departureChip(UpcomingDeparture d) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: Colors.grey.shade300, width: 0.7),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: d.bus.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(d.time,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.black87)),
        ],
      ),
    );
  }

  Widget _stopDropdown({
    required String label,
    required IconData icon,
    required String? value,
    required List<Stop> stops,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, size: 20),
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      items: stops
          .map((s) => DropdownMenuItem(value: s.id, child: Text(s.name)))
          .toList(),
      onChanged: onChanged,
    );
  }

  Widget _planCard(PlanResult result) {
    final plan = result.plan;
    if (plan == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.orange.shade50,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          const Icon(Icons.info_outline, color: Colors.orange),
          const SizedBox(width: 10),
          Expanded(child: Text(result.message)),
        ]),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(
            width: 12, height: 12,
            decoration:
                BoxDecoration(color: plan.bus.color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(plan.bus.label,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Spacer(),
          Text(_etaText(plan.etaToBoardingSec),
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                  color: plan.bus.color)),
        ]),
        const SizedBox(height: 6),
        LegProgress(
          stops: plan.legStops,
          stopFractions: plan.legStopFractions,
          progress: plan.progressToBoarding,
          busColor: plan.bus.color,
        ),
        const SizedBox(height: 4),
        Text(
          _planSubtitle(plan),
          style: const TextStyle(color: Colors.black54, fontSize: 12),
        ),
      ],
    );
  }

  /// Explain, in one line, how this bus is going to reach you.
  String _planSubtitle(TripPlan plan) {
    final boarding = _data!.stops[_boardingId]?.name ?? 'your stop';
    final ride = 'Ride ≈ ${_mins(plan.rideSec)}.';

    if (plan.finishedForToday) {
      // Ranked last on purpose — say why, so a stale-looking ETA makes sense.
      return '${plan.bus.label} has no scheduled departures left today. '
          'No other bus is currently heading to $boarding.';
    }
    if (plan.viaStopId != null) {
      // The bus passes your stop the wrong way round first. Without this line
      // "why does it say 25 min when I can see the bus?" is unanswerable.
      final via = _data!.stops[plan.viaStopId!]?.name ?? plan.viaStopId!;
      return plan.scheduledDeparture != null
          ? 'Goes to $via first, turns around, departs back ~${plan.scheduledDeparture}. $ride'
          : 'Goes to $via first, then comes back to $boarding. $ride';
    }
    if (plan.waitingAtTerminal) {
      return plan.scheduledDeparture != null
          ? 'Waiting at $boarding. Departs ~${plan.scheduledDeparture}. $ride'
          : 'Waiting at $boarding. Departing shortly. $ride';
    }
    if (plan.arrivingToTurnAround) {
      // The bus is finishing the opposite leg and will turn around at your
      // stop — say so, or an arriving-then-waiting bus looks like a wrong ETA.
      final from = _data!.stops[plan.route.origin]?.name ?? 'the other end';
      return plan.scheduledDeparture != null
          ? 'Coming in from $from, then departs $boarding ~${plan.scheduledDeparture}. $ride'
          : 'Coming in from $from, turns around at $boarding. $ride';
    }
    return 'Heading to $boarding. $ride';
  }

  String _etaText(int sec) {
    if (sec <= 30) return 'Arriving';
    final m = (sec / 60).round();
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    return '${h}h ${m % 60}m';
  }

  String _mins(int sec) => '${(sec / 60).round()} min';
}

class _Banner extends StatelessWidget {
  final String text;
  const _Banner(this.text);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(children: [
        const Icon(Icons.warning_amber, color: Colors.orange),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
      ]),
    );
  }
}
