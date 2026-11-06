import 'dart:math' as math;

import 'charge_planner.dart';
import 'charger.dart';
import 'energy.dart';
import 'geo.dart';
import 'live_status.dart';
import 'route_profile.dart';

/// The stack-rank weights for the charger picker, and how it's built.
class RankingRules {
  const RankingRules();

  final double free = 0.4;
  final double statusNotAvailable = -0.5;
  final double greatRestaurant = 0.35;
  final double kw100Plus = 0.4;
  final double kw60Plus = 0.2;

  /// Chargers this close together are one stop, as far as a driver is concerned.
  final double collocatedKm = 0.15;

  /// Below this the car may not make it, so the option isn't offered.
  final double minArrivalSoc = 3;

  final double chargeToSoc = 80;
  final int maxListed = 12;

  /// Limits requests to the status server per opening of the list.
  final int maxStationChecks = 24;
  final int stationChecksAtOnce = 4;

  /// Limits road-distance requests to Google per opening of the list.
  final int maxDetourChecks = 24;

  double powerPoints(double kw) => kw >= 100 ? kw100Plus : (kw >= 60 ? kw60Plus : 0);
}

class Restaurant {
  const Restaurant({required this.name, required this.rating, required this.ratingCount});
  final String name;
  final double rating;
  final int ratingCount;
}

enum SiteStatus { available, busy, notChecked }

/// One stop in the list: a single charger or several collocated ones merged.
class ChargerSite {
  const ChargerSite({
    required this.primary,
    required this.otherChargers,
    required this.isFree,
    required this.kw,
    required this.totalGuns,
    required this.freeGuns,
    required this.allGunsKnown,
    required this.status,
    required this.arrivalSoc,
    required this.chargeMinutes,
    required this.score,
    required this.isSuggested,
    this.isPriority = false,
    this.restaurant,
    this.healthNote,
  });

  /// Where to navigate: the best charger at this stop.
  final RouteCharger primary;
  final int otherChargers;
  final bool isFree;
  final double kw;
  final int totalGuns;
  final int freeGuns;

  /// False when the free count covers only some of the guns.
  final bool allGunsKnown;
  final SiteStatus status;
  final double arrivalSoc;

  /// Null when the power rating isn't known or no charge is needed.
  final int? chargeMinutes;
  final double score;
  final bool isSuggested;

  /// 180 kW or more, free to use now, on the road and reachable above the floor.
  /// Listed above everything else, whatever the score.
  final bool isPriority;
  final Restaurant? restaurant;

  /// When it was last used and checked, for sources that report that.
  final String? healthNote;
}

class ChargerOptions {
  const ChargerOptions(this.sites, {required this.done});
  final List<ChargerSite> sites;

  /// False while live status and restaurants are still loading.
  final bool done;
}

typedef RestaurantLookup = Future<Restaurant?> Function(GeoPoint near);
typedef RouteChargerSearch = Future<List<Charger>> Function(RouteProfile route);

/// Builds the ranked charger list for the picker.
class ChargerOptionsBuilder {
  ChargerOptionsBuilder({
    required this.planner,
    required this.findRestaurant,
    required this.findOtherChargers,
    this.rules = const RankingRules(),
  });

  final ChargePlanner planner;
  final RestaurantLookup findRestaurant;
  final RouteChargerSearch findOtherChargers;
  final RankingRules rules;

  static const _maxSettlingPasses = 4;

  // Reopening the list shouldn't cost more Google requests.
  final Map<String, Restaurant?> _restaurants = {};
  final Map<String, double> _realDetours = {};
  final Set<String> _failedChecks = {};
  RouteProfile? _detoursRoute;
  RouteProfile? _otherChargersRoute;
  List<Charger> _otherChargers = const [];

