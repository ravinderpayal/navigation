import 'energy.dart';
import 'geo.dart';

class AirSample {
  const AirSample(this.position, this.air);
  final GeoPoint position;
  final AirConditions air;
}

/// Weather at points along a trip. Kept by place rather than by route km, so it
/// still applies after a reroute.
class AirAlongRoute {
  AirAlongRoute(this.samples, {DateTime? time}) : time = time ?? DateTime.now();

  final List<AirSample> samples;
  final DateTime time;

  AirConditions? nearest(GeoPoint point) {
    AirConditions? best;
    var bestKm = double.infinity;
    for (final sample in samples) {
      final km = distanceKm(point, sample.position);
      if (km < bestKm) {
        bestKm = km;
        best = sample.air;
      }
    }
    return best;
  }
}
