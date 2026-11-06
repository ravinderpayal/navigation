import 'energy.dart';
import 'geo.dart';
import 'route_profile.dart';

/// Where and when the battery is expected to cross a level.
class BatteryForecast {
  const BatteryForecast({
    required this.km,
    required this.position,
    required this.secondsAway,
    required this.roadKind,
  });

  /// Distance along the route.
  final double km;
  final GeoPoint position;
  final int secondsAway;
  final RoadKind? roadKind;
}

/// Null when the battery stays above [level] for the rest of the route.
///
/// [timeScale] corrects the route's predicted time using navigation's live estimate.
BatteryForecast? forecastBatteryLevel({
  required RouteProfile route,
  required double progressKm,
  required double soc,
  required EnergyModel energy,
  required double level,
  double timeScale = 1,
}) {
  final km = soc <= level ? progressKm : route.kmAfterSoc(progressKm, soc - level, energy);
  if (km > route.totalKm) return null;
  return BatteryForecast(
    km: km,
    position: route.pointAt(km),
    secondsAway: (route.secondsBetween(progressKm, km) * timeScale).round(),
    roadKind: route.roadKindAt(km),
  );
}