  /// Emits a first list straight away, then better ones as data arrives.
  /// Without [wantFood], restaurants are neither looked up nor scored.
  Stream<ChargerOptions> load({
    required RouteProfile route,
    required double progressKm,
    required double soc,
    required EnergyModel energy,
    String? suggestedChargerId,
    bool wantFood = true,
  }) async* {
    if (!identical(_detoursRoute, route)) {
      _realDetours.clear();
      _detoursRoute = route;
    }
    var places = planner.chargersOnRoute(route);
    final checks = <String, StationCheck>{};
    List<ChargerSite> rank() => _rank(
        route: route,
        places: places,
        checks: checks,
        progressKm: progressKm,
        soc: soc,
        energy: energy,
        suggestedChargerId: suggestedChargerId,
        wantFood: wantFood);

    yield ChargerOptions(rank().take(rules.maxListed).toList(), done: false);

    places = [...places, ...await _otherChargersOn(route)];
    yield ChargerOptions(rank().take(rules.maxListed).toList(), done: false);

    await _checkStations(route, places, checks, progressKm, soc, energy, suggestedChargerId);
    yield ChargerOptions(rank().take(rules.maxListed).toList(), done: false);

    // Each check can drop rows, moving unchecked ones up into the list.
    var stationChecks = 0, detourChecks = 0;
    for (var pass = 0; pass < _maxSettlingPasses; pass++) {
      final stationsDone = await _checkListedStations(checks, rank, rules.maxListed * 2 - stationChecks);
      final detoursDone = await _checkDetours(route, rank, rules.maxDetourChecks - detourChecks);
      if (stationsDone == 0 && detoursDone == 0) break;
      stationChecks += stationsDone;
      detourChecks += detoursDone;
    }
    yield ChargerOptions(rank().take(rules.maxListed).toList(), done: false);

    if (wantFood) {
      final listed = rank().take(rules.maxListed).toList();
      await Future.wait(listed.map(_loadRestaurant));
    }
    yield ChargerOptions(rank().take(rules.maxListed).toList(), done: true);
  }

  Future<List<RouteCharger>> _otherChargersOn(RouteProfile route) async {
    if (!identical(_otherChargersRoute, route)) {
      try {
        _otherChargers = await findOtherChargers(route);
        _otherChargersRoute = route;
      } catch (_) {
        return const []; // The free chargers can still be listed.
      }
    }
    final found = <RouteCharger>[];
    for (final charger in _otherChargers) {
      final projection = route.project(charger.position);
      final detour = projection.offRouteKm * 2 * planner.rules.roadWindingFactor;
      if (detour <= planner.rules.detourLimitKm(route, projection.alongKm)) {
        found.add(RouteCharger(charger: charger, alongKm: projection.alongKm, detourKm: detour));
      }
    }
    return found;
  }

  /// Checks stations in rank order until the list is settled. Chargers reported
  /// down get checked too, because that also covers ones that are merely in use.
  Future<void> _checkStations(
    RouteProfile route,
    List<RouteCharger> places,
    Map<String, StationCheck> checks,
    double progressKm,
    double soc,
    EnergyModel energy,
    String? suggestedChargerId,
  ) async {
    final live = planner.live;
    if (live == null) return;
    // Nearest the reserve point first. Some sources only reveal power once checked,
    // so power can't be used to choose what to check.
    final ordered = _clusters(_reachable(route, places, progressKm, soc, energy))
      ..sort((a, b) => _distanceToReserve(route, a, progressKm, soc, energy)
          .compareTo(_distanceToReserve(route, b, progressKm, soc, energy)));
    final queue = [
      for (final cluster in ordered)
        for (final place in cluster)
          if (live.canCheck(place.charger)) place.charger,
    ];
    final batch = queue.take(rules.maxStationChecks).toList();
    for (var i = 0; i < batch.length; i += rules.stationChecksAtOnce) {
      final part = batch.skip(i).take(rules.stationChecksAtOnce);
      await Future.wait(part.map((charger) async {
        final check = await live.check(charger);
        if (check != null) checks[charger.id] = check;
      }));
    }
  }

  /// The first pass goes by distance, so what made the list can still be unchecked.
  /// Returns how many requests it made.
  Future<int> _checkListedStations(
      Map<String, StationCheck> checks, List<ChargerSite> Function() rank, int budget) async {
    final live = planner.live;
    if (live == null) return 0;
    var made = 0;
    while (made < budget) {
      final pending = rank()
          .take(rules.maxListed)
          .map((s) => s.primary.charger)
          .where((c) => live.canCheck(c) && !checks.containsKey(c.id) && !_failedChecks.contains(c.id))
          .take(rules.stationChecksAtOnce)
          .toList();
      if (pending.isEmpty) break;
      made += pending.length;
      await Future.wait(pending.map((charger) async {
        final check = await live.check(charger);
        if (check != null) {
          checks[charger.id] = check;
        } else {
          _failedChecks.add(charger.id);
        }
      }));
    }
    _failedChecks.clear();
    return made;
  }

