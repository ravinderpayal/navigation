import 'dart:math' as math;

import 'air_along_route.dart';
import 'energy.dart';
import 'geo.dart';

/// A part of the route where a long detour is not worth it: slow city roads or
/// live congestion.
class SlowStretch {
  const SlowStretch(this.startKm, this.endKm);
  final double startKm;
  final double endKm;
}

/// How fast traffic flows freely on part of the route.
class SpeedBand {
  const SpeedBand(this.startKm, this.endKm, this.kmh);
  final double startKm;
  final double endKm;
  final double kmh;
}

/// Live congestion on part of the route, as a share of the free-flow speed.
class TrafficBand {
  const TrafficBand(this.startKm, this.endKm, this.speedFactor);
  final double startKm;
  final double endKm;
  final double speedFactor;
}

class RouteProjection {
  const RouteProjection(this.alongKm, this.offRouteKm);
  final double alongKm;
  final double offRouteKm;
}

/// A route geometry with fast "how far along" lookups.
class RouteProfile {
  RouteProfile({
    required List<GeoPoint> points,
    this.slowStretches = const [],
    this.durationSeconds = 0,
    this.routeToken,
    this.encodedPolyline,
    this.speedBands = const [],
    this.trafficBands = const [],
  }) : assert(points.length >= 2) {
    _sample(points);
    _buildKmTables();
  }

  /// Used for timing when the route says nothing about speed.
  static const _fallbackKmh = 50.0;

  static const _sampleEveryKm = 0.5;
  static const _cellDegrees = 0.1;

  final List<SlowStretch> slowStretches;
  final int durationSeconds;
  final String? routeToken;

  /// The geometry as Google sent it, for searches along this route.
  final String? encodedPolyline;
  final List<SpeedBand> speedBands;
  final List<TrafficBand> trafficBands;

  /// Running totals per km of the route, so any stretch can be costed quickly.
  /// Energy is in "80 km/h km": 1 means a km at the car's 80 km/h consumption.
  /// It depends on the car and the weather, so it's built for each car on demand.
  final Map<Object, List<double>> _energyTables = {};
  final List<double> _secondsTable = [0];

  /// Speed and direction for each whole km of the route.
  final List<double?> _kmhPerKm = [];

  /// Legal top speed where the driver picks the pace: open road without
  /// congestion. Null in towns and traffic, where the road sets the pace.
  final List<double?> _openRoadLimitPerKm = [];

  /// Indian limits for cars: 120 km/h on expressways, 100 on national highways.
  static const _expresswayLimitKmh = 120.0;
  static const _highwayLimitKmh = 100.0;
  final List<double> _headingPerKm = [];
  AirAlongRoute? _air;

  /// Weather along the route. Changes the cost of every km.
  AirAlongRoute? get air => _air;
  set air(AirAlongRoute? value) {
    _air = value;
    _energyTables.clear();
  }

  /// Geometry as drawn on the map.
  late final List<GeoPoint> points;
  late final double totalKm;
  final List<GeoPoint> _samples = [];
  final List<double> _sampleKm = [];
  final Map<int, List<int>> _cells = {};

  void _sample(List<GeoPoint> input) {
    points = input;
    var covered = 0.0, nextSample = 0.0;
    for (var i = 1; i < input.length; i++) {
      final a = input[i - 1], b = input[i];
      final length = distanceKm(a, b);
      while (nextSample <= covered + length) {
        final t = length == 0 ? 0.0 : (nextSample - covered) / length;
        _addSample(GeoPoint(a.lat + (b.lat - a.lat) * t, a.lng + (b.lng - a.lng) * t), nextSample);
        nextSample += _sampleEveryKm;
      }
      covered += length;
    }
    totalKm = covered;
    _addSample(input.last, covered);
  }

  void _addSample(GeoPoint point, double km) {
    _cells.putIfAbsent(_cellOf(point.lat, point.lng), () => []).add(_samples.length);
    _samples.add(point);
    _sampleKm.add(km);
  }

  int _cellOf(double lat, double lng) =>
      (lat / _cellDegrees).floor() * 100000 + (lng / _cellDegrees).floor();

