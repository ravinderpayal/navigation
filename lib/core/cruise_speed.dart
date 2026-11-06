import 'dart:math' as math;

import 'energy.dart';
import 'route_profile.dart';

/// What a trip costs at one cruising speed.
class CruiseOption {
  const CruiseOption({
    required this.kmh,
    required this.driveMinutes,
    required this.chargeMinutes,
    required this.stops,
    required this.socUsed,
  });

  /// Never faster than this. Slower stretches stay at the road's own speed.
  final double kmh;
  final double driveMinutes;

  /// Charging plus parking, connecting and leaving at each stop.
  final double chargeMinutes;
  final int stops;

  /// Battery used driving the whole route, in %.
  final double socUsed;

  double get totalMinutes => driveMinutes + chargeMinutes;
}

class CruiseAdvice {
  const CruiseAdvice({required this.best, required this.fastest, required this.options});
  final CruiseOption best;

  /// The fastest speed tried, for comparison.
  final CruiseOption fastest;
  final List<CruiseOption> options;

  /// False when cruising slower than the road allows doesn't pay on this trip.
  bool get slowerPays => best.kmh < fastest.kmh;
}

/// Finds the cruising speed that gets to the destination soonest, counting the
/// charging that faster driving makes necessary.
///
/// Air drag grows with the square of speed, so each extra km/h costs more battery
/// than the last, and that battery has to be charged back, slowly once the car is
/// past 75%. At some speed the minutes saved driving are lost again at the charger.
class CruiseAdvisor {
  /// Indian expressways allow 120 km/h for cars, national highways 100.
  static const speeds = [70.0, 75.0, 80.0, 85.0, 90.0, 95.0, 100.0, 105.0, 110.0, 115.0, 120.0];

  /// Within this many minutes of the quickest counts as a tie. The slower speed
  /// wins: the same time with more charge in hand.
  static const tieMinutes = 1.0;

  static CruiseAdvice advise({
    required RouteProfile route,
    required double startSoc,
    required EnergyModel energy,
    required double arriveWith,
    required double chargerKw,
    required double reserveSoc,
    required double chargeToSoc,
    required int stopOverheadMinutes,
  }) {
    final options = [
      for (final kmh in speeds)
        _option(route, startSoc, energy.withCruise(kmh), arriveWith, chargerKw, reserveSoc, chargeToSoc,
            stopOverheadMinutes),
    ];
    final quickest = options.map((o) => o.totalMinutes).reduce(math.min);
    final best = options.firstWhere((o) => o.totalMinutes <= quickest + tieMinutes);
    return CruiseAdvice(best: best, fastest: options.last, options: options);
  }

  /// Charging is costed as stops from the reserve up to [chargeToSoc], where the
  /// charging curve is still kind, as many as the trip needs.
  static CruiseOption _option(RouteProfile route, double startSoc, EnergyModel energy, double arriveWith,
      double chargerKw, double reserveSoc, double chargeToSoc, int overhead) {
    final kmh = energy.cruiseKmh!;
    final used = route.socUsed(0, route.totalKm, energy);
    var needed = arriveWith + used - startSoc;
    var chargeMinutes = 0.0;
    var stops = 0;
    final perStop = chargeToSoc - reserveSoc;
    while (needed > 0) {
      final add = math.min(needed, perStop);
      chargeMinutes += energy.chargeMinutes(reserveSoc, reserveSoc + add, chargerKw) + overhead;
      stops++;
      needed -= add;
    }
    return CruiseOption(
      kmh: kmh,
      driveMinutes: route.drivingSeconds(cruiseKmh: kmh) / 60,
      chargeMinutes: chargeMinutes,
      stops: stops,
      socUsed: used,
    );
  }
}
