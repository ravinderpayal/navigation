import 'dart:math' as math;

import 'charger.dart';
import 'energy.dart';
import 'geo.dart';
import 'live_status.dart';
import 'route_profile.dart';

/// All the tuning numbers for stop planning.
class PlannerRules {
  const PlannerRules();

  /// Aim to reach a charger with about this much left.
  final double reserveSoc = 25;

  /// Chargers are shown on the map once the estimate drops below this.
  final double showChargersBelowSoc = 50;

  /// Never plan to arrive anywhere below this, unless already below it.
  final double hardFloorSoc = 20;

  /// When nothing is reachable above the floor, the closest charger still beats
  /// running flat, so it's planned with a warning, down to this.
  final double emergencyFloorSoc = 3;

  /// A free charger reached with up to this much left beats paying later.
  final double earliestStopSoc = 45;

  /// Before paying, a free charger is worth stopping at with up to this much left.
  /// Beyond it, the stop adds little range for the time it costs.
  final double earliestFreeStopSoc = 55;

  final double chargeToSoc = 80;

  /// Maximum extra km driven, there and back, to use a free charger.
  final double maxDetourOpenRoadKm = 15;
  final double maxDetourCityKm = 6;

  /// Slower than this for a whole route step (free-flow) counts as city driving.
  final double cityBelowKmh = 45;

  /// Roads wind: this converts straight-line distance to a road distance guess.
  final double roadWindingFactor = 1.3;

  /// Below this a "stop" takes hours, so the charger is not a route option.
  final double minUsefulDcKw = 20;

  /// Chargers this powerful come first when available and right on the road.
  final double ultraFastKw = 180;

  /// "On the road": at most this many extra km there and back.
  final double ultraFastMaxDetourKm = 3;

  /// A short stop that doubles as a break: at least this powerful, and this long.
  final double topUpMinKw = 60;
  final int topUpMinMinutes = 5;
  final int topUpMaxMinutes = 10;

  /// A top-up adds at least this much range, or what the destination needs.
  final double topUpExtraKm = 20;

  /// Parking, connecting the charger and leaving: about 3 + 2 + 3 minutes.
  final int stopOverheadMinutes = 8;

  /// On a long trip, arrive with this much so there's no hunt for a charger in
  /// city traffic straight after. Short trips just keep the reserve.
  final double longTripArrivalSoc = 55;
  final double longTripKm = 100;

  double destinationSocFor(double tripKm) => tripKm >= longTripKm ? longTripArrivalSoc : reserveSoc;

  /// Charging power assumed for a charger that doesn't list one.
  final double unlistedChargerKw = 50;

  /// A minute saved at the charger is worth this much driving, in km: highway pace.
  final double kmPerMinuteSaved = 1.5;

  final double otherChargerSearchRadiusKm = 10;

  /// A busy charger may free up if the car is at least this far away in time.
  final int busyOkIfMinutesAway = 15;

  /// Scoring, in km-equivalents: worth driving this much further from the ideal
  /// spot for a charger the network confirms, and this much to avoid one it says
  /// is down, which still gets a closer look since that includes merely busy ones.
  final double confirmedChargerBonusKm = 15;
  final double reportedDownPenaltyKm = 40;

  double detourLimitKm(RouteProfile route, double km) =>
      route.isSlowAt(km) ? maxDetourCityKm : maxDetourOpenRoadKm;
}

/// A charger placed relative to a route.
class RouteCharger {
  const RouteCharger({required this.charger, required this.alongKm, required this.detourKm});
  final Charger charger;
  final double alongKm;

  /// Extra km driven to use it, there and back.
  final double detourKm;
}

enum StopKind {
  /// Charge to 80%, or what the rest of the trip needs.
  full,

  /// A few minutes, mid-trip, for just enough range. Also a break.
  topUp,
}

