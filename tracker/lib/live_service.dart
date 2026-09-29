import 'dart:async';
import 'dart:convert';

import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import 'config.dart';
import 'models.dart';

/// Connection state, so the UI can distinguish "no buses running" from
/// "we cannot reach the server" — which look identical on a map otherwise.
enum LiveStatus { connecting, live, disconnected }

/// Subscribes to the processed bus state the Raspberry Pi publishes.
///
/// The app does no tracking maths of its own on this data: the Pi has already
/// validated, smoothed and route-matched every fix, worked out which stop is
/// next and when the bus will reach it. All of it arrives pre-computed.
///
/// Every topic is published retained, so the current state of the whole fleet
/// lands in the first moments after subscribing — there is no separate "fetch
/// once, then subscribe" step and no window where the map is empty but live.
class LiveService {
  final _busController = StreamController<Map<String, BusPosition>>.broadcast();
  final _statusController = StreamController<LiveStatus>.broadcast();
  final _configController = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, BusPosition>> get buses => _busController.stream;
  Stream<LiveStatus> get status => _statusController.stream;

  /// Stops, routes and the timetable, as published by the Pi. Lets a data fix
  /// reach the app without a release; the bundled assets are the fallback.
  Stream<Map<String, dynamic>> get config => _configController.stream;

  MqttClient? _client;
  Timer? _reconnect;
  bool _disposed = false;
  LiveStatus _status = LiveStatus.connecting;

  LiveStatus get currentStatus => _status;

  /// The most recent snapshot, kept so a late subscriber (a rebuilt widget)
  /// does not have to wait for the next publish.
  Map<String, BusPosition> latest = {};
  DateTime? lastMessageAt;

  Future<void> start() async {
    _disposed = false;
    await _connect();
  }

  Future<void> _connect() async {
    if (_disposed) return;
    _setStatus(LiveStatus.connecting);

    // A stable client id would make two phones fight over one session, so it
    // includes a timestamp.
    final clientId = 'tracker-${DateTime.now().millisecondsSinceEpoch}';

    // MqttServerClient handles both native TCP and WebSocket. The browser client
    // is deliberately not used: importing it pulls in dart:js_interop, which
    // cannot be compiled for Android or iOS at all.
    final MqttServerClient client = Config.useWebSocket
        ? (MqttServerClient.withPort(
            'ws://${Config.mqttHost}', clientId, Config.mqttWsPort)
          ..useWebSocket = true)
        : MqttServerClient.withPort(Config.mqttHost, clientId, Config.mqttPort);

    client.logging(on: false);
    client.keepAlivePeriod = 30;
    client.autoReconnect = true;
    client.onDisconnected = _onDisconnected;
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean();
    _client = client;

    try {
      await client.connect(Config.mqttUsername, Config.mqttPassword);
    } catch (_) {
      client.disconnect();
      _scheduleReconnect();
      return;
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      _scheduleReconnect();
      return;
    }

    client.subscribe(Config.topicBuses, MqttQos.atMostOnce);
    client.subscribe(Config.topicConfig, MqttQos.atMostOnce);
    client.updates?.listen(_onMessages);
    _setStatus(LiveStatus.live);
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> events) {
    for (final event in events) {
      final payload = event.payload;
      if (payload is! MqttPublishMessage) continue;
      final text =
          MqttPublishPayload.bytesToStringAsString(payload.payload.message);

      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(text);
        if (decoded is! Map<String, dynamic>) continue;
        body = decoded;
      } catch (_) {
        continue; // a malformed publish must not take the app down
      }

      if (event.topic == Config.topicConfig) {
        _configController.add(body);
        continue;
      }
      if (event.topic == Config.topicBuses) {
        _handleSnapshot(body);
      }
    }
  }

  void _handleSnapshot(Map<String, dynamic> body) {
    final list = body['buses'];
    if (list is! List) return;

    final next = <String, BusPosition>{};
    for (final entry in list) {
      if (entry is! Map<String, dynamic>) continue;
      final bp = BusPosition.fromLive(entry);
      // A bus the server has never heard from has no coordinates to draw.
      if (bp != null) next[bp.busId] = bp;
    }

    latest = next;
    lastMessageAt = DateTime.now();
    _setStatus(LiveStatus.live);
    if (!_busController.isClosed) _busController.add(next);
  }

  void _onDisconnected() {
    if (_disposed) return;
    _setStatus(LiveStatus.disconnected);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _setStatus(LiveStatus.disconnected);
    _reconnect?.cancel();
    _reconnect = Timer(Config.reconnectDelay, _connect);
  }

  void _setStatus(LiveStatus s) {
    if (_status == s) return;
    _status = s;
    if (!_statusController.isClosed) _statusController.add(s);
  }

  void dispose() {
    _disposed = true;
    _reconnect?.cancel();
    try {
      _client?.disconnect();
    } catch (_) {
      // Disconnecting an already-dead socket is not worth reporting.
    }
    _busController.close();
    _statusController.close();
    _configController.close();
  }
}
