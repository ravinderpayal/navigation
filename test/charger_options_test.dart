import 'package:flutter_test/flutter_test.dart';
import 'package:vinfast_copilot/core/charge_planner.dart';
import 'package:vinfast_copilot/core/charger.dart';
import 'package:vinfast_copilot/core/charger_options.dart';
import 'package:vinfast_copilot/core/energy.dart';
import 'package:vinfast_copilot/core/geo.dart';
import 'package:vinfast_copilot/core/live_status.dart';
import 'package:vinfast_copilot/core/route_profile.dart';

const _kmPerDegree = 111.195;
GeoPoint _north(double km) => GeoPoint(10 + km / _kmPerDegree, 77);
const _energy = EnergyModel(kwhPer100Km: 20, batteryKwh: 100); // 0.2 % per km

Charger _at(double km, String id, {double kw = 30, int guns = 2, ChargerSource source = ChargerSource.free, int? free}) =>
    Charger(id: id, name: id, position: _north(km), dcKw: kw, dcCount: guns, source: source, freeGuns: free);

class _Live extends LiveStatusSource {
  _Live({this.status = const {}, this.checks = const {}});
  final Map<String, LiveStatus> status;
  final Map<String, StationCheck> checks;
  int calls = 0;

  @override
  LiveStatus statusOf(Charger c) => status[c.id] ?? LiveStatus.unknown;

  @override
  Future<StationCheck?> check(Charger c) async {
    calls++;
    return checks[c.id];
  }
}

const _freeGuns = StationCheck(StationState.free, freeGuns: 2, totalGuns: 2);

Future<List<ChargerSite>> _sites(
  List<Charger> free, {
  _Live? live,
  List<Charger> other = const [],
  Map<String, Restaurant> restaurants = const {},
  double soc = 70,
  double progressKm = 0,
  String? suggested,
  void Function()? onRestaurant,
  Map<String, double> realDetours = const {},
  bool wantFood = true,
}) async {
  final route = RouteProfile(points: [const GeoPoint(10, 77), _north(800)]);
  final builder = ChargerOptionsBuilder(
    planner: ChargePlanner(
      freeChargers: free,
      live: live,
      searchOtherChargers: (_, _) async => const [],
      checkDetour: (_, place) async => realDetours[place.charger.id],
    ),
    findOtherChargers: (_) async => other,
    findRestaurant: (near) async {
      onRestaurant?.call();
      for (final c in [...free, ...other]) {
        if (distanceKm(c.position, near) < 0.01) return restaurants[c.id];
      }
      return null;
    },
  );
  final options = await builder
      .load(
          route: route,
          progressKm: progressKm,
          soc: soc,
          energy: _energy,
          suggestedChargerId: suggested,
          wantFood: wantFood)
      .last;
  expect(options.done, isTrue);
  return options.sites;
}