class ChargeStop {
  const ChargeStop({
    required this.place,
    required this.arrivalSoc,
    required this.departureSoc,
    required this.chargeMinutes,
    required this.detourVerified,
    this.kind = StopKind.full,
    this.belowFloor = false,
  });
  final RouteCharger place;
  final double arrivalSoc;
  final double departureSoc;
  final int chargeMinutes;

  /// True when [RouteCharger.detourKm] came from a real road route, not a guess.
  final bool detourVerified;
  final StopKind kind;

  /// Nothing was reachable above the safe floor, so this arrives below it.
  final bool belowFloor;
}

class ChargePlan {
  const ChargePlan({required this.stops, required this.arrivalSoc, this.strandedAtKm});
  final List<ChargeStop> stops;

  /// Estimated charge on reaching the destination.
  final double arrivalSoc;

  /// Set when no charger could be found: where the car reaches its reserve.
  final double? strandedAtKm;
}

/// Finds non-free chargers near a point.
typedef OtherChargerSearch = Future<List<Charger>> Function(GeoPoint near, double radiusKm);

/// Returns the real extra km for a charger, or null when that can't be checked.
typedef DetourCheck = Future<double?> Function(RouteProfile route, RouteCharger place);

/// Finds chargers of at least the given power along a route.
typedef FastChargerSearch = Future<List<Charger>> Function(RouteProfile route);

class ChargePlanner {
  ChargePlanner({
    required List<Charger> freeChargers,
    required this.searchOtherChargers,
    required this.checkDetour,
    this.searchUltraFast,
    this.live,
    this.rules = const PlannerRules(),
  }) : _freeChargers = freeChargers.where((c) => c.dcKw >= rules.minUsefulDcKw).toList();

  static const _maxStops = 12;
  /// Straight-line distance misleads badly near expressways and rivers, so many
  /// close-looking chargers fail a real road check. Keep looking before paying.
  static const _maxChecksPerStop = 12;

  static const _maxOtherChargerChecks = 5;
  static const _maxUltraFastChecks = 8;
  static const _maxTopUpChecks = 8;
  static const _arrivalToleranceSoc = 0.5;

  /// Searching for a top-up charger only pays off when a common fast charger
  /// could add enough in time.
  static const _topUpSearchKw = 120.0;

  /// Stops after the first must move the trip on, not recharge at the same spot.
  static const _minProgressKm = 20.0;

  final List<Charger> _freeChargers;
  final OtherChargerSearch searchOtherChargers;
  final DetourCheck checkDetour;
  final FastChargerSearch? searchUltraFast;
  final LiveStatusSource? live;
  final PlannerRules rules;

  // Road distances don't change with the plan, so replanning the same route
  // (for a new cruising speed, say) doesn't ask Google again.
  RouteProfile? _detourRoute;
  final Map<String, double> _detours = {};

  Future<double?> _realDetour(RouteProfile route, RouteCharger place) async {
    if (!identical(_detourRoute, route)) {
      _detourRoute = route;
      _detours.clear();
    }
    final known = _detours[place.charger.id];
    if (known != null) return known;
    final km = await checkDetour(route, place);
    if (km != null) _detours[place.charger.id] = km;
    return km;
  }

  /// Free chargers within the detour limits to show on the map, in route order.
  /// Leaves out any the network reports as down.
  List<RouteCharger> freeChargersOnRoute(RouteProfile route) {
    final shown = <RouteCharger>[];
    for (final place in chargersOnRoute(route)) {
      switch (_statusOf(place.charger)) {
        case LiveStatus.unavailable:
          break;
        case LiveStatus.available:
          shown.add(_withNote(place, 'Available now'));
        case LiveStatus.unknown:
          shown.add(place);
      }
    }
    return shown;
  }

  LiveStatus _statusOf(Charger charger) => live?.statusOf(charger) ?? LiveStatus.unknown;

  RouteCharger _withNote(RouteCharger place, String? note) => RouteCharger(
        charger: place.charger.withAvailabilityNote(note),
        alongKm: place.alongKm,
        detourKm: place.detourKm,
      );

