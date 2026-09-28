import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'journey.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: Config.supabaseUrl,
    publishableKey: Config.supabaseAnonKey,
  );
  runApp(const PublisherApp());
}

class PublisherApp extends StatelessWidget {
  const PublisherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bus GPS Publisher',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const PublisherPage(),
    );
  }
}

class BusOption {
  final String id;
  final String label;
  BusOption(this.id, this.label);
}

/// Stable per-install id, so the server can tell one phone from another.
Future<String> _deviceId() async {
  final prefs = await SharedPreferences.getInstance();
  var id = prefs.getString('device_id');
  if (id == null) {
    final rnd = math.Random.secure();
    id = List.generate(16, (_) => rnd.nextInt(16).toRadixString(16)).join();
    await prefs.setString('device_id', id);
  }
  return id;
}

class PublisherPage extends StatefulWidget {
  const PublisherPage({super.key});

  @override
  State<PublisherPage> createState() => _PublisherPageState();
}

class _PublisherPageState extends State<PublisherPage> {
  final SupabaseClient _supabase = Supabase.instance.client;

  List<BusOption> _buses = [];
  Map<String, StopPoint> _stops = {};
  List<StopPoint> _terminals = [];
  List<RouteOption> _routes = [];

  String? _deviceIdValue;
  String? _selectedBusId;
  String? _startId;
  String? _destId;

  Journey? _journey;