void main() {
  group('score', () {
    double score(ChargerSite s) => double.parse(s.score.toStringAsFixed(2));

    test('uses your weights', () async {
      final live = _Live(
        status: {'a': LiveStatus.available, 'b': LiveStatus.available},
        checks: {'a': _freeGuns, 'b': _freeGuns},
      );
      final sites = await _sites(
        [_at(50, 'a', kw: 120), _at(100, 'b', kw: 60), _at(150, 'c', kw: 30)],
        live: live,
        restaurants: const {'a': Restaurant(name: 'R', rating: 4.5, ratingCount: 500)},
      );
      final byId = {for (final s in sites) s.primary.charger.id: score(s)};
      expect(byId['a'], 1.15); // free 0.4 + restaurant 0.35 + 100 kW 0.4
      expect(byId['b'], 0.60); // free 0.4 + 60 kW 0.2
      expect(byId['c'], -0.10); // free 0.4 + status not available -0.5
    });

    test('with food switched off, restaurants are not looked up or scored', () async {
      final live = _Live(
        status: {'a': LiveStatus.available, 'b': LiveStatus.available},
        checks: {'a': _freeGuns, 'b': _freeGuns},
      );
      var lookups = 0;
      final sites = await _sites(
        [_at(50, 'a', kw: 60), _at(100, 'b', kw: 100)],
        live: live,
        restaurants: const {'a': Restaurant(name: 'R', rating: 4.5, ratingCount: 500)},
        onRestaurant: () => lookups++,
        wantFood: false,
      );
      expect(lookups, 0);
      expect(sites.map((s) => s.primary.charger.id), ['b', 'a'], reason: 'power decides, not food');
      expect(score(sites.last), 0.6);
      expect(sites.every((s) => s.restaurant == null), isTrue);
    });

    test('the same restaurant moves its charger up when food is wanted', () async {
      final live = _Live(
        status: {'a': LiveStatus.available, 'b': LiveStatus.available},
        checks: {'a': _freeGuns, 'b': _freeGuns},
      );
      final sites = await _sites(
        [_at(50, 'a', kw: 60), _at(100, 'b', kw: 100)],
        live: live,
        restaurants: const {'a': Restaurant(name: 'R', rating: 4.5, ratingCount: 500)},
      );
      expect(sites.map((s) => s.primary.charger.id), ['a', 'b']);
      expect(score(sites.first), 0.95);
    });

    test('power tiers: 99 kW scores as 60, 59 kW as 30', () async {
      final live = _Live(
        status: {'x': LiveStatus.available, 'y': LiveStatus.available},
        checks: {'x': _freeGuns, 'y': _freeGuns},
      );
      final sites = await _sites([_at(50, 'x', kw: 99), _at(60, 'y', kw: 59)], live: live);
      expect(score(sites.firstWhere((s) => s.primary.charger.id == 'x')), 0.6);
      expect(score(sites.firstWhere((s) => s.primary.charger.id == 'y')), 0.4);
    });

    test('list is sorted best first, ties go to the one nearest 25%', () async {
      // At 70%, 25% is reached at km 225.
      final sites = await _sites([_at(50, 'far'), _at(220, 'near'), _at(120, 'mid')]);
      expect(sites.map((s) => s.primary.charger.id), ['near', 'mid', 'far']);
    });

    test('on equal scores a charger with a free gun beats a busy one', () async {
      final live = _Live(
        status: {'busy': LiveStatus.unavailable, 'up': LiveStatus.available},
        checks: {
          'busy': const StationCheck(StationState.busy, freeGuns: 0, totalGuns: 2),
          'up': _freeGuns,
        },
      );
      // The busy one is closer to the 25% point, which would otherwise win the tie.
      final sites = await _sites([_at(220, 'busy'), _at(50, 'up')], live: live);
      expect(sites.map((s) => s.primary.charger.id), ['up', 'busy']);
    });

    test('a paid charger gets no free points', () async {
      final sites = await _sites(const [],
          other: [_at(50, 'p', kw: 120, source: ChargerSource.other, free: 1)]);
      expect(score(sites.single), 0.4);
      expect(sites.single.isFree, isFalse);
      expect(sites.single.status, SiteStatus.available);
    });
  });

  group('estimates', () {
    test('arrival charge uses distance from here plus half the detour', () async {
      final sites = await _sites([_at(150, 'a')], soc: 60, progressKm: 50);
      expect(sites.single.arrivalSoc, closeTo(40, 0.5));
    });

    test('charge time follows the charging curve to 80%', () async {
      // 100 km uses 20%: arrive at 50%, 30 kWh to reach 80%. A 60 kW charger gives
      // 54 kW until the car's own taper drops below that, near 79%.
      final sites = await _sites([_at(100, 'a', kw: 60)]);
      expect(sites.single.chargeMinutes, _energy.chargeMinutes(50, 80, 60).ceil());
      expect(sites.single.chargeMinutes, inInclusiveRange(33, 35));
    });

    test('no charge time without a power rating or need', () async {
      final sites = await _sites(const [],
          other: [_at(10, 'p', kw: 0, source: ChargerSource.other)], soc: 95);
      expect(sites.single.chargeMinutes, isNull);
    });

    test('chargers behind the car or out of range are not offered', () async {
      final sites = await _sites([_at(10, 'behind'), _at(150, 'ok'), _at(700, 'far')], soc: 50, progressKm: 100);
      expect(sites.map((s) => s.primary.charger.id), ['ok']);
    });
  });

  group('live status', () {
    test('dead chargers are dropped, busy ones listed as busy', () async {
      final live = _Live(
        status: {'dead': LiveStatus.unavailable, 'busy': LiveStatus.unavailable},
        checks: {
          'dead': const StationCheck(StationState.dead),
          'busy': const StationCheck(StationState.busy, freeGuns: 0, totalGuns: 2),
        },
      );
      final sites = await _sites([_at(50, 'dead'), _at(60, 'busy')], live: live);
      expect(sites.single.primary.charger.id, 'busy');
      expect(sites.single.status, SiteStatus.busy);
      expect(sites.single.freeGuns, 0);
      expect(sites.single.allGunsKnown, isTrue);
    });

    test('a charger reported down whose check fails stays hidden', () async {
      final sites = await _sites([_at(50, 'down')], live: _Live(status: {'down': LiveStatus.unavailable}));
      expect(sites, isEmpty);
    });

    test('caps requests to the status server', () async {
      final free = [for (var k = 10; k < 300; k += 2) _at(k.toDouble(), 'c$k')];
      final live = _Live(status: {for (final c in free) c.id: LiveStatus.available});
      await _sites(free, live: live);
      expect(live.calls, lessThanOrEqualTo(const RankingRules().maxStationChecks + const RankingRules().maxListed * 2));
    });

    test('stations that make the list get checked, even after the first pass runs out', () async {
      // Nearest the 25% point are the 30 kW ones that use up the first pass.
      final near = [for (var k = 0; k < 30; k++) _at(190.0 + k * 2, 'near$k')];
      final strong = _at(30, 'strong', kw: 120);
      final live = _Live(
        status: {for (final c in [...near, strong]) c.id: LiveStatus.available},
        checks: {'strong': _freeGuns},
      );
      final sites = await _sites([...near, strong], live: live);
      final site = sites.firstWhere((s) => s.primary.charger.id == 'strong');
      expect(site.freeGuns, 2);
      expect(site.allGunsKnown, isTrue);
    });

    test('caps the list, and restaurant lookups with it', () async {
      var lookups = 0;
      final sites = await _sites([for (var k = 10; k < 300; k += 2) _at(k.toDouble(), 'c$k')],
          onRestaurant: () => lookups++);
      expect(sites.length, const RankingRules().maxListed);
      expect(lookups, lessThanOrEqualTo(const RankingRules().maxListed));
    });
  });

  group('real road detours', () {
    test('a charger over the limit by road is dropped, whatever the map suggests', () async {
      final sites = await _sites([_at(100, 'river'), _at(120, 'ok')],
          realDetours: const {'river': 28, 'ok': 2});
      expect(sites.map((s) => s.primary.charger.id), ['ok']);
    });

    test('the real distance is what gets shown and used for arrival charge', () async {
      final sites = await _sites([_at(100, 'a')], realDetours: const {'a': 10});
      expect(sites.single.primary.detourKm, 10);
      expect(sites.single.arrivalSoc, closeTo(49, 0.5)); // 70 - (100 + 5) * 0.2
    });

    test('a charger moving up after others drop out still gets a health check', () async {
      // The top 12 are all rejected by road, so the 13th moves up. It's actually dead.
      final top = [for (var k = 0; k < 12; k++) _at(20.0 + k, 't$k', kw: 120)];
      final late = _at(60, 'late', kw: 30);
      final live = _Live(
        status: {'late': LiveStatus.available},
        checks: {'late': const StationCheck(StationState.dead)},
      );
      final sites = await _sites([...top, late], live: live, realDetours: {for (final c in top) c.id: 40.0});
      expect(sites, isEmpty);
    });

    test('next chargers fill the list when some drop out', () async {
      final free = [for (var k = 0; k < 20; k++) _at(20.0 + k * 10, 'c$k')];
      final sites = await _sites(free, realDetours: {for (var k = 0; k < 8; k++) 'c${k + 4}': 40.0});
      expect(sites.length, const RankingRules().maxListed);
      expect(sites.any((s) => s.primary.detourKm > 15), isFalse);
    });
  });

  test('the chosen stop carries the power learnt from its live check', () async {
    final live = _Live(
      status: {'a': LiveStatus.available},
      checks: {'a': const StationCheck(StationState.free, freeGuns: 2, totalGuns: 2, kw: 120)},
    );
    final site = (await _sites([_at(100, 'a', kw: 60)], live: live)).single;
    expect(site.kw, 120);
    expect(site.primary.charger.dcKw, 120, reason: 'the "Going to" card uses this');
  });

  group('collocated chargers', () {
    test('merge: guns add up, best power wins', () async {
      final live = _Live(
        status: {'a': LiveStatus.available, 'b': LiveStatus.available},
        checks: {
          'a': const StationCheck(StationState.free, freeGuns: 1, totalGuns: 2),
          'b': const StationCheck(StationState.free, freeGuns: 2, totalGuns: 4),
        },
      );
      final sites = await _sites([_at(100, 'a', kw: 30), _at(100.05, 'b', kw: 120)], live: live);
      final site = sites.single;
      expect(site.otherChargers, 1);
      expect(site.kw, 120);
      expect(site.totalGuns, 6);
      expect(site.freeGuns, 3);
      expect(site.primary.charger.id, 'b');
    });

    test('a free charger beside a paid one makes the stop free, and navigates to it', () async {
      final sites = await _sites([_at(100, 'free', kw: 30)],
          other: [_at(100.05, 'paid', kw: 120, source: ChargerSource.other)]);
      expect(sites.single.isFree, isTrue);
      expect(sites.single.primary.charger.id, 'free');
      expect(sites.single.kw, 120);
    });

    test('one dead charger does not take the stop down with it', () async {
      final live = _Live(
        status: {'dead': LiveStatus.unavailable, 'up': LiveStatus.available},
        checks: {'dead': const StationCheck(StationState.dead), 'up': _freeGuns},
      );
      final site = (await _sites([_at(100, 'dead'), _at(100.05, 'up')], live: live)).single;
      expect(site.otherChargers, 0);
      expect(site.totalGuns, 2);
    });

    test('chargers apart stay separate', () async {
      final sites = await _sites([_at(100, 'a'), _at(100.5, 'b')]);
      expect(sites.length, 2);
    });

    test('marks the suggested stop even when merged', () async {
      final sites = await _sites([_at(100, 'a'), _at(100.05, 'b', kw: 120)], suggested: 'a');
      expect(sites.single.isSuggested, isTrue);
    });
  });

  test('failed lookups never break the list', () async {
    final route = RouteProfile(points: [const GeoPoint(10, 77), _north(800)]);
    final builder = ChargerOptionsBuilder(
      planner: ChargePlanner(
        freeChargers: [_at(50, 'a')],
        searchOtherChargers: (_, _) async => const [],
        checkDetour: (_, _) async => null,
      ),
      findOtherChargers: (_) async => throw Exception('offline'),
      findRestaurant: (_) async => throw Exception('offline'),
    );
    final options = await builder.load(route: route, progressKm: 0, soc: 70, energy: _energy).last;
    expect(options.sites.single.restaurant, isNull);
    expect(options.done, isTrue);
  });
}