  /// Statiq only reveals a station's power with its details.
  RouteCharger _withLiveDetails(RouteCharger place, StationCheck check, String? note) => RouteCharger(
        charger: place.charger.withAvailabilityNote(note, dcKw: place.charger.dcKw > 0 ? null : check.kw),
        alongKm: place.alongKm,
        detourKm: place.detourKm,
      );

  /// All free chargers within the detour limits, whatever their live status.
  List<RouteCharger> chargersOnRoute(RouteProfile route) {
    final found = <RouteCharger>[];
    for (final charger in _freeChargers) {
      final projection = route.projectNearby(charger.position);
      if (projection == null) continue;
      final detour = projection.offRouteKm * 2 * rules.roadWindingFactor;
      if (detour <= rules.detourLimitKm(route, projection.alongKm)) {
        found.add(RouteCharger(charger: charger, alongKm: projection.alongKm, detourKm: detour));
      }
    }
    found.sort((a, b) => a.alongKm.compareTo(b.alongKm));
    return found;
  }

  /// Chargers of [PlannerRules.ultraFastKw] or more right on the road, from the
  /// free list and the search, in route order. Leaves out any reported down.
  Future<List<RouteCharger>> ultraFastOnRoute(RouteProfile route) async {
    final byId = <String, Charger>{
      for (final c in _freeChargers)
        if (c.dcKw >= rules.ultraFastKw) c.id: c,
    };
    try {
      for (final c in await searchUltraFast?.call(route) ?? const <Charger>[]) {
        if (c.dcKw >= rules.ultraFastKw) byId.putIfAbsent(c.id, () => c);
      }
    } catch (_) {
      // The free list's fast chargers still count.
    }
    final found = <RouteCharger>[];
    for (final charger in byId.values) {
      final projection = route.projectNearby(charger.position);
      if (projection == null) continue;
      final detour = projection.offRouteKm * 2 * rules.roadWindingFactor;
      if (detour > rules.ultraFastMaxDetourKm) continue;
      final place = RouteCharger(charger: charger, alongKm: projection.alongKm, detourKm: detour);
      switch (_statusOf(charger)) {
        case LiveStatus.unavailable:
          break;
        case LiveStatus.available:
          found.add(_withNote(place, 'Available now'));
        case LiveStatus.unknown:
          found.add(place);
      }
    }
    found.sort((a, b) => a.alongKm.compareTo(b.alongKm));
    return found;
  }

