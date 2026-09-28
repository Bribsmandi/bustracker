/// Supabase connection details and tuning for the campus bus publisher.
///
/// The publishable ("anon") key is safe to ship in a client app — Row Level
/// Security plus the claim/publish functions control what it can do.
class Config {
  static const String supabaseUrl = 'https://hlnelrsletdunynfiaxv.supabase.co';
  static const String supabaseAnonKey =
      'sb_publishable_tOLEHKUH5RpLqUL0NQ64HQ_4JBVplhr';

  /// How often to push the latest position even when the bus is stationary,
  /// so the tracker never wrongly marks a parked-but-running bus as offline.
  static const Duration heartbeat = Duration(seconds: 12);

  /// Periodic self-check: re-assert our claim on the bus and re-evaluate the
  /// journey state, so a phone that briefly lost network recovers on its own.
  static const Duration recheckInterval = Duration(seconds: 30);

  /// A bus within this many metres of a stop is considered "at" that stop.
  /// Used to log arrival/departure analytics events.
  static const double atStopRadiusM = 40.0;

  /// How often to sample and publish GPS.
  ///
  /// Derived, not chosen: the bus must record at least two fixes inside the
  /// [arriveRadiusM] circle or it can pass through a terminal without ever
  /// registering as parked. It is inside that circle for an 80 m chord, so the
  /// interval must satisfy  T <= 40 / speed.  At 5 s that holds up to
  /// 28.8 km/h — comfortably above campus bus speeds — and yields ~2.3 fixes
  /// per arrival at a typical 25 km/h.
  ///
  /// Going to 6 s drops below two fixes per arrival; going to 3 s costs 66%
  /// more data and battery for no detection benefit.
  static const Duration fixInterval = Duration(seconds: 5);

  // -------------------------------------------------------- parked / departed
  //
  // Both transitions need two independent signals to agree. A stationary phone
  // drifts 5-15 m (worse beside buildings), so distance alone produces false
  // departures; Android's fused speed is unreliable below walking pace, so
  // speed alone produces false parks. Requiring both kills each other's noise.

  /// A bus this close to its destination terminal is a candidate for parking.
  static const double arriveRadiusM = 40.0;

  /// ...and it must also have stayed within [parkedMaxDriftM] over the last
  /// [parkedWindow] before we call it parked.
  static const Duration parkedWindow = Duration(seconds: 30);
  static const double parkedMaxDriftM = 15.0;

  /// Departure: the bus must be this far from where it parked...
  static const double departMinDistanceM = 25.0;

  /// ...AND be moving at least this fast...
  static const double departMinSpeedMps = 2.0;

  /// ...for this many consecutive fixes (~10 s at [fixInterval]).
  static const int departMinConsecutiveFixes = 3;

  /// For terminals that define an explicit return-trigger coordinate in
  /// stops.json (`triggerLat`/`triggerLng`), crossing within this distance of
  /// that point also starts the return trip.
  static const double returnTriggerRadiusM = 20.0;
}
