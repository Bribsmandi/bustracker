import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:publisher/uploader.dart';

/// The wire contract from HARDWARE.md.
///
/// The expected signature below was produced independently by `openssl dgst`
/// and by Python's `hmac`, both agreeing — so this pins the Dart implementation
/// against what the relay will actually compute, not against itself.
const _referenceBody =
    '{"b":"bus1","d":"esp32-01","c":1,"lat":11.3185,"lng":75.9379,'
    '"spd":6.4,"hdg":312}';
const _referenceSecret = 'YOUR_SECRET_HERE';
const _referenceSig =
    'd0d9d4c131e5b25c618be70720948ae790b564804543d6f8a743a88716567e39';

void main() {
  group('signing', () {
    test('matches the reference signature from HARDWARE.md §7', () {
      expect(Uploader.sign(_referenceBody, _referenceSecret), _referenceSig);
    });

    test('a single changed byte changes the signature', () {
      final tampered = _referenceBody.replaceFirst('11.3185', '11.3186');
      expect(Uploader.sign(tampered, _referenceSecret),
          isNot(equals(_referenceSig)));
    });

    test('a different secret changes the signature', () {
      expect(Uploader.sign(_referenceBody, 'other-secret'),
          isNot(equals(_referenceSig)));
    });
  });

  group('body construction', () {
    test('signs to a value the relay independently computes', () {
      // Dart renders a double heading as "312.0" where the doc example writes
      // "312". That is fine: the relay verifies the HMAC over the exact bytes it
      // received and then parses them, so any valid JSON rendering works. What
      // must hold is that Python computes the same digest over OUR bytes — this
      // expected value came from `openssl dgst` and Python's `hmac`, agreeing.
      const dartBody = '{"b":"bus1","d":"esp32-01","c":1,"lat":11.3185,'
          '"lng":75.9379,"spd":6.4,"hdg":312.0}';
      const dartSig =
          '08de558686d1b0f2e9a4d0d363f616b53b797555f8f7c5c81d9b7729c0e821f5';

      final body = Uploader.buildBody(
        busId: 'bus1',
        deviceId: 'esp32-01',
        counter: 1,
        lat: 11.3185,
        lng: 75.9379,
        speedMps: 6.4,
        headingDeg: 312,
      );
      expect(body, dartBody);
      expect(Uploader.sign(body, _referenceSecret), dartSig);
    });

    test('key order is stable, because the signature covers these bytes', () {
      final body = Uploader.buildBody(
        busId: 'bus2',
        deviceId: 'esp32-02',
        counter: 99,
        lat: 11.0,
        lng: 75.0,
      );
      expect(body.indexOf('"b"'), lessThan(body.indexOf('"d"')));
      expect(body.indexOf('"d"'), lessThan(body.indexOf('"c"')));
      expect(body.indexOf('"c"'), lessThan(body.indexOf('"lat"')));
      expect(body.indexOf('"lat"'), lessThan(body.indexOf('"lng"')));
      expect(body.indexOf('"lng"'), lessThan(body.indexOf('"spd"')));
      expect(body.indexOf('"spd"'), lessThan(body.indexOf('"hdg"')));
    });

    test('unknown heading is sent as null, never 0', () {
      final body = Uploader.buildBody(
        busId: 'bus1',
        deviceId: 'esp32-01',
        counter: 1,
        lat: 11.3185,
        lng: 75.9379,
        speedMps: 0,
      );
      expect(jsonDecode(body)['hdg'], isNull);
      expect(body, contains('"hdg":null'));
    });

    test('coordinates are trimmed to 6 decimals, as the spec allows', () {
      final body = Uploader.buildBody(
        busId: 'bus1',
        deviceId: 'esp32-01',
        counter: 1,
        lat: 11.31851234567,
        lng: 75.93794999999,
      );
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      expect(decoded['lat'], 11.318512);
      expect(decoded['lng'], 75.93795);
    });

    test('speed defaults to 0 rather than null when the GPS has none', () {
      final body = Uploader.buildBody(
        busId: 'bus1',
        deviceId: 'esp32-01',
        counter: 1,
        lat: 11.3185,
        lng: 75.9379,
      );
      expect(jsonDecode(body)['spd'], 0.0);
    });
  });

  group('relay responses', () {
    test('403 is fatal — a config error retrying will never fix', () {
      expect(const UploadResult(403, false, 'bad signature').isFatal, isTrue);
      expect(const UploadResult(403, false, 'wrong bus').isFatal, isTrue);
    });

    test('a replay or an outage is not fatal', () {
      expect(const UploadResult(409, false, 'replay').isFatal, isFalse);
      expect(const UploadResult(502, false, 'upstream down').isFatal, isFalse);
      expect(const UploadResult(0, false, 'no route to host').isFatal, isFalse);
    });

    test('describe is readable for each documented outcome', () {
      expect(const UploadResult(200, true).describe(), 'Accepted');
      expect(const UploadResult(409, false, 'replay').describe(), '409 replay');
      expect(const UploadResult(0, false, 'timeout').describe(),
          'No network: timeout');
    });
  });
}