  Future<ChargePlan> plan({
    required RouteProfile route,
    required double fromKm,
    required double soc,
    required EnergyModel energy,
    double? destinationSoc,
  }) async {
    final arriveWith = destinationSoc ?? rules.reserveSoc;
    // 55% already leaves room; the reserve gets a little on top.
    final margin = arriveWith > rules.reserveSoc ? 0.0 : 5.0;
    final corridor = chargersOnRoute(route);
    final ultraFast = await ultraFastOnRoute(route);
    final stops = <ChargeStop>[];
    var km = fromKm;
    var currentSoc = soc;

    while (stops.length < _maxStops) {
      final socNeededForRest = route.socUsed(km, route.totalKm, energy);
      final arrival = currentSoc - socNeededForRest;
      // A stop charges to exactly what's needed, so allow for rounding.
      if (arrival >= arriveWith - _arrivalToleranceSoc) {
        return ChargePlan(stops: stops, arrivalSoc: arrival);
      }

      final targetKm = route.kmAfterSoc(km, math.max(0.0, currentSoc - rules.reserveSoc), energy);
      // Already at or under the floor: anything reachable will do.
      final floor = currentSoc > rules.hardFloorSoc ? rules.hardFloorSoc : 3.0;
      double kmAtSoc(double level) => route.kmAfterSoc(km, math.max(0.0, currentSoc - level), energy);
      final soonestPossibleKm = stops.isEmpty ? km : km + _minProgressKm;
      final earliestKm = math.max(soonestPossibleKm, kmAtSoc(rules.earliestStopSoc));
      final latestKm = kmAtSoc(floor);

      final soonestKm = math.max(soonestPossibleKm, kmAtSoc(rules.earliestFreeStopSoc));

      // Just short of the destination: a few minutes mid-trip does it.
      final topUp = await _pickTopUp(route, corridor, ultraFast, stops, arriveWith - arrival,
          soonestPossibleKm, latestKm, km, currentSoc, floor, energy);
      if (topUp != null) {
        stops.add(topUp);
        km = topUp.place.alongKm;
        currentSoc = topUp.departureSoc - topUp.place.detourKm / 2 * energy.socPerKm;
        continue;
      }

      var choice = await _pickUltraFast(route, ultraFast, stops, targetKm, soonestKm, latestKm,
              km, currentSoc, floor, energy) ??
          await _pickFree(route, corridor, stops, targetKm, earliestKm, latestKm,
              km, currentSoc, floor, energy) ??
          // Stopping with plenty of charge left still beats paying.
          await _pickFree(route, corridor, stops, targetKm, soonestKm, earliestKm,
              km, currentSoc, floor, energy) ??
          await _pickOther(route, stops, targetKm, km, currentSoc, floor, energy);
      var belowFloor = false;
      if (choice == null && floor > rules.emergencyFloorSoc) {
        // Nothing above the floor. Arriving low still beats running flat.
        final emergency = rules.emergencyFloorSoc;
        choice = await _pickFree(route, corridor, stops, latestKm, latestKm, kmAtSoc(emergency),
                km, currentSoc, emergency, energy) ??
            await _pickOther(route, stops, targetKm, km, currentSoc, emergency, energy);
        belowFloor = choice != null;
      }
      if (choice == null) {
        return ChargePlan(stops: stops, arrivalSoc: arrival, strandedAtKm: targetKm);
      }

      final place = choice.place;
      final arrivalSoc = _arrivalSoc(route, energy, currentSoc, km, place.alongKm, place.detourKm);
      // Stop as briefly as possible when the rest of the trip doesn't need 80%.
      // Includes driving back to the route from the charger.
      final socForRest = route.socUsed(place.alongKm, route.totalKm, energy) +
          place.detourKm / 2 * energy.socPerKm +
          arriveWith +
          margin;
      final departureSoc = math.max(arrivalSoc, math.min(rules.chargeToSoc, socForRest));
      stops.add(ChargeStop(
        place: place,
        arrivalSoc: arrivalSoc,
        departureSoc: departureSoc,
        chargeMinutes: _chargeMinutes(arrivalSoc, departureSoc, place.charger.dcKw, energy),
        detourVerified: choice.verified,
        belowFloor: belowFloor && arrivalSoc < rules.hardFloorSoc,
      ));
      km = place.alongKm;
      currentSoc = departureSoc - place.detourKm / 2 * energy.socPerKm;
    }
    return ChargePlan(
        stops: stops, arrivalSoc: currentSoc - route.socUsed(km, route.totalKm, energy));
  }

  double _arrivalSoc(RouteProfile route, EnergyModel energy, double soc, double fromKm, double toKm, double detourKm) =>
      soc - route.socUsed(fromKm, toKm, energy) - detourKm / 2 * energy.socPerKm;

