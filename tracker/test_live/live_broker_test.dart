// Checks this app against a REAL broker carrying REAL Pi output.
//
// Not part of the normal suite: it needs a broker and a running Pi server, so it
// lives outside test/ and is run explicitly.
//
//   flutter test test_live/live_broker_test.dart                 # config defaults
//   BROKER_HOST=127.0.0.1 BROKER_PORT=18830 BROKER_USER= BROKER_PASS= \
//     flutter test test_live/live_broker_test.dart               # local broker
//
// Unit tests pin the payload against a fixture; this catches the case where the
// server's real output has drifted away from that fixture.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:tracker/config.dart';
import 'package:tracker/models.dart';

void main() {
  final env = Platform.environment;
  final host = env['BROKER_HOST'] ?? Config.mqttHost;
  final port = int.tryParse(env['BROKER_PORT'] ?? '') ?? Config.mqttPort;
  final user = env['BROKER_USER'] ?? Config.mqttUsername;
  final pass = env['BROKER_PASS'] ?? Config.mqttPassword;

  test('live broker delivers parseable snapshot and config', () async {
    final client = MqttServerClient.withPort(
        host, 'verify-${DateTime.now().millisecondsSinceEpoch}', port);
    client.logging(on: false);
    client.keepAlivePeriod = 30;

    await client.connect(user.isEmpty ? null : user, pass);
    expect(client.connectionStatus?.state, MqttConnectionState.connected,
        reason: 'could not reach the broker at $host:$port');

    client.subscribe(Config.topicBuses, MqttQos.atMostOnce);
    client.subscribe(Config.topicConfig, MqttQos.atMostOnce);

    final seen = <String>{};
    Map<String, dynamic>? config;
    var tracked = <BusPosition>[];
    var snapshotRetained = false;
    final done = Completer<void>();

    client.updates?.listen((events) {
      for (final event in events) {
        final msg = event.payload;
        if (msg is! MqttPublishMessage) continue;
        final body = jsonDecode(
                MqttPublishPayload.bytesToStringAsString(msg.payload.message))
            as Map<String, dynamic>;

        if (event.topic == Config.topicConfig) {
          config = body;
          seen.add('config');
        } else if (event.topic == Config.topicBuses) {
          snapshotRetained = msg.header?.retain ?? false;
          tracked = [
            for (final e in body['buses'] as List)
              ?BusPosition.fromLive(e as Map<String, dynamic>)
          ];
          seen.add('buses');
        }
        if (seen.length == 2 && !done.isCompleted) done.complete();
      }
    });

    await done.future.timeout(const Duration(seconds: 20),
        onTimeout: () => fail('timed out waiting for topics; saw $seen'));

    // Retained is the whole reason the app needs no initial fetch.
    expect(snapshotRetained, isTrue,
        reason: 'live topics must be retained so a phone gets state on connect');

    expect((config!['stops'] as List), isNotEmpty);
    expect((config!['routes'] as List), isNotEmpty);
    expect(config!['version'], isA<String>());

    for (final bus in tracked) {
      expect(bus.lat, inInclusiveRange(Config.boundsSouth, Config.boundsNorth));
      expect(bus.lng, inInclusiveRange(Config.boundsWest, Config.boundsEast));
      expect(bus.serverStatus, isIn(['live', 'delayed', 'stale', 'offline']));
      if (bus.nextStop != null) expect(bus.etaSec, isNotNull);
      stdout.writeln('  ${bus.busId}: route=${bus.routeId} '
          'status=${bus.serverStatus} next=${bus.nextStop} eta=${bus.etaSec}s');
    }

    client.disconnect();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
