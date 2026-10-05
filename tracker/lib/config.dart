/// App-wide configuration for the campus bus tracker.
class Config {
  // ---------------------------------------------------------------- transport

  /// A public MQTT broker. Nothing in this system can accept an inbound
  /// connection — the buses are on cellular NAT and the Pi on a phone hotspot —
  /// so every party dials out to a common meeting point instead.
  ///
  /// Overridable at build time:
  ///
  ///     flutter build apk --release \
  ///       --dart-define=BUS_MQTT_HOST=broker.emqx.io \
  ///       --dart-define=BUS_TOPIC_ROOT=<must match the Pi>
  static const String mqttHost =
      String.fromEnvironment('BUS_MQTT_HOST', defaultValue: 'broker.emqx.io');
  static const int mqttPort = int.fromEnvironment('BUS_MQTT_PORT', defaultValue: 1883);

  /// Port for MQTT-over-WebSocket, used by Flutter web and by mobile networks
  /// that only allow 443.
  static const int mqttWsPort = 9001;
  static const bool useWebSocket = false;

  /// The public broker takes no credentials. Left configurable so a private
  /// broker with authentication can be swapped in without a code change.
  static const String mqttUsername =
      String.fromEnvironment('BUS_MQTT_USERNAME', defaultValue: '');
  static const String mqttPassword =
      String.fromEnvironment('BUS_MQTT_PASSWORD', defaultValue: '');

  /// Root for every topic. Deliberately unguessable: on a shared public broker
  /// a generic name collides with other people's traffic. Hygiene, not security
  /// — it must match the Pi's BUS_TOPIC_ROOT.
  static const String topicRoot =
      String.fromEnvironment('BUS_TOPIC_ROOT', defaultValue: 'campus_arund');

  /// Topics published by the Pi. All retained, so the current state arrives the
  /// moment we subscribe.
  static const String topicBuses = '$topicRoot/live/buses';
  static const String topicConfig = '$topicRoot/live/config';
  static const String topicServer = '$topicRoot/live/server';
  static String topicStop(String stopId) => '$topicRoot/live/stop/$stopId';

  /// How long a snapshot stays trustworthy without a fresh one arriving.
  ///
  /// This is the safeguard against retained messages. Every live topic is
  /// retained so the app has state the instant it connects — but a retained
  /// message outlives the server that published it, and its `status` field is
  /// frozen at publish time. A snapshot saying "live" therefore proves nothing
  /// on its own. The server republishes at least every 10 s, so silence for
  /// appreciably longer than that means it is gone, whatever the payload says.
  static const Duration serverSilentAfter = Duration(seconds: 35);

  /// REST base URL, for the things pub/sub is the wrong shape for: trip
  /// planning and analytics. Empty disables them and the app falls back to its
  /// own on-device planner.
  static const String apiBaseUrl = 'http://127.0.0.1:8000';

  /// How long to wait before retrying a dropped broker connection.
  static const Duration reconnectDelay = Duration(seconds: 3);

  // ------------------------------------------------------------------ tuning

  /// A bus whose latest position is older than this is treated as offline.
  ///
  /// The server sends an authoritative `status` with every snapshot, so this is
  /// only a fallback for when we have not heard from the server at all. It is
  /// sized for the hardware's 5 s reporting interval.
  static const Duration staleAfter = Duration(seconds: 120);

  /// Below this GPS speed (m/s) the bus is considered stopped/waiting, and we
  /// fall back to the printed timetable + average speed for ETAs.
  static const double stoppedSpeedMps = 0.8;

  /// Campus-wide average speed used when a bus is waiting at a terminal and we
  /// only have scheduled departure times to work from. (~18 km/h)
  static const double avgSpeedMps = 5.0;

  /// A bus within this distance (metres) of a terminal stop is treated as
  /// "waiting at" that terminal.
  static const double atTerminalRadiusM = 40.0;

  /// Fallback wait at a terminal before a bus sets off again, used only when
  /// the timetable has no departure left for that bus and route today.
  static const int terminalDwellSec = 180;

  /// The exact extent of every stop and surveyed path coordinate: ~760 m x
  /// ~935 m. Used to frame the map when it opens.
  static const double contentSouth = 11.314827;
  static const double contentWest = 75.930985;
  static const double contentNorth = 11.323224;
  static const double contentEast = 75.937940;

  /// How far the map may be panned: the content extent plus 250 m of margin.
  ///
  /// This limits the map CENTRE, not the camera edges. Constraining the edges
  /// (CameraConstraint.contain) fails hard whenever the viewport is larger than
  /// the box — its constrain() returns null and flutter_map renders nothing at
  /// all. Since a phone viewport at low zoom is easily wider than a 1.3 km box,
  /// centre-clamping is the only form that cannot blank the map.
  static const double boundsSouth = 11.312581;
  static const double boundsWest = 75.928695;
  static const double boundsNorth = 11.325470;
  static const double boundsEast = 75.940230;

  /// At zoom 16 a typical phone shows ~965 m across, which frames the campus
  /// almost exactly. Lower zooms only add surrounding town.
  static const double minZoom = 16;
  static const double maxZoom = 19;

  /// OpenStreetMap tile endpoint (no API key required).
  static const String osmTileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String userAgentPackageName = 'com.campusbus.tracker';
}
