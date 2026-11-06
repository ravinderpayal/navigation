/// Build-time settings, passed with --dart-define-from-file=config/keys.json.
class AppConfig {
  static const googleApiKey = String.fromEnvironment('MAPS_API_KEY');

  /// Sends Places and Routes calls to a fake server. For testing only.
  static const apiBaseOverride = String.fromEnvironment('API_BASE_OVERRIDE');

  /// Drives the route with the Navigation SDK simulator instead of real GPS.
  static const simulateDrive = bool.fromEnvironment('SIMULATE_DRIVE');

  /// How many times faster than real life a simulated drive goes.
  static const simulationSpeed = int.fromEnvironment('SIMULATION_SPEED', defaultValue: 5);

  static bool get hasApiKey => googleApiKey.isNotEmpty;
}
