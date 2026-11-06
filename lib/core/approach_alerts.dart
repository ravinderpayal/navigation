import 'dart:math' as math;

import 'charge_planner.dart';

class DriverAlert {
  const DriverAlert(this.message, {required this.urgent});
  final String message;

  /// Urgent alerts sound twice and vibrate longer.
  final bool urgent;
}

/// Warns the driver in time to slow down for the charger turn-off, and when the
/// battery nears the floor. Each warning sounds once.
class ApproachAlerts {
  ApproachAlerts({this.floorSoc = 20});

  /// Time to slow down, change lanes and find the exit.
  static const _headsUpSeconds = 90;
  static const _urgentSeconds = 30;
  static const _minHeadsUpKm = 1.0;
  static const _minUrgentKm = 0.3;

  /// Used before the car's speed is known.
  static const _assumedKmh = 60.0;

  /// The turn-off comes before the charger's closest point on the route, by up
  /// to the one-way detour. Capped, because long detours rarely leave that early.
  static const _maxExitLeadKm = 2.0;

  /// Past the turn-off by this much, it's been missed. No point warning then.
  static const _missedKm = 0.2;

  /// Warns this far above the floor, so there's time to act.
  static const _lowBatteryMargin = 2.0;

  final double floorSoc;
  final Set<String> _sounded = {};

  /// The alert to give now, if any. [heading] is true when guidance already goes
  /// to [target].
  DriverAlert? check({
    required RouteCharger? target,
    required bool heading,
    required double progressKm,
    required double? speedKmh,
    required double soc,
  }) {
    final stop = target;
    if (stop != null) {
      final alert = _approach(stop, heading, progressKm, speedKmh);
      if (alert != null) return alert;
    }
    return _battery(soc, hasStop: stop != null);
  }

  DriverAlert? _approach(RouteCharger stop, bool heading, double progressKm, double? speedKmh) {
    final exitKm = stop.alongKm - math.min(stop.detourKm / 2, _maxExitLeadKm);
    final kmAway = exitKm - progressKm;
    if (kmAway < -_missedKm) return null;
    final kmh = speedKmh == null || speedKmh < 5 ? _assumedKmh : speedKmh;
    final id = stop.charger.id;
    final where = _distance(kmAway);
    final name = stop.charger.name;

    if (kmAway <= math.max(_minUrgentKm, kmh * _urgentSeconds / 3600)) {
      if (!_sounded.add('$id:urgent')) return null;
      _sounded.add('$id:headsUp');
      return DriverAlert(
        heading
            ? 'Charger turn-off $where. Slow down now.'
            : 'Charger $where: $name. Tap Go now or you will pass it.',
        urgent: true,
      );
    }
    if (kmAway <= math.max(_minHeadsUpKm, kmh * _headsUpSeconds / 3600)) {
      if (!_sounded.add('$id:headsUp')) return null;
      return DriverAlert(
        heading
            ? 'Charger turn-off $where. Start slowing down.'
            : 'Charging stop $where: $name.',
        urgent: false,
      );
    }
    return null;
  }

  DriverAlert? _battery(double soc, {required bool hasStop}) {
    if (soc <= floorSoc && _sounded.add('floor')) {
      _sounded.add('nearFloor');
      return DriverAlert('Battery about ${soc.round()}%, below the ${floorSoc.round()}% safe level. '
          '${hasStop ? 'Charge at the stop ahead.' : 'Charge at the nearest charger.'}', urgent: true);
    }
    if (soc <= floorSoc + _lowBatteryMargin && _sounded.add('nearFloor')) {
      return DriverAlert('Battery about ${soc.round()}%. '
          '${hasStop ? 'Charge at the stop ahead.' : 'Plan to charge soon.'}', urgent: false);
    }
    return null;
  }

  /// A fresh reading or a charge starts the battery warnings over.
  void resetBattery() => _sounded.removeAll(['floor', 'nearFloor']);

  static String _distance(double km) {
    if (km <= 0.05) return 'now';
    if (km < 1) return 'in ${(km * 1000 / 50).round() * 50} m';
    return 'in ${km.toStringAsFixed(1)} km';
  }
}
