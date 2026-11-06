import '../core/charger.dart';
import '../core/live_status.dart';
import '../core/route_profile.dart';
import 'statiq_service.dart';

/// One view of charger health across every source, and the monitor that keeps the
/// stations around the expected charging point up to date.
class LiveStatusHub extends LiveStatusSource {
  LiveStatusHub({required this.feed, required this.statiq, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  /// A station is checked before use if its last result is older than this.
  static const _recheckAfter = Duration(minutes: 2);

  /// Older results than this are no longer trusted.
  static const _maxAge = Duration(minutes: 10);
  static const _checksAtOnce = 4;

  /// Stations further than this from the route aren't worth watching.
  static const _maxOffRouteKm = 6.0;
  static const _maxWatched = 30;
  static const _minWatched = 5;

  final LiveStatusSource feed;
  final StatiqService statiq;
  final DateTime Function() _clock;

  List<LiveStation> _stations = const [];
  final Map<String, String> _statiqIdForCharger = {};
  List<Charger> _statiqOnly = const [];
  final Map<String, _Result> _results = {};
  Set<String> _watched = const {};
  final Map<RouteProfile, List<_RouteStation>> _onRoute = {};

  /// Statiq stations that aren't on the free list, as chargers.
  List<Charger> get statiqOnlyChargers => _statiqOnly;

  /// Statiq-only stations whose checks found at least [minKw]. Statiq gives
  /// power only with a station's details, so this grows as stations are checked.
  List<Charger> statiqOnlyAtLeast(double minKw) => [
        for (final c in _statiqOnly)
          if ((_results[c.id.substring('statiq:'.length)]?.check.kw ?? 0) >= minKw)
            c.withAvailabilityNote(null, dcKw: _results[c.id.substring('statiq:'.length)]!.check.kw),
      ];

  /// Links stations to the free list. One free-list charger takes at most one
  /// station, so the same site is never listed twice while several Statiq ids at
  /// one address stay as the separate chargers they are.
  void setStatiqStations(List<LiveStation> stations, List<Charger> freeChargers) {
    _stations = stations;
    _statiqIdForCharger.clear();
    _onRoute.clear();
    final matcher = StationMatcher(stations);
    final linked = <String>{};
    for (final charger in freeChargers) {
      final station = matcher.match(charger);
      if (station != null) {
        _statiqIdForCharger[charger.id] = station.id;
        linked.add(station.id);
      }
    }
    _statiqOnly = [
      for (final s in stations)
        if (!linked.contains(s.id))
          Charger(
            id: 'statiq:${s.id}',
            name: s.name,
            address: s.address,
            position: s.position,
            dcKw: 0, // Comes with the station's details.
            source: ChargerSource.statiq,
          ),
    ];
  }

  String? _statiqIdOf(Charger charger) => charger.id.startsWith('statiq:')
      ? charger.id.substring('statiq:'.length)
      : _statiqIdForCharger[charger.id];

  @override
  bool canCheck(Charger charger) => _statiqIdOf(charger) != null || feed.canCheck(charger);

  @override
  LiveStatus statusOf(Charger charger) {
    final id = _statiqIdOf(charger);
    final result = id == null ? null : _results[id];
    if (result != null && _age(result) < _maxAge) {
      return result.check.state == StationState.free ? LiveStatus.available : LiveStatus.unavailable;
    }
    return feed.statusOf(charger);
  }

  @override
  Future<StationCheck?> check(Charger charger) async {
    final id = _statiqIdOf(charger);
    if (id == null) return feed.check(charger);
    final known = _results[id];
    if (known != null && _age(known) < _recheckAfter) return _withAge(known);
    final fresh = await _checkStation(id);
    if (fresh != null) return _withAge(fresh);
    if (known != null && _age(known) < _maxAge) return _withAge(known);
    return feed.check(charger);
  }

  Duration _age(_Result r) => _clock().difference(r.time);

  Future<_Result?> _checkStation(String id) async {
    final check = await statiq.check(id);
    if (check == null) return null;
    return _results[id] = _Result(check, _clock());
  }

  StationCheck _withAge(_Result r) {
    final minutes = _age(r).inMinutes;
    final checked = minutes < 1 ? 'Checked just now' : 'Checked $minutes min ago';
    final used = r.check.healthNote;
    return StationCheck(
      r.check.state,
      note: r.check.note,
      freeGuns: r.check.freeGuns,
      totalGuns: r.check.totalGuns,
      kw: r.check.kw,
      healthNote: used == null ? checked : '$used · $checked',
    );
  }

  List<_RouteStation> _stationsOn(RouteProfile route) => _onRoute.putIfAbsent(route, () {
        final found = <_RouteStation>[];
        for (final station in _stations) {
          final projection = route.projectNearby(station.position);
          if (projection != null && projection.offRouteKm <= _maxOffRouteKm) {
            found.add(_RouteStation(station.id, projection.alongKm));
          }
        }
        return found;
      });

  /// Chooses the stations to monitor: those within [rangeKm] of a point on the route,
  /// and still ahead of the car. On a bare stretch, where the driver most needs to
  /// know, it falls back to the nearest stations instead of watching nothing.
  void watchAround(RouteProfile route, double km, double rangeKm, {double fromKm = 0}) {
    final ahead = _stationsOn(route).where((s) => s.alongKm >= fromKm).toList()
      ..sort((a, b) => (a.alongKm - km).abs().compareTo((b.alongKm - km).abs()));
    final inRange = ahead.where((s) => (s.alongKm - km).abs() <= rangeKm).toList();
    final chosen = inRange.length >= _minWatched ? inRange : ahead.take(_minWatched);
    _watched = chosen.take(_maxWatched).map((s) => s.id).toSet();
  }

  void stopWatching() => _watched = const {};

  int get watchedCount => _watched.length;

  /// How many monitored stations have a recent result.
  int get checkedWatchedCount => _watched.where((id) {
        final result = _results[id];
        return result != null && _age(result) < _maxAge;
      }).length;

  /// How many monitored stations last looked usable.
  int get healthyWatchedCount => _watched.where((id) {
        final result = _results[id];
        return result != null && _age(result) < _maxAge && result.check.state != StationState.dead;
      }).length;

  /// Checks monitored stations, in small groups to go easy on the server.
  /// [onlyDue] skips stations checked within the last couple of minutes.
  Future<void> checkWatched({bool onlyDue = false}) async {
    final ids = _watched.where((id) {
      final known = _results[id];
      return !onlyDue || known == null || _age(known) >= _recheckAfter;
    }).toList();
    for (var i = 0; i < ids.length; i += _checksAtOnce) {
      await Future.wait(ids.skip(i).take(_checksAtOnce).map(_checkStation));
    }
  }
}

class _Result {
  const _Result(this.check, this.time);
  final StationCheck check;
  final DateTime time;
}

class _RouteStation {
  const _RouteStation(this.id, this.alongKm);
  final String id;
  final double alongKm;
}

/// Removes results that are another source's listing of a site already known.
List<Charger> withoutDuplicates(List<Charger> candidates, Iterable<Charger> known) {
  final matcher = StationMatcher([
    for (final c in candidates)
      LiveStation(id: c.id, name: c.name, position: c.position, available: true),
  ]);
  final duplicates = <String>{};
  for (final charger in known) {
    final match = matcher.match(charger);
    if (match != null) duplicates.add(match.id);
  }
  return candidates.where((c) => !duplicates.contains(c.id)).toList();
}