  /// An available charger of 180 kW or more right on the road, reachable at the
  /// current rate of use. Status must be confirmed: it's chosen for being quick.
  Future<_Choice?> _pickUltraFast(
    RouteProfile route,
    List<RouteCharger> ultraFast,
    List<ChargeStop> used,
    double targetKm,
    double earliestKm,
    double latestKm,
    double km,
    double soc,
    double floor,
    EnergyModel energy,
  ) async {
    final options = ultraFast.where((c) {
      if (c.alongKm < earliestKm || c.alongKm > latestKm) return false;
      if (used.any((s) => s.place.charger.id == c.charger.id)) return false;
      return _arrivalSoc(route, energy, soc, km, c.alongKm, c.detourKm) >= floor;
    }).toList()
      ..sort((a, b) => _score(a, targetKm, energy).compareTo(_score(b, targetKm, energy)));

    for (final option in options.take(_maxUltraFastChecks)) {
      final confirmed = await _confirmAvailable(option);
      if (confirmed == null) continue;
      final realDetour = await _realDetour(route, confirmed);
      if (realDetour != null && realDetour > rules.ultraFastMaxDetourKm) continue;
      final detour = realDetour ?? confirmed.detourKm;
      if (_arrivalSoc(route, energy, soc, km, confirmed.alongKm, detour) < floor) continue;
      return _Choice(
        RouteCharger(charger: confirmed.charger, alongKm: confirmed.alongKm, detourKm: detour),
        verified: realDetour != null,
      );
    }
    return null;
  }

  /// Only a charger known to have a free gun now. Busy or unknown isn't enough.
  Future<RouteCharger?> _confirmAvailable(RouteCharger place) async {
    final check = await live?.check(place.charger);
    if (check != null) {
      return check.state == StationState.free ? _withLiveDetails(place, check, check.note) : null;
    }
    if ((place.charger.freeGuns ?? 0) > 0) return place;
    return _statusOf(place.charger) == LiveStatus.available ? place : null;
  }

  /// A short stop near the middle of what's left, when [arrival] at the
  /// destination is short by what a fast charger adds in a few minutes.
  Future<ChargeStop?> _pickTopUp(
    RouteProfile route,
    List<RouteCharger> corridor,
    List<RouteCharger> ultraFast,
    List<ChargeStop> used,
    double shortSoc,
    double earliestKm,
    double latestKm,
    double km,
    double soc,
    double floor,
    EnergyModel energy,
  ) async {
    final addSoc = math.max(shortSoc, rules.topUpExtraKm * energy.socPerKm);
    final midKm = math.min(km + (route.totalKm - km) / 2, latestKm);
    final midSoc = soc - route.socUsed(km, midKm, energy);
    // Even the fastest charger the car can use takes too long: a full stop it is.
    if (energy.chargeMinutes(midSoc, midSoc + addSoc, double.infinity) > rules.topUpMaxMinutes) return null;

    final pool = <String, RouteCharger>{
      for (final c in [...ultraFast, ...corridor])
        if (c.charger.dcKw >= rules.topUpMinKw) c.charger.id: c,
    };
    bool fits(RouteCharger c) {
      if (c.alongKm < earliestKm || c.alongKm > latestKm) return false;
      if (used.any((s) => s.place.charger.id == c.charger.id)) return false;
      final arrivalSoc = _arrivalSoc(route, energy, soc, km, c.alongKm, c.detourKm);
      if (arrivalSoc < floor) return false;
      return energy.chargeMinutes(arrivalSoc, arrivalSoc + addSoc + c.detourKm * energy.socPerKm,
              c.charger.dcKw) <=
          rules.topUpMaxMinutes;
    }

    final options = pool.values.where(fits).toList();
    final searchWorthIt =
        energy.chargeMinutes(midSoc, midSoc + addSoc, _topUpSearchKw) <= rules.topUpMaxMinutes;
    if (options.isEmpty && searchWorthIt) {
      try {
        for (final charger in await searchOtherChargers(route.pointAt(midKm), rules.otherChargerSearchRadiusKm)) {
          if (charger.dcKw < rules.topUpMinKw) continue;
          final projection = route.project(charger.position, fromKm: km);
          final place = RouteCharger(
              charger: charger,
              alongKm: projection.alongKm,
              detourKm: projection.offRouteKm * 2 * rules.roadWindingFactor);
          if (place.detourKm <= rules.detourLimitKm(route, place.alongKm) && fits(place)) options.add(place);
        }
      } catch (_) {
        return null;
      }
    }
    // A free charger is worth a little more driving, as everywhere else.
    double topUpScore(RouteCharger c) => _score(c, midKm, energy) - (c.charger.isFree ? 10 : 0);
    options.sort((a, b) => topUpScore(a).compareTo(topUpScore(b)));

    for (final option in options.take(_maxTopUpChecks)) {
      final confirmed = await _confirmLive(route, option, km);
      if (confirmed == null) continue;
      final realDetour = await _realDetour(route, confirmed);
      if (realDetour != null && realDetour > rules.detourLimitKm(route, confirmed.alongKm)) continue;
      final detour = realDetour ?? confirmed.detourKm;
      final arrivalSoc = _arrivalSoc(route, energy, soc, km, confirmed.alongKm, detour);
      if (arrivalSoc < floor) continue;
      final kw = confirmed.charger.dcKw;
      final needed =
          energy.chargeMinutes(arrivalSoc, arrivalSoc + addSoc + detour * energy.socPerKm, kw).ceil();
      if (needed > rules.topUpMaxMinutes) continue;
      final minutes = math.max(rules.topUpMinMinutes, needed);
      return ChargeStop(
        place: RouteCharger(charger: confirmed.charger, alongKm: confirmed.alongKm, detourKm: detour),
        arrivalSoc: arrivalSoc,
        departureSoc: energy.socAfterCharging(arrivalSoc, minutes.toDouble(), kw, maxSoc: rules.chargeToSoc),
        chargeMinutes: minutes,
        detourVerified: realDetour != null,
        kind: StopKind.topUp,
      );
    }
    return null;
  }