  void _buildKmTables() {
    final wholeKm = totalKm.ceil();
    for (var i = 0; i < wholeKm; i++) {
      final length = math.min(i + 1.0, totalKm) - i;
      final kmh = _speedAt(i + length / 2);
      _kmhPerKm.add(kmh);
      _openRoadLimitPerKm.add(_openRoadLimitAt(i + length / 2));
      _headingPerKm.add(bearingDegrees(pointAt(i.toDouble()), pointAt(i + length)));
      _secondsTable.add(_secondsTable.last + length * 3600 / (kmh ?? _fallbackKmh));
    }
    // Keeps the shape from road speeds, and Google's total for the whole trip.
    final predicted = _secondsTable.last;
    if (durationSeconds > 0 && predicted > 0) {
      final scale = durationSeconds / predicted;
      for (var i = 0; i < _secondsTable.length; i++) {
        _secondsTable[i] *= scale;
      }
    }
  }

  List<double> _energyTableFor(EnergyModel energy) => _energyTables.putIfAbsent(energy.curveKey, () {
        final table = [0.0];
        for (var i = 0; i < _kmhPerKm.length; i++) {
          final length = math.min(i + 1.0, totalKm) - i;
          table.add(table.last +
              length * _factorAt(i, _plannedAt(i, energy.cruiseKmh), energy, stopStart: _isStopStart(i)));
        }
        return table;
      });

  double? _openRoadLimitAt(double km) {
    final free = _freeFlowAt(km);
    if (free == null) return null;
    final congested = trafficBands.any((b) => km >= b.startKm && km <= b.endKm);
    if (congested) return null;
    return switch (roadKindFor(free)) {
      RoadKind.expressway => _expresswayLimitKmh,
      RoadKind.highway => _highwayLimitKmh,
      RoadKind.city => null,
    };
  }

  /// Speed for a km of route when cruising at [cruiseKmh]: that, up to the limit,
  /// on open road, and the road's own pace elsewhere. Google's speeds are typical
  /// travel times, and on an expressway they run well below what drivers choose.
  double? _plannedAt(int kmIndex, double? cruiseKmh) {
    final road = _kmhPerKm[kmIndex];
    final limit = _openRoadLimitPerKm[kmIndex];
    if (cruiseKmh == null || limit == null) return road;
    return math.min(cruiseKmh, limit);
  }

  /// Driving time for the whole route cruising at [cruiseKmh], or at the road's
  /// own speeds without one. Unscaled: for comparing speeds.
  double drivingSeconds({double? cruiseKmh}) {
    var seconds = 0.0;
    for (var i = 0; i < _kmhPerKm.length; i++) {
      final length = math.min(i + 1.0, totalKm) - i;
      seconds += length * 3600 / (_plannedAt(i, cruiseKmh) ?? _fallbackKmh);
    }
    return seconds;
  }

  /// Share of the route where the driver sets the pace.
  double get openRoadShare =>
      _openRoadLimitPerKm.isEmpty ? 0 : _openRoadLimitPerKm.where((l) => l != null).length / _openRoadLimitPerKm.length;

  /// Without speed data a km costs what 80 km/h does, in that km's weather.
  double _factorAt(int kmIndex, double? kmh, EnergyModel energy, {bool stopStart = false}) {
    final air = _air?.nearest(pointAt(kmIndex + 0.5));
    final heading = _headingPerKm.isEmpty
        ? 0.0
        : _headingPerKm[kmIndex.clamp(0, _headingPerKm.length - 1)];
    return energy.factorAt(kmh ?? EnergyModel.referenceKmh,
        air: air, headwindKmh: air?.headwindKmh(heading) ?? 0, stopStart: stopStart);
  }

  /// Town roads and traffic mean stopping and starting. Only known from speeds.
  bool _isStopStart(int kmIndex) =>
      kmIndex < _kmhPerKm.length && _kmhPerKm[kmIndex] != null && _openRoadLimitPerKm[kmIndex] == null;

  /// Whether this part of the route is town driving or traffic.
  bool isStopStartAt(double km) => _isStopStart(km.clamp(0.0, math.max(0.0, totalKm - 1e-9)).floor());

  double? _freeFlowAt(double km) {
    for (final band in speedBands) {
      if (km >= band.startKm && km <= band.endKm) return band.kmh;
    }
    return null;
  }

  double? _speedAt(double km) {
    final free = _freeFlowAt(km);
    if (free == null) return null;
    for (final band in trafficBands) {
      if (km >= band.startKm && km <= band.endKm) return free * band.speedFactor;
    }
    return free;
  }

