/// Configuration for the bus GPS publisher.
///
/// This app is a stand-in for the ESP32 units: it publishes the same signed
/// payload, to the same MQTT topic, as the firmware does. It exists so the
/// chain (broker → Raspberry Pi → tracker app) can be exercised from a laptop
/// or a phone before touching hardware, and to record real GPS traces.
///
/// It is a development and field-test tool, not something students install.
class Config {
  // ---------------------------------------------------------------- transport

  /// A public broker, because nothing in this system can accept an inbound
  /// connection: the buses are on cellular NAT and the Pi is on a phone
  /// hotspot. Everything dials out to a common meeting point instead.
  ///
  /// Free and unauthenticated — which is exactly why every fix is signed.
  static const String mqttHost =
      String.fromEnvironment('BUS_MQTT_HOST', defaultValue: 'broker.emqx.io');
  static const int mqttPort =
      int.fromEnvironment('BUS_MQTT_PORT', defaultValue: 1883);

  /// Root for every topic. Deliberately unguessable: on a shared public broker
  /// a generic name collides with other people's traffic. Hygiene, not security
  /// — it must match the Pi's BUS_TOPIC_ROOT.
  static const String topicRoot =
      String.fromEnvironment('BUS_TOPIC_ROOT', defaultValue: 'cbt7f3c9e21b');

  static String gpsTopic(String busId) => '$topicRoot/bus/$busId/gps';
  static String statusTopic(String busId) => '$topicRoot/bus/$busId/status';

  // ----------------------------------------------------------------- identity

  /// Device identity, issued per unit and registered in the Pi's devices.json.
  /// A device is bound to exactly one bus; publishing as another is rejected.
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

  // ------------------------------------------------------------------ timing

  /// How often to sample and publish GPS.
  ///
  /// Derived, not chosen (HARDWARE.md §6.1): the bus must record at least two
  /// fixes inside the server's 40 m stop radius or it can pass through without
  /// registering an arrival. It is inside that circle for an 80 m chord, so the
  /// interval must satisfy T <= 40 / speed. At 5 s that holds up to 28.8 km/h.
  static const Duration fixInterval = Duration(seconds: 5);

  /// Keep publishing while the bus is stationary, so the server sees it as
  /// parked-and-running rather than gone.
  static const Duration heartbeat = Duration(seconds: 5);

  /// MQTT keepalive. Long enough to be cheap on 2G, short enough that a dead
  /// connection is noticed within a broadcast cycle.
  static const int keepAliveSeconds = 60;

  static const Duration reconnectDelay = Duration(seconds: 3);
}