  Future<_Choice?> _pickFree(
    RouteProfile route,
    List<RouteCharger> corridor,
    List<ChargeStop> used,
    double targetKm,
    double earliestKm,
    double latestKm,
    double km,
    double soc,
    double floor,
    EnergyModel energy,
  ) async {
    final options = corridor.where((c) {
      if (c.alongKm < earliestKm || c.alongKm > latestKm) return false;
      if (used.any((s) => s.place.charger.id == c.charger.id)) return false;
      return _arrivalSoc(route, energy, soc, km, c.alongKm, c.detourKm) >= floor;
    }).toList()
      ..sort((a, b) => _score(a, targetKm, energy).compareTo(_score(b, targetKm, energy)));

    for (final option in options.take(_maxChecksPerStop)) {
      final confirmed = await _confirmLive(route, option, km);
      if (confirmed == null) continue;
      final realDetour = await _realDetour(route, confirmed);
      if (realDetour == null) return _Choice(confirmed, verified: false);
      if (realDetour > rules.detourLimitKm(route, confirmed.alongKm)) continue;
      if (_arrivalSoc(route, energy, soc, km, confirmed.alongKm, realDetour) < floor) continue;
      return _Choice(
        RouteCharger(charger: confirmed.charger, alongKm: confirmed.alongKm, detourKm: realDetour),
        verified: true,
      );
    }
    return null;
  }

  /// Asks the network about one charger just before suggesting it. Returns it with
  /// its live note, or null if it shouldn't be suggested.
  Future<RouteCharger?> _confirmLive(RouteProfile route, RouteCharger place, double km) async {
    final source = live;
    if (source == null) return place;
    final check = await source.check(place.charger);
    if (check == null) {
      // A failed check can't clear a charger already reported as down.
      return _statusOf(place.charger) == LiveStatus.unavailable ? null : place;
    }
    switch (check.state) {
      case StationState.free:
        return _withLiveDetails(place, check, check.note);
      case StationState.dead:
        return null;
      case StationState.busy:
        final minutes = route.secondsBetween(km, place.alongKm) ~/ 60;
        if (minutes < rules.busyOkIfMinutesAway) return null;
        return _withLiveDetails(place, check, '${check.note}, $minutes min away');
    }
  }