  double _tableValue(List<double> table, double km) {
    final clamped = km.clamp(0.0, totalKm);
    final i = math.min(clamped.floor(), table.length - 2);
    final length = math.min(i + 1.0, totalKm) - i;
    return table[i] + (table[i + 1] - table[i]) * (length == 0 ? 0 : (clamped - i) / length);
  }

  /// Battery used driving between two points on the route. Beyond the end of the
  /// route, it assumes the 80 km/h consumption.
  double socUsed(double fromKm, double toKm, EnergyModel energy) {
    final table = _energyTableFor(energy);
    final beyond = math.max(0.0, toKm - totalKm) - math.max(0.0, fromKm - totalKm);
    return (_tableValue(table, toKm) - _tableValue(table, fromKm) + beyond) * energy.socPerKm;
  }

  /// Where the car will be after using [soc] percent of battery from [fromKm].
  /// Can be past the end of the route.
  double kmAfterSoc(double fromKm, double soc, EnergyModel energy) {
    final table = _energyTableFor(energy);
    final target = _tableValue(table, fromKm) + soc / energy.socPerKm;
    final end = table.last;
    if (target >= end) return totalKm + (target - end);
    var low = 0, high = table.length - 1;
    while (high - low > 1) {
      final mid = (low + high) ~/ 2;
      if (table[mid] <= target) {
        low = mid;
      } else {
        high = mid;
      }
    }
    final length = math.min(low + 1.0, totalKm) - low;
    return low + length * (target - table[low]) / (table[high] - table[low]);
  }

  /// Predicted driving time between two points on the route.
  double secondsBetween(double fromKm, double toKm) =>
      _tableValue(_secondsTable, toKm) - _tableValue(_secondsTable, fromKm);

  /// How this part of the route compares with the 80 km/h figure, as predicted,
  /// or steady at [kmh] when the car's real speed is known. Real stops are
  /// measured as they happen, so they're not added to a real speed.
  double energyFactorAt(double km, EnergyModel energy, {double? kmh}) {
    final index = km.clamp(0.0, math.max(0.0, totalKm - 1e-9)).floor();
    if (kmh != null) return _factorAt(index, kmh, energy);
    return _factorAt(index, _plannedAt(math.min(index, _kmhPerKm.length - 1), energy.cruiseKmh), energy,
        stopStart: _isStopStart(index));
  }

  /// The weather at a point on the route, when known.
  AirConditions? airAt(double km) => _air?.nearest(pointAt(km));

  RoadKind? roadKindAt(double km) {
    final kmh = _freeFlowAt(km);
    return kmh == null ? null : roadKindFor(kmh);
  }

  bool isSlowAt(double km) => slowStretches.any((s) => km >= s.startKm && km <= s.endKm);

  GeoPoint pointAt(double km) {
    final index = (km.clamp(0.0, totalKm) / _sampleEveryKm).round();
    return _samples[math.min(index, _samples.length - 1)];
  }

  /// The closest route position, only searching about 10 km around [point].
  /// Null when the route does not pass nearby. Cheap enough to run per charger.
  RouteProjection? projectNearby(GeoPoint point) {
    final row = (point.lat / _cellDegrees).floor();
    final col = (point.lng / _cellDegrees).floor();
    int? best;
    var bestKm = double.infinity;
    for (var r = row - 1; r <= row + 1; r++) {
      for (var c = col - 1; c <= col + 1; c++) {
        for (final i in _cells[r * 100000 + c] ?? const <int>[]) {
          final d = distanceKm(point, _samples[i]);
          if (d < bestKm) {
            bestKm = d;
            best = i;
          }
        }
      }
    }
    return best == null ? null : RouteProjection(_sampleKm[best], bestKm);
  }

  /// The closest route position, however far away. For occasional single lookups.
  /// [fromKm] ignores the part of the route already driven.
  RouteProjection project(GeoPoint point, {double fromKm = 0}) {
    var best = 0;
    var bestKm = double.infinity;
    for (var i = 0; i < _samples.length; i++) {
      if (_sampleKm[i] < fromKm) continue;
      final d = distanceKm(point, _samples[i]);
      if (d < bestKm) {
        bestKm = d;
        best = i;
      }
    }
    return RouteProjection(_sampleKm[best], bestKm);
  }
}
