/// App-wide configuration for the campus bus tracker.
class Config {
  static const String supabaseUrl = 'https://hlnelrsletdunynfiaxv.supabase.co';
  static const String supabaseAnonKey =
      'sb_publishable_tOLEHKUH5RpLqUL0NQ64HQ_4JBVplhr';

  /// A bus whose latest position is older than this is treated as offline.
  static const Duration staleAfter = Duration(minutes: 5);

  /// How often to re-fetch every bus position from the server, independently of
  /// the realtime subscription. Guards against a silently dropped socket.
  static const Duration resyncInterval = Duration(seconds: 30);

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
