import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// Outcome of one publish, mirroring the relay's documented responses.
class UploadResult {
  final int status;
  final bool ok;
  final String? reason;

  const UploadResult(this.status, this.ok, [this.reason]);

  /// A signature or binding failure is a configuration problem, not a blip:
  /// retrying identical requests will never start working.
  bool get isFatal => status == 403;

  String describe() {
    if (ok) return 'Accepted';
    if (status == 0) return 'No network: $reason';
    return '$status ${reason ?? ''}'.trim();
  }
}

/// Signs and posts positions exactly as the ESP32 firmware does.
///
/// The signature is over the precise bytes transmitted. The body is built once,
/// signed, and that same string is sent — re-serialising in between changes the
/// hash and is the usual cause of a rejected signature (HARDWARE.md §5).
class Uploader {
  static const _counterKey = 'publisher_counter';

  final HttpClient _http = HttpClient()
    ..connectionTimeout = Config.requestTimeout
    // Keep one socket open. Reconnecting every 5 s multiplies data use and power
    // draw for no benefit (HARDWARE.md §6.2).
    ..idleTimeout = const Duration(seconds: 60);

  int _counter = 0;
  SharedPreferences? _prefs;

  /// The counter must increase forever, per device, across restarts — otherwise
  /// the relay rejects everything as a replay until it climbs past the old high
  /// water mark. Seeding from wall-clock seconds gives that for free, and the
  /// stored value guards against a clock that jumps backwards.
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final stored = _prefs?.getInt(_counterKey) ?? 0;
    final fromClock = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _counter = fromClock > stored ? fromClock : stored + 1;
  }

  int get counter => _counter;

  /// Builds the exact JSON the relay will verify. Key order is part of the
  /// contract: the signature covers these bytes, so it must not be rebuilt
  /// anywhere else with a different ordering.
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
      // Metres per second, never km/h or knots (HARDWARE.md §8).
      'spd': speedMps == null ? 0.0 : double.parse(speedMps.toStringAsFixed(2)),
      // null, never 0: zero means due north and would point every parked bus
      // the same wrong way on the map.
      'hdg': headingDeg,
    });
  }

  /// X-Sig = hex(HMAC_SHA256(secret, exact_body_bytes)).
  static String sign(String raw, String secret) =>
      Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(raw)).toString();

  Future<UploadResult> publish({
    required String busId,
    required double lat,
    required double lng,
    double? speedMps,
    double? headingDeg,
  }) async {
    _counter++;
    // Persist before sending: a crash mid-request must not let the counter be
    // reused, which would look like a replay.
    await _prefs?.setInt(_counterKey, _counter);

    final raw = buildBody(
      busId: busId,
      deviceId: Config.deviceId,
      counter: _counter,
      lat: lat,
      lng: lng,
      speedMps: speedMps,
      headingDeg: headingDeg,
    );
    final sig = sign(raw, Config.deviceSecret);

    try {
      final req = await _http
          .postUrl(Uri.parse(Config.relayUrl))
          .timeout(Config.requestTimeout);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      req.headers.set('X-Sig', sig);
      req.persistentConnection = true;
      req.add(utf8.encode(raw));

      final resp = await req.close().timeout(Config.requestTimeout);
      final text = await resp.transform(utf8.decoder).join();

      bool ok = false;
      String? reason;
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          ok = decoded['ok'] == true;
          reason = decoded['reason'] as String?;
        }
      } catch (_) {
        reason = text.isEmpty ? null : text;
      }
      return UploadResult(resp.statusCode, ok && resp.statusCode == 200, reason);
    } catch (e) {
      // A dead spot is an ordinary event on campus, not an error worth stopping
      // for. The fix is dropped; the next one will be fresher anyway.
      return UploadResult(0, false, '$e');
    }
  }

  Future<bool> checkHealth() async {
    try {
      final req = await _http.getUrl(Uri.parse(Config.healthUrl));
      final resp = await req.close().timeout(Config.requestTimeout);
      final text = await resp.transform(utf8.decoder).join();
      return resp.statusCode == 200 && jsonDecode(text)['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  void dispose() => _http.close(force: true);
}
