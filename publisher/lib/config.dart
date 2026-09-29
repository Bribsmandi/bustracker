/// Configuration for the bus GPS publisher.
///
/// This app is a stand-in for the ESP32 units: it speaks the exact wire protocol
/// in HARDWARE.md — a signed plain-HTTP POST to the relay — so the whole chain
/// (relay → MQTT → Raspberry Pi → tracker app) can be exercised with a phone in
/// a real bus before the hardware is fitted, and used to record real GPS traces.
///
/// It is a development and field-test tool, not something students install.
class Config {
  /// The relay endpoint. Unchanged from the old design: the relay still accepts
  /// plain HTTP and still verifies the signature. Only its upstream changed.
  static const String relayHost =
      String.fromEnvironment('BUS_RELAY_HOST', defaultValue: 'recverse.ibinujaleel.dev:8081');

  static String get relayUrl => 'http://$relayHost/p';
  static String get healthUrl => 'http://$relayHost/health';

  /// Device identity, issued per unit and registered in the relay's
  /// devices.json. The relay binds a device to exactly one bus, so publishing as
  /// any other bus is refused with "wrong bus".
  ///
  /// Supplied at build time rather than written here, so a real secret never
  /// enters source control:
  ///
  ///     flutter build apk --release \
  ///       --dart-define=BUS_DEVICE_ID=esp32-01 \
  ///       --dart-define=BUS_DEVICE_SECRET=<32 hex characters>
  ///
  /// The secret never leaves the device — it signs the body and is never sent.
  static const String deviceId =
      String.fromEnvironment('BUS_DEVICE_ID', defaultValue: 'esp32-01');
  static const String deviceSecret =
      String.fromEnvironment('BUS_DEVICE_SECRET', defaultValue: 'SET_BEFORE_BUILDING');

  /// How often to sample and publish GPS.
  ///
  /// Derived, not chosen (HARDWARE.md §6.1): the bus must record at least two
  /// fixes inside the server's 40 m stop radius or it can pass through without
  /// registering an arrival. It is inside that circle for an 80 m chord, so the
  /// interval must satisfy T <= 40 / speed. At 5 s that holds up to 28.8 km/h —
  /// comfortably above campus bus speeds.
  static const Duration fixInterval = Duration(seconds: 5);

  /// Keep publishing while the bus is stationary, so the server sees it as
  /// parked-and-running rather than offline.
  static const Duration heartbeat = Duration(seconds: 5);

  /// Network timeout for one POST. Short: a fix that took longer than the
  /// interval to send is already stale, and the next one is more useful.
  static const Duration requestTimeout = Duration(seconds: 10);
}