  /// Replaces guessed detours with real road distances for whatever is listed.
  /// Chargers over the limit then drop out, and the next ones move up and get checked.
  /// Returns how many requests it made.
  Future<int> _checkDetours(RouteProfile route, List<ChargerSite> Function() rank, int budget) async {
    var made = 0;
    while (made < budget) {
      final pending = rank()
          .take(rules.maxListed)
          .map((s) => s.primary)
          .where((p) => !_realDetours.containsKey(p.charger.id))
          .take(rules.stationChecksAtOnce)
          .toList();
      if (pending.isEmpty) break;
      made += pending.length;
      await Future.wait(pending.map((place) async {
        // If the check fails, the guess is the best there is.
        _realDetours[place.charger.id] = await planner.checkDetour(route, place) ?? place.detourKm;
      }));
    }
    return made;
  }

  /// Applies known road distances, leaving out chargers they rule out.
  List<RouteCharger> _withRealDetours(RouteProfile route, List<RouteCharger> places) {
    final result = <RouteCharger>[];
    for (final place in places) {
      final real = _realDetours[place.charger.id];
      if (real == null) {
        result.add(place);
      } else if (real <= planner.rules.detourLimitKm(route, place.alongKm)) {
        result.add(RouteCharger(charger: place.charger, alongKm: place.alongKm, detourKm: real));
      }
    }
    return result;
  }

  double _distanceToReserve(RouteProfile route, List<RouteCharger> cluster, double progressKm, double soc, EnergyModel energy) {
    final reserveKm = route.kmAfterSoc(progressKm, math.max(0.0, soc - planner.rules.reserveSoc), energy);
    return (cluster.first.alongKm - reserveKm).abs();
  }

  Future<void> _loadRestaurant(ChargerSite site) async {
    final key = _restaurantKey(site.primary.charger.position);
    if (_restaurants.containsKey(key)) return;
    try {
      _restaurants[key] = await findRestaurant(site.primary.charger.position);
    } catch (_) {
      // Unknown this time. Not cached, so reopening the list tries again.
    }
  }

  String _restaurantKey(GeoPoint p) => '${p.lat.toStringAsFixed(3)},${p.lng.toStringAsFixed(3)}';

  List<RouteCharger> _reachable(RouteProfile route, List<RouteCharger> places, double progressKm, double soc, EnergyModel energy) =>
      places.where((p) {
        if (p.alongKm < progressKm) return false;
        return _arrivalSoc(route, p, progressKm, soc, energy) >= rules.minArrivalSoc;
      }).toList();

  double _arrivalSoc(RouteProfile route, RouteCharger p, double progressKm, double soc, EnergyModel energy) =>
      soc - route.socUsed(progressKm, p.alongKm, energy) - p.detourKm / 2 * energy.socPerKm;

  /// Groups chargers within walking distance. Route order keeps groups stable.
  List<List<RouteCharger>> _clusters(List<RouteCharger> places) {
    final sorted = [...places]..sort((a, b) => a.alongKm.compareTo(b.alongKm));
    final clusters = <List<RouteCharger>>[];
    for (final place in sorted) {
      List<RouteCharger>? home;
      for (final cluster in clusters.reversed) {
        if (place.alongKm - cluster.first.alongKm > rules.collocatedKm * 4) break;
        if (distanceKm(cluster.first.charger.position, place.charger.position) <= rules.collocatedKm) {
          home = cluster;
          break;
        }
      }
      if (home != null) {
        home.add(place);
      } else {
        clusters.add([place]);
      }
    }
    return clusters;
  }

  List<ChargerSite> _rank({
    required RouteProfile route,
    required List<RouteCharger> places,
    required Map<String, StationCheck> checks,
    required double progressKm,
    required double soc,
    required EnergyModel energy,
    String? suggestedChargerId,
    required bool wantFood,
  }) {
    final sites = <ChargerSite>[];
    final known = _withRealDetours(route, places);
    for (final cluster in _clusters(_reachable(route, known, progressKm, soc, energy))) {
      final site = _site(route, cluster, checks, progressKm, soc, energy, suggestedChargerId, wantFood);
      if (site != null) sites.add(site);
    }
    final reserve = planner.rules.reserveSoc;
    sites.sort((a, b) {
      if (a.isPriority != b.isPriority) return a.isPriority ? -1 : 1;
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      // The weights don't separate a free gun from a busy one, but a driver would.
      final aBusy = a.status == SiteStatus.busy, bBusy = b.status == SiteStatus.busy;
      if (aBusy != bBusy) return aBusy ? 1 : -1;
      return (a.arrivalSoc - reserve).abs().compareTo((b.arrivalSoc - reserve).abs());
    });
    return sites;
  }