  Future<_Choice?> _pickOther(RouteProfile route, List<ChargeStop> used, double targetKm, double km,
      double soc, double floor, EnergyModel energy) async {
    // Each stop must move the trip on, as with free chargers.
    final soonestKm = used.isEmpty ? km : km + _minProgressKm;
    // Nothing at the target? Try a little past it, then further back along the
    // route, because earlier is always safe.
    _Choice? leastBad;
    for (final offsetKm in const [0.0, 20.0, -20.0, -40.0, -60.0, -80.0, -100.0, -120.0]) {
      final searchKm = targetKm + offsetKm;
      if (searchKm < km) break;
      final results =
          await searchOtherChargers(route.pointAt(searchKm), rules.otherChargerSearchRadiusKm);
      final options = <RouteCharger>[];
      for (final charger in results) {
        if (used.any((s) => s.place.charger.id == charger.id)) continue;
        final projection = route.project(charger.position, fromKm: km);
        if (projection.alongKm < soonestKm) continue;
        final detour = projection.offRouteKm * 2 * rules.roadWindingFactor;
        if (_arrivalSoc(route, energy, soc, km, projection.alongKm, detour) < floor) continue;
        options.add(RouteCharger(charger: charger, alongKm: projection.alongKm, detourKm: detour));
      }
      options.sort((a, b) => _score(a, targetKm, energy).compareTo(_score(b, targetKm, energy)));
      for (final candidate in options.take(_maxOtherChargerChecks)) {
        final option = await _confirmLive(route, candidate, km);
        if (option == null) continue;
        final realDetour = await _realDetour(route, option);
        if (realDetour == null) return _Choice(option, verified: false);
        if (_arrivalSoc(route, energy, soc, km, option.alongKm, realDetour) < floor) continue;
        final choice = _Choice(
          RouteCharger(charger: option.charger, alongKm: option.alongKm, detourKm: realDetour),
          verified: true,
        );
        if (realDetour <= rules.detourLimitKm(route, option.alongKm)) return choice;
        if (leastBad == null || realDetour < leastBad.place.detourKm) leastBad = choice;
      }
    }
    // No charger is close by road, but a long detour beats being stranded.
    return leastBad;
  }

  /// Lower is better, in km-equivalents: how far from the 25% point, plus half
  /// the detour, plus the time slow charging costs, adjusted for live status.
  /// A 60 kW charger saves about 45 minutes over a 30 kW one, worth stopping
  /// about 70 km away from the ideal spot, within the reachable window.
  double _score(RouteCharger c, double targetKm, EnergyModel energy) {
    final base = (c.alongKm - targetKm).abs() + c.detourKm * 0.5 + _slowChargingKm(c.charger, energy);
    return switch (_statusOf(c.charger)) {
      LiveStatus.available => base - rules.confirmedChargerBonusKm,
      LiveStatus.unavailable => base + rules.reportedDownPenaltyKm,
      LiveStatus.unknown => base,
    };
  }

  /// Minutes lost charging here compared with a charger the car can't outpace,
  /// as the km that much driving would cover. A 30 kW charger loses about an hour
  /// against a fast one for a normal stop.
  double _slowChargingKm(Charger charger, EnergyModel energy) {
    final kw = charger.dcKw > 0 ? charger.dcKw : rules.unlistedChargerKw;
    final lost = energy.chargeMinutes(rules.reserveSoc, rules.chargeToSoc, kw) -
        energy.chargeMinutes(rules.reserveSoc, rules.chargeToSoc, double.infinity);
    return lost * rules.kmPerMinuteSaved;
  }

  int _chargeMinutes(double fromSoc, double toSoc, double dcKw, EnergyModel energy) =>
      energy.chargeMinutes(fromSoc, toSoc, dcKw > 0 ? dcKw : rules.unlistedChargerKw).ceil();
}

class _Choice {
  const _Choice(this.place, {required this.verified});
  final RouteCharger place;
  final bool verified;
}
