import 'dart:math' as math;

import 'geo.dart';

/// Adds up distance driven from a stream of position fixes. Prefers road-snapped
/// positions from navigation, and uses raw GPS only when those stop arriving.
class DistanceTracker {
  DistanceTracker({required this.onDistance, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// GPS jitter while parked must not drain the estimate.
  static const _minStepKm = 0.02;

  /// A longer jump than this between fixes is a glitch or a gap, not driving.
  static const _maxPlausibleKmh = 200.0;
  static const _snappedGoesStaleAfter = Duration(seconds: 10);

  /// Distance since the last fix, and the speed over it when the time is known.
  final void Function(double km, double? kmh) onDistance;
  final DateTime Function() _clock;
  GeoPoint? _last;
  DateTime? _lastTime;
  DateTime? _lastSnappedTime;

  void addSnappedFix(GeoPoint point) {
    _lastSnappedTime = _clock();
    _add(point);
  }

  void addGpsFix(GeoPoint point) {
    final snapped = _lastSnappedTime;
    if (snapped != null && _clock().difference(snapped) < _snappedGoesStaleAfter) return;
    _add(point);
  }

  void _add(GeoPoint point) {
    final now = _clock();
    final last = _last, lastTime = _lastTime;
    if (last == null || lastTime == null) {
      _last = point;
      _lastTime = now;
      return;
    }
    final km = distanceKm(last, point);
    if (km < _minStepKm) return;
    final hours = now.difference(lastTime).inMilliseconds / 3600000;
    // Allow 1 km of slack for fixes that arrive in a burst.
    if (km <= _maxPlausibleKmh * hours + 1) {
      onDistance(km, hours > 0 ? math.min(km / hours, _maxPlausibleKmh) : null);
    }
    _last = point;
    _lastTime = now;
  }
}