  /// Null when nothing at this stop is usable.
  ChargerSite? _site(
    RouteProfile route,
    List<RouteCharger> cluster,
    Map<String, StationCheck> checks,
    double progressKm,
    double soc,
    EnergyModel energy,
    String? suggestedChargerId,
    bool wantFood,
  ) {
    final live = planner.live;
    final kept = <RouteCharger>[];
    var totalGuns = 0, freeGuns = 0;
    var allGunsKnown = true;
    var anyAvailable = false, anyBusy = false;
    var kw = 0.0;
    String? healthNote;
    // Google often lists the same site under another name, so its guns only count
    // when no better source knows about this spot.
    final hasBetterSource = cluster.any((p) => p.charger.source != ChargerSource.other);

    for (final place in cluster) {
      final charger = place.charger;
      final reported = live?.statusOf(charger) ?? LiveStatus.unknown;
      final check = checks[charger.id];
      if (check?.state == StationState.dead) continue;
      // Reported down and not looked at yet, so it stays hidden until checked.
      if (reported == LiveStatus.unavailable && check == null) continue;
      kept.add(place);
      kw = math.max(kw, math.max(charger.dcKw, check?.kw ?? 0));
      healthNote ??= check?.healthNote;

      if (charger.source == ChargerSource.other && hasBetterSource) {
        // Counted through the better source.
      } else if (check?.totalGuns != null) {
        totalGuns += check!.totalGuns!;
        freeGuns += check.freeGuns ?? 0;
      } else if (charger.freeGuns != null) {
        totalGuns += charger.dcCount;
        freeGuns += charger.freeGuns!;
      } else {
        totalGuns += charger.dcCount;
        allGunsKnown = false;
      }
      if (check?.state == StationState.free ||
          (check == null && reported == LiveStatus.available) ||
          (charger.freeGuns ?? 0) > 0) {
        anyAvailable = true;
      }
      if (check?.state == StationState.busy) anyBusy = true;
    }
    if (kept.isEmpty) return null;

    // Navigate to the free one if there is one, then the most powerful.
    kept.sort((a, b) {
      if (a.charger.isFree != b.charger.isFree) return a.charger.isFree ? -1 : 1;
      return b.charger.dcKw.compareTo(a.charger.dcKw);
    });
    // Carries the stop's best known power, often only learnt from a live check,
    // so what's shown after choosing it matches the list.
    final best = kept.first;
    final primary = RouteCharger(
      charger: best.charger.withAvailabilityNote(best.charger.availabilityNote, dcKw: kw),
      alongKm: best.alongKm,
      detourKm: best.detourKm,
    );
    final isFree = primary.charger.isFree;
    final status = anyAvailable
        ? SiteStatus.available
        : (anyBusy ? SiteStatus.busy : SiteStatus.notChecked);
    final restaurant = wantFood ? _restaurants[_restaurantKey(primary.charger.position)] : null;
    final arrival = _arrivalSoc(route, primary, progressKm, soc, energy);
    final plannerRules = planner.rules;
    final floor = soc > plannerRules.hardFloorSoc ? plannerRules.hardFloorSoc : plannerRules.emergencyFloorSoc;
    final isPriority = kw >= plannerRules.ultraFastKw &&
        status == SiteStatus.available &&
        primary.detourKm <= plannerRules.ultraFastMaxDetourKm &&
        arrival >= floor;

    return ChargerSite(
      primary: primary,
      otherChargers: kept.length - 1,
      isFree: isFree,
      kw: kw,
      totalGuns: totalGuns,
      freeGuns: freeGuns,
      allGunsKnown: allGunsKnown,
      status: status,
      arrivalSoc: arrival,
      chargeMinutes: _chargeMinutes(arrival, kw, energy),
      restaurant: restaurant,
      healthNote: healthNote,
      isSuggested: suggestedChargerId != null && kept.any((p) => p.charger.id == suggestedChargerId),
      isPriority: isPriority,
      score: (isFree ? rules.free : 0) +
          (status == SiteStatus.notChecked ? rules.statusNotAvailable : 0) +
          (restaurant != null ? rules.greatRestaurant : 0) +
          rules.powerPoints(kw),
    );
  }

  int? _chargeMinutes(double fromSoc, double kw, EnergyModel energy) {
    if (kw <= 0 || fromSoc >= rules.chargeToSoc) return null;
    return energy.chargeMinutes(fromSoc, rules.chargeToSoc, kw).ceil();
  }
}