  bool _sharing = false;
  StreamSubscription<Position>? _posSub;
  Timer? _heartbeat;
  Timer? _recheck;
  Position? _lastPosition;
  DateTime? _lastSentAt;
  String _status = 'Idle';
  Object? _lastError;
  bool _claimOk = false;
  int _tripsToday = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _heartbeat?.cancel();
    _recheck?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    _deviceIdValue = await _deviceId();
    await _loadData();
  }

  Future<void> _loadData() async {
    final busRaw = await rootBundle.loadString('assets/data/buses.json');
    final buses = (jsonDecode(busRaw)['buses'] as List)
        .map((b) => BusOption(b['id'] as String, b['label'] as String))
        .toList();

    final stopRaw = await rootBundle.loadString('assets/data/stops.json');
    final stops = <String, StopPoint>{};
    for (final s in jsonDecode(stopRaw)['stops'] as List) {
      final lat = (s['lat'] as num?)?.toDouble();
      final lng = (s['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      stops[s['id'] as String] = StopPoint(
        id: s['id'] as String,
        name: s['name'] as String? ?? s['id'] as String,
        isTerminal: s['isTerminal'] as bool? ?? false,
        lat: lat,
        lng: lng,
        triggerLat: (s['triggerLat'] as num?)?.toDouble(),
        triggerLng: (s['triggerLng'] as num?)?.toDouble(),
      );
    }

    final routeRaw = await rootBundle.loadString('assets/data/routes.json');
    final routes = (jsonDecode(routeRaw)['routes'] as List)
        .map((r) => RouteOption(
              r['id'] as String,
              r['origin'] as String,
              r['destination'] as String,
            ))
        .toList();

    if (!mounted) return;
    setState(() {
      _buses = buses;
      _stops = stops;
      _terminals = stops.values.where((s) => s.isTerminal).toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      _routes = routes;
    });
  }

  // ------------------------------------------------------------ permissions

  Future<bool> _ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _setStatus('Location services are OFF. Enable GPS.', error: true);
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      _setStatus('Location permission denied.', error: true);
      return false;
    }
    return true;
  }

  // ----------------------------------------------------------------- claim

  /// Ask the server for exclusive rights to broadcast as this bus.
  Future<bool> _claim() async {
    final busId = _selectedBusId, dev = _deviceIdValue;
    if (busId == null || dev == null) return false;
    try {
      final res = await _supabase
          .rpc('claim_bus', params: {'p_bus_id': busId, 'p_device_id': dev});
      final map = (res as Map).cast<String, dynamic>();
      final ok = map['ok'] == true;
      if (!ok) {
        _setStatus('Cannot start: ${map['reason']}', error: true);
      }
      if (mounted) setState(() => _claimOk = ok);
      return ok;
    } catch (e) {
      _setStatus('Claim failed: $e', error: true);
      return false;
    }
  }

  // ------------------------------------------------------------- lifecycle

  /// On Android, run location as a foreground service so the bus keeps
  /// reporting with the screen off — otherwise the OS suspends us the moment
  /// the driver pockets the phone, and the bus silently goes offline.
  LocationSettings _locationSettings() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: Config.fixInterval,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: 'Sharing bus location',
          notificationText: 'This phone is broadcasting its position as a bus.',
          notificationChannelName: 'Bus location sharing',
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    }
    return LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
      timeLimit: null,
    );
  }

  Future<void> _startSharing() async {
    if (_selectedBusId == null) {
      _setStatus('Pick which bus you are first.', error: true);
      return;
    }
    if (_startId == null || _destId == null) {
      _setStatus('Pick your start and destination points.', error: true);
      return;
    }
    if (_startId == _destId) {
      _setStatus('Start and destination must differ.', error: true);
      return;
    }
    if (!await _ensureLocationPermission()) return;
    if (!await _claim()) return;

    setState(() {
      _sharing = true;
      _lastError = null;
      _journey = Journey(originId: _startId!, destinationId: _destId!);
    });
    await _startTrip(_journey!);

    _posSub = Geolocator.getPositionStream(
      locationSettings: _locationSettings(),
    ).listen(
      (pos) {
        _lastPosition = pos;
        _advanceJourney(pos);
        _push(pos);
      },
      onError: (e) => _setStatus('GPS error: $e', error: true),
    );

    // Keep the row fresh even while the bus is parked/idling.
    _heartbeat = Timer.periodic(Config.heartbeat, (_) {
      if (_lastPosition != null) _push(_lastPosition!);
    });

    // Periodic self-check: renew the claim and re-evaluate the journey, so a
    // phone that lost network or was backgrounded recovers without a restart.
    _recheck = Timer.periodic(Config.recheckInterval, (_) async {
      if (!_sharing) return;
      final ok = await _claim();
      if (!ok) {
        _setStatus('Lost the claim on this bus — stopping.', error: true);
        await _stopSharing();
        return;
      }
      final p = _lastPosition;
      if (p != null) _advanceJourney(p);
    });

    _setStatus('Sharing location…');
  }

  /// Run the state machine, record the trip, and surface changes to the driver.
  Future<void> _advanceJourney(Position pos) async {
    final j = _journey;
    if (j == null) return;
    final before = j.state;
    final flipped = j.update(
      pos.latitude,
      pos.longitude,
      _stops,
      speed: pos.speed,
    );

    if (flipped) {
      // Pulled away from the terminal: this is a new leg.
      _setStatus('Return journey started: '
          '${_name(j.originId)} → ${_name(j.destinationId)}');
      await _startTrip(j);
    } else if (before != j.state && j.state == JourneyState.parked) {
      // Reached the terminal and settled: the leg is complete.
      _setStatus('Parked at ${_name(j.destinationId)} — waiting to depart');
      await _endTrip();
    }
    if (mounted) setState(() {});
  }

  /// Open a trip row for the leg the bus is now driving.
  Future<void> _startTrip(Journey j) async {
    final busId = _selectedBusId, dev = _deviceIdValue;
    if (busId == null || dev == null) return;
    try {
      final res = await _supabase.rpc('start_trip', params: {
        'p_bus_id': busId,
        'p_device_id': dev,
        'p_route_id': j.routeIdFrom(_routes),
        'p_origin_id': j.originId,
        'p_destination_id': j.destinationId,
      });
      final map = (res as Map).cast<String, dynamic>();
      if (map['ok'] == true) {
        j.tripId = (map['trip_id'] as num?)?.toInt();
        _tripsToday++;
      }
    } catch (_) {
      // Trip logging is best-effort; never interrupt live tracking for it.
    }
  }

  /// Close the open trip. A leg that never closes keeps a null arrival time,
  /// which correctly records "this leg did not complete".
  Future<void> _endTrip() async {
    final busId = _selectedBusId, dev = _deviceIdValue;
    if (busId == null || dev == null) return;
    try {
      await _supabase
          .rpc('end_trip', params: {'p_bus_id': busId, 'p_device_id': dev});
      _journey?.tripId = null;
    } catch (_) {
      // Best effort.
    }
  }

  String _name(String id) => _stops[id]?.name ?? id;

  Future<void> _stopSharing() async {
    _posSub?.cancel();
    _posSub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    _recheck?.cancel();
    _recheck = null;

    final busId = _selectedBusId, dev = _deviceIdValue;
    if (busId != null && dev != null && _claimOk) {
      try {
        await _supabase.rpc('release_bus',
            params: {'p_bus_id': busId, 'p_device_id': dev});
      } catch (_) {
        // Best effort — the claim expires on its own after 5 minutes.
      }
    }
    if (mounted) {
      setState(() {
        _sharing = false;
        _claimOk = false;
        _journey = null;
        _status = 'Idle';
      });
    }
  }

  // ------------------------------------------------------------------ push

  Future<void> _push(Position pos) async {
    final busId = _selectedBusId, dev = _deviceIdValue;
    final j = _journey;
    if (busId == null || dev == null || j == null) return;
    try {
      final res = await _supabase.rpc('publish_position', params: {
        'p_bus_id': busId,
        'p_device_id': dev,
        'p_lat': pos.latitude,
        'p_lng': pos.longitude,
        'p_speed': pos.speed,
        'p_heading': pos.heading >= 0 ? pos.heading : null,
        'p_route_id': j.routeIdFrom(_routes),
        'p_origin_id': j.originId,
        'p_destination_id': j.destinationId,
        'p_journey_state': j.wireState,
      });
      final map = (res as Map).cast<String, dynamic>();
      if (map['ok'] != true) {
        _setStatus('Rejected: ${map['reason']}', error: true);
        return;
      }
      _lastSentAt = DateTime.now();
      _setStatus('Live — ${_name(j.originId)} → ${_name(j.destinationId)}');
    } catch (e) {
      _setStatus('Upload failed: $e', error: true);
    }
  }

  void _setStatus(String msg, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = msg;
      _lastError = error ? msg : null;
    });
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final pos = _lastPosition;
    final speedKmh = pos != null ? (pos.speed * 3.6).clamp(0, 999) : 0;
    final j = _journey;
    return Scaffold(
      appBar: AppBar(title: const Text('Bus GPS Publisher')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Which bus is this phone on?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _selectedBusId,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Select bus',
              ),
              items: _buses
                  .map((b) =>
                      DropdownMenuItem(value: b.id, child: Text(b.label)))
                  .toList(),
              onChanged:
                  _sharing ? null : (v) => setState(() => _selectedBusId = v),
            ),
            const SizedBox(height: 20),
            const Text('End points for this trip',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text(
              'Pick only where you start and where you finish. The route and '
              'direction update themselves from GPS.',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
            const SizedBox(height: 10),
            _terminalDropdown(
              label: 'Starting point',
              value: _startId,
              onChanged: (v) => setState(() => _startId = v),
            ),
            const SizedBox(height: 12),
            _terminalDropdown(
              label: 'Destination point',
              value: _destId,
              onChanged: (v) => setState(() => _destId = v),
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: _sharing ? _stopSharing : _startSharing,
                icon: Icon(_sharing ? Icons.stop : Icons.play_arrow),
                label: Text(_sharing ? 'Stop sharing' : 'Start sharing'),
                style: FilledButton.styleFrom(
                  backgroundColor: _sharing ? Colors.red : null,
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (j != null) _journeyCard(j),
            if (j != null) const SizedBox(height: 16),
            _statusCard(pos, speedKmh.toDouble()),
          ],
        ),
      ),
    );
  }

  Widget _terminalDropdown({
    required String label,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: label,
      ),
      items: _terminals
          .map((s) => DropdownMenuItem(value: s.id, child: Text(s.name)))
          .toList(),
      onChanged: _sharing ? null : onChanged,
    );
  }

  Widget _journeyCard(Journey j) {
    final parked = j.state == JourneyState.parked;
    return Card(
      color: parked ? Colors.orange.withValues(alpha: 0.15) : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(parked ? Icons.local_parking : Icons.directions_bus,
                    size: 18,
                    color: parked ? Colors.orangeAccent : Colors.greenAccent),
                const SizedBox(width: 8),
                Text(parked ? 'Parked' : 'En route',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            const Divider(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(_name(j.originId),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                const Icon(Icons.arrow_forward, size: 18),
                Expanded(
                  child: Text(_name(j.destinationId),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              parked
                  ? 'Drive off (${Config.departMinDistanceM.round()} m at speed) '
                      'and the return trip starts automatically.'
                  : 'Route: ${j.routeIdFrom(_routes) ?? "not a scheduled route"}',
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(Position? pos, double speedKmh) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.circle,
                    size: 12,
                    color: _sharing ? Colors.greenAccent : Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_status,
                      style: TextStyle(
                          color: _lastError != null ? Colors.redAccent : null)),
                ),
              ],
            ),
            const Divider(height: 24),
            _kv('Latitude', pos?.latitude.toStringAsFixed(6) ?? '—'),
            _kv('Longitude', pos?.longitude.toStringAsFixed(6) ?? '—'),
            _kv('Speed',
                pos != null ? '${speedKmh.toStringAsFixed(1)} km/h' : '—'),
            _kv(
                'Heading',
                (pos != null && pos.heading >= 0)
                    ? '${pos.heading.toStringAsFixed(0)}°'
                    : '—'),
            _kv(
                'Last sent',
                _lastSentAt != null
                    ? '${DateTime.now().difference(_lastSentAt!).inSeconds}s ago'
                    : '—'),
            _kv('Trips this session', '$_tripsToday'),
            _kv('Device', _deviceIdValue?.substring(0, 8) ?? '—'),
          ],
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: const TextStyle(color: Colors.white70)),
            Text(v),
          ],
        ),
      );
}
