import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:geolocator/geolocator.dart';

import 'config.dart';
import 'uploader.dart';

/// A phone standing in for an ESP32 tracker unit.
///
/// It does exactly what the firmware does and nothing more: read GPS, sign it,
/// POST it every 5 seconds. There is no route logic, no claiming, no journey
/// state machine and no trip logging here any more — the Raspberry Pi works all
/// of that out from the raw positions, so a phone and a real unit now produce
/// identical results.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PublisherApp());
}

class PublisherApp extends StatelessWidget {
  const PublisherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bus GPS Publisher',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const PublisherPage(),
    );
  }
}

class BusOption {
  final String id;
  final String label;
  const BusOption(this.id, this.label);
}

class PublisherPage extends StatefulWidget {
  const PublisherPage({super.key});

  @override
  State<PublisherPage> createState() => _PublisherPageState();
}

class _PublisherPageState extends State<PublisherPage> {
  final Uploader _uploader = Uploader();

  List<BusOption> _buses = [];
  String? _selectedBusId;

  bool _sharing = false;
  StreamSubscription<Position>? _posSub;
  Timer? _heartbeat;
  Position? _lastPosition;
  DateTime? _lastAcceptedAt;
  int _sent = 0;
  int _accepted = 0;
  String _status = 'Idle';
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _heartbeat?.cancel();
    _uploader.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    await _uploader.init();
    final raw = await rootBundle.loadString('assets/data/buses.json');
    final buses = (jsonDecode(raw)['buses'] as List)
        .map((b) => BusOption(b['id'] as String, b['label'] as String))
        .toList();
    if (!mounted) return;
    setState(() => _buses = buses);
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
    return const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );
  }

  // -------------------------------------------------------------- lifecycle

  Future<void> _startSharing() async {
    if (_selectedBusId == null) {
      _setStatus('Pick which bus you are first.', error: true);
      return;
    }
    if (Config.deviceSecret == 'SET_BEFORE_BUILDING') {
      _setStatus('No device secret compiled in — see lib/config.dart.',
          error: true);
      return;
    }
    if (!await _ensureLocationPermission()) return;

    setState(() {
      _sharing = true;
      _error = null;
      _sent = 0;
      _accepted = 0;
    });

    _posSub = Geolocator.getPositionStream(
      locationSettings: _locationSettings(),
    ).listen(
      (pos) {
        _lastPosition = pos;
        _push(pos);
      },
      onError: (e) => _setStatus('GPS error: $e', error: true),
    );

    // Keep reporting while parked, so the server sees the bus as stationary
    // rather than gone. The position stream goes quiet when nothing moves.
    _heartbeat = Timer.periodic(Config.heartbeat, (_) {
      final p = _lastPosition;
      if (_sharing && p != null) _push(p);
    });

    _setStatus('Sharing location…');
  }

  Future<void> _stopSharing() async {
    _posSub?.cancel();
    _posSub = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    if (mounted) {
      setState(() {
        _sharing = false;
        _status = 'Idle';
      });
    }
  }

  // -------------------------------------------------------------------- push

  DateTime? _lastPushAt;

  Future<void> _push(Position pos) async {
    final busId = _selectedBusId;
    if (busId == null || !_sharing) return;

    // The GPS stream and the heartbeat can both fire; do not double-send.
    final now = DateTime.now();
    final since = _lastPushAt == null ? null : now.difference(_lastPushAt!);
    if (since != null && since < Config.fixInterval - const Duration(seconds: 1)) {
      return;
    }
    _lastPushAt = now;

    _sent++;
    final result = await _uploader.publish(
      busId: busId,
      lat: pos.latitude,
      lng: pos.longitude,
      speedMps: pos.speed >= 0 ? pos.speed : 0,
      // §8: null when unknown, never 0 — zero means due north.
      headingDeg: pos.heading >= 0 ? pos.heading : null,
    );

    if (result.ok) {
      _accepted++;
      _lastAcceptedAt = now;
      _setStatus('Live — sending as $busId');
      return;
    }

    if (result.isFatal) {
      _setStatus('Refused: ${result.describe()} — stopping.', error: true);
      await _stopSharing();
      return;
    }
    _setStatus('Not accepted: ${result.describe()}', error: true);
  }

  void _setStatus(String msg, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = msg;
      _error = error ? msg : null;
    });
  }

  // ---------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final pos = _lastPosition;
    final speedKmh = pos != null ? (pos.speed * 3.6).clamp(0, 999) : 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Bus GPS Publisher')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: Colors.blueGrey.withValues(alpha: 0.2),
              child: const Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'Test tool. This phone pretends to be a tracker unit: it '
                  'signs and posts its GPS to the relay exactly as the ESP32 '
                  'does. The server works out the route, direction and trips.',
                  style: TextStyle(fontSize: 12.5),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text('Which bus is this phone on?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              'Device ${Config.deviceId} is bound to one bus in the relay. '
              'Choosing a different one is refused.',
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
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
            _statusCard(pos, speedKmh.toDouble()),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(Position? pos, double speedKmh) {
    return Card(
      color: _error != null ? Colors.red.withValues(alpha: 0.15) : null,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_status,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 12),
            _row('Accepted', '$_accepted of $_sent sent'),
            _row('Counter', '${_uploader.counter}'),
            _row(
                'Last accepted',
                _lastAcceptedAt == null
                    ? '—'
                    : '${DateTime.now().difference(_lastAcceptedAt!).inSeconds}s ago'),
            const Divider(height: 20),
            _row(
                'Position',
                pos == null
                    ? '—'
                    : '${pos.latitude.toStringAsFixed(6)}, '
                        '${pos.longitude.toStringAsFixed(6)}'),
            _row('Speed', pos == null ? '—' : '${speedKmh.toStringAsFixed(1)} km/h'),
            _row('Heading',
                pos == null || pos.heading < 0 ? 'unknown' : '${pos.heading.round()}°'),
            _row('Accuracy',
                pos == null ? '—' : '±${pos.accuracy.toStringAsFixed(0)} m'),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          Text(value, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}
