import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// Outcome of one publish.
class UploadResult {
  final bool ok;
  final String? reason;

  const UploadResult(this.ok, [this.reason]);

  /// A configuration problem, as opposed to a dropped connection: retrying an
  /// identical message will never start working.
  bool get isFatal => reason == 'no device secret compiled in';

  String describe() => ok ? 'Published' : (reason ?? 'failed');
}

/// Publishes signed positions exactly as the ESP32 firmware does.
///
/// MQTT has no header to carry the signature, so the payload is framed as
///
///     <64 hex chars>.<the exact JSON bytes that were signed>
///
/// The body is built once, signed, and those same bytes are sent. Re-encoding
/// between signing and sending changes the hash and is the usual cause of a
/// rejected signature.
class Uploader {
  static const _counterKey = 'publisher_counter';

  MqttServerClient? _client;
  int _counter = 0;
  SharedPreferences? _prefs;
  String? _busId;
  Timer? _reconnect;
  bool _stopped = true;

  bool get connected =>
      _client?.connectionStatus?.state == MqttConnectionState.connected;

  int get counter => _counter;

  /// The counter must increase forever, per device, across restarts — otherwise
  /// the server rejects everything as a replay until it climbs past its old
  /// high-water mark. Seeding from wall-clock seconds gives that for free, and
  /// the stored value guards against a clock that jumps backwards.
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final stored = _prefs?.getInt(_counterKey) ?? 0;
    final fromClock = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _counter = fromClock > stored ? fromClock : stored + 1;
  }

  // ------------------------------------------------------------- connection

  Future<void> connect(String busId) async {
    _busId = busId;
    _stopped = false;
    await _open();
  }

  Future<void> _open() async {
    if (_stopped) return;

    final busId = _busId;
    if (busId == null) return;

    final client = MqttServerClient.withPort(
      Config.mqttHost,
      'pub-${Config.deviceId}-${DateTime.now().millisecondsSinceEpoch}',
      Config.mqttPort,
    );
    client.logging(on: false);
    client.keepAlivePeriod = Config.keepAliveSeconds;
    client.autoReconnect = true;
    client.onDisconnected = _onDisconnected;

    // The server marks a bus offline when the broker reports us gone, which is
    // the one thing a plain HTTP client could never do for itself.
    client.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(client.clientIdentifier)
        .withWillTopic(Config.statusTopic(busId))
        .withWillMessage('offline')
        .withWillQos(MqttQos.atLeastOnce)
        .withWillRetain()
        .startClean();

    _client = client;
    try {
      await client.connect();
    } catch (_) {
      client.disconnect();
      _scheduleReconnect();
      return;
    }
    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      _scheduleReconnect();
      return;
    }

    _publishRaw(Config.statusTopic(busId), 'online',
        qos: MqttQos.atLeastOnce, retain: true);
  }

  void _onDisconnected() {
    if (_stopped) return;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_stopped) return;
    _reconnect?.cancel();
    _reconnect = Timer(Config.reconnectDelay, _open);
  }

  Future<void> disconnect() async {
    _stopped = true;
    _reconnect?.cancel();
    final busId = _busId;
    if (connected && busId != null) {
      _publishRaw(Config.statusTopic(busId), 'offline',
          qos: MqttQos.atLeastOnce, retain: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    try {
      _client?.disconnect();
    } catch (_) {
      // Disconnecting an already-dead socket is not worth reporting.
    }
    _client = null;
  }

  // ---------------------------------------------------------------- payload

  /// Builds the exact JSON the server will verify. Key order is part of the
  /// contract: the signature covers these bytes.
  static String buildBody({
    required String busId,
    required String deviceId,
    required int counter,
    required double lat,
    required double lng,
    double? speedMps,
    double? headingDeg,
  }) {
    return jsonEncode(<String, dynamic>{
      'b': busId,
      'd': deviceId,
      'c': counter,
      'lat': double.parse(lat.toStringAsFixed(6)),
      'lng': double.parse(lng.toStringAsFixed(6)),
      // Metres per second, never km/h or knots.
      'spd': speedMps == null ? 0.0 : double.parse(speedMps.toStringAsFixed(2)),
      // null, never 0: zero means due north and would point every parked bus
      // the same wrong way on the map.
      'hdg': headingDeg,
    });
  }

  static String sign(String raw, String secret) =>
      Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(raw)).toString();

  /// The wire format: signature, a dot, then the signed bytes verbatim.
  static String frame(String body, String secret) => '${sign(body, secret)}.$body';

  // ---------------------------------------------------------------- publish

  Future<UploadResult> publish({
    required String busId,
    required double lat,
    required double lng,
    double? speedMps,
    double? headingDeg,
  }) async {
    if (Config.deviceSecret == 'SET_BEFORE_BUILDING') {
      return const UploadResult(false, 'no device secret compiled in');
    }
    if (!connected) {
      // A dead spot is an ordinary event, not an error worth stopping for. The
      // fix is dropped; the next one will be fresher anyway.
      return const UploadResult(false, 'not connected');
    }

    _counter++;
    // Persist before sending: a crash mid-publish must not let the counter be
    // reused, which would look like a replay.
    await _prefs?.setInt(_counterKey, _counter);

    final body = buildBody(
      busId: busId,
      deviceId: Config.deviceId,
      counter: _counter,
      lat: lat,
      lng: lng,
      speedMps: speedMps,
      headingDeg: headingDeg,
    );

    try {
      _publishRaw(Config.gpsTopic(busId), frame(body, Config.deviceSecret));
      return const UploadResult(true);
    } catch (e) {
      return UploadResult(false, '$e');
    }
  }

  void _publishRaw(String topic, String payload,
      {MqttQos qos = MqttQos.atMostOnce, bool retain = false}) {
    final builder = MqttClientPayloadBuilder()..addUTF8String(payload);
    // Positions go at QoS 0: a fix that needs retrying is already too old to be
    // worth delivering.
    _client?.publishMessage(topic, qos, builder.payload!, retain: retain);
  }

  void dispose() {
    _stopped = true;
    _reconnect?.cancel();
    try {
      _client?.disconnect();
    } catch (_) {
      // Nothing useful to do if the socket is already gone.
    }
  }
}
