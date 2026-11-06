import 'package:flutter_test/flutter_test.dart';
import 'package:vinfast_copilot/core/charge_planner.dart';
import 'package:vinfast_copilot/core/charger.dart';
import 'package:vinfast_copilot/core/charger_options.dart';
import 'package:vinfast_copilot/core/energy.dart';
import 'package:vinfast_copilot/core/geo.dart';
import 'package:vinfast_copilot/core/live_status.dart';
import 'package:vinfast_copilot/core/route_profile.dart';

const _kmPerDegree = 111.195;
GeoPoint _north(double km, {double off = 0}) => GeoPoint(10 + km / _kmPerDegree, 77 + off / (_kmPerDegree * 0.98));
RouteProfile _route(double km) => RouteProfile(points: [const GeoPoint(10, 77), _north(km)]);

// 0.2 % per km.
const _energy = EnergyModel(kwhPer100Km: 20, batteryKwh: 100);

Charger _free(double km, {double kw = 30, String? id}) =>
    Charger(id: id ?? 'free$km', name: 'Free $km', position: _north(km), dcKw: kw);

/// A Google listing. [freeGuns] is Google's live count, when it has one.
Charger _fast(double km, {int? freeGuns = 2, double kw = 180, String? id, double off = 0}) => Charger(
      id: id ?? 'fast$km',
      name: 'Fast $km',
      position: _north(km, off: off),
      dcKw: kw,
      dcCount: 2,
      freeGuns: freeGuns,
      source: ChargerSource.other,
    );

class _Live extends LiveStatusSource {
  _Live(this.checks);
  final Map<String, StationCheck> checks;

  @override
  LiveStatus statusOf(Charger c) => switch (checks[c.id]?.state) {
        StationState.free => LiveStatus.available,
        null => LiveStatus.unknown,
        _ => LiveStatus.unavailable,
      };

  @override
  bool canCheck(Charger c) => checks.containsKey(c.id);

  @override
  Future<StationCheck?> check(Charger c) async => checks[c.id];
}

ChargePlanner _planner({
  List<Charger> free = const [],
  List<Charger> fast = const [],
  List<Charger> other = const [],
  Map<String, double> realDetours = const {},
  LiveStatusSource? live,
}) =>
    ChargePlanner(
      freeChargers: free,
      searchUltraFast: (_) async => fast,
      searchOtherChargers: (_, _) async => other,
      checkDetour: (_, place) async => realDetours[place.charger.id],
      live: live,
    );

void main() {
  group('180 kW chargers', () {
    // Start at 75%: 25% at 250 km, the 20% floor at 275 km.
    final route = _route(600);

    test('an available one on the road beats a free charger nearer the 25% point', () async {
      final plan = await _planner(free: [_free(245)], fast: [_fast(200)])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'fast200.0');
    });

    test('free-list chargers of 180 kW count too, when the network confirms a free gun', () async {
      final live = _Live({'f180': const StationCheck(StationState.free, freeGuns: 1, totalGuns: 2)});
      final plan = await _planner(free: [_free(245), _free(190, kw: 180, id: 'f180')], live: live)
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'f180');
    });

    test('unknown availability is not enough to jump the queue', () async {
      final plan = await _planner(free: [_free(245)], fast: [_fast(200, freeGuns: null)])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'free245.0');
    });

    test('busy is not available', () async {
      final live = _Live({'fast200.0': const StationCheck(StationState.busy)});
      final plan = await _planner(free: [_free(245)], fast: [_fast(200, freeGuns: null)], live: live)
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'free245.0');
    });

    test('more than 3 km off the road by real roads is not "on the road"', () async {
      final plan = await _planner(free: [_free(245)], fast: [_fast(200)], realDetours: const {'fast200.0': 5})
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'free245.0');
    });

    test('must be reachable above 20%', () async {
      final plan = await _planner(free: [_free(245)], fast: [_fast(285)])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'free245.0');
    });

    test('reachability uses the current rate of burning, not the usual one', () async {
      final planner = _planner(free: [_free(150)], fast: [_fast(220)]);
      final usual = await planner.plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(usual.stops.first.place.charger.id, 'fast220.0');
      // Driving 30% harder: 220 km would leave about 17.8%.
      final hard = await planner.plan(route: route, fromKm: 0, soc: 75, energy: _energy.withBurnScale(1.3));
      expect(hard.stops.first.place.charger.id, 'free150.0');
    });

    test('found for the map whatever the charge, minus any reported down', () async {
      final live = _Live({'fast300.0': const StationCheck(StationState.dead)});
      final planner = _planner(
          free: [_free(100, kw: 240, id: 'f240'), _free(120)],
          fast: [_fast(200), _fast(300), _fast(400, kw: 120), _fast(500, off: 5)],
          live: live);
      final shown = await planner.ultraFastOnRoute(route);
      expect(shown.map((c) => c.charger.id), ['f240', 'fast200.0']);
    });

    test('a failed search still leaves the free list\'s fast chargers', () async {
      final planner = ChargePlanner(
        freeChargers: [_free(100, kw: 180, id: 'f180')],
        searchUltraFast: (_) async => throw Exception('offline'),
        searchOtherChargers: (_, _) async => const [],
        checkDetour: (_, _) async => null,
      );
      expect((await planner.ultraFastOnRoute(route)).single.charger.id, 'f180');
    });
  });

  group('quick top-up', () {
    // 75% over 260 km uses 52%: arriving at 23%, just short of 25%.
    final route = _route(260);

    test('a few minutes at a 60 kW charger near halfway instead of a full stop', () async {
      final plan = await _planner(free: [_free(60, kw: 60), _free(130, kw: 60), _free(132, kw: 30)])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      final stop = plan.stops.single;
      expect(stop.kind, StopKind.topUp);
      expect(stop.place.charger.id, 'free130.0');
      // Short by 2%, but a top-up adds at least 20 km: 4 kWh at 54 kW is 4.4 min,
      // so the 5 minute minimum, which adds 4.5 kWh.
      expect(stop.chargeMinutes, 5);
      expect(stop.arrivalSoc, closeTo(49, 0.5));
      expect(stop.departureSoc, closeTo(53.5, 0.5));
      expect(plan.arrivalSoc, greaterThanOrEqualTo(25));
    });

    test('at least 5 minutes, enough for a break', () async {
      final plan = await _planner(fast: [_fast(130)]).plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.single.kind, StopKind.topUp);
      expect(plan.stops.single.chargeMinutes, 5);
    });

    test('a slow charger can\'t top up in time, so it becomes a normal stop', () async {
      final plan = await _planner(free: [_free(130)]).plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.single.kind, StopKind.full);
    });

    test('a big shortfall needs a full stop, not a top-up', () async {
      final plan = await _planner(free: [_free(240, kw: 60)])
          .plan(route: _route(400), fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.kind, StopKind.full);
    });

    test('the car\'s own charging limit counts', () async {
      // Short by 7 kWh. A 120 kW charger manages that in 4 min, but a car that
      // takes only 30 kW needs about 15.
      final planner = _planner(free: [_free(110, kw: 120)]);
      final fastCar = await planner.plan(route: _route(285), fromKm: 0, soc: 75, energy: _energy);
      expect(fastCar.stops.single.kind, StopKind.topUp);
      const slowCar = EnergyModel(kwhPer100Km: 20, batteryKwh: 100, maxChargeKw: 30);
      final slow = await planner.plan(route: _route(285), fromKm: 0, soc: 75, energy: slowCar);
      expect(slow.stops.single.kind, StopKind.full);
    });

    test('searches near halfway when the corridor has nothing fast enough', () async {
      final plan = await _planner(other: [_fast(128, kw: 60, freeGuns: null, id: 'paid60')])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.single.kind, StopKind.topUp);
      expect(plan.stops.single.place.charger.id, 'paid60');
    });

    test('a charger reported dead is never the top-up', () async {
      final live = _Live({'free130.0': const StationCheck(StationState.dead)});
      final plan = await _planner(free: [_free(130, kw: 60), _free(150, kw: 60)], live: live)
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.single.place.charger.id, 'free150.0');
    });
  });

  group('picker', () {
    test('an available 180 kW charger on the road is listed first, whatever the score', () async {
      final route = _route(800);
      final builder = ChargerOptionsBuilder(
        planner: _planner(
            free: [_free(150, kw: 120, id: 'free120')],
            live: _Live({'free120': const StationCheck(StationState.free, freeGuns: 2, totalGuns: 2)})),
        findOtherChargers: (_) async => [_fast(200), _fast(210, freeGuns: null, id: 'unknown')],
        findRestaurant: (_) async => null,
      );
      final sites = (await builder.load(route: route, progressKm: 0, soc: 70, energy: _energy).last).sites;
      expect(sites.first.primary.charger.id, 'fast200.0');
      expect(sites.first.isPriority, isTrue);
      // Free and 120 kW scores higher, but isn't 180 kW.
      expect(sites[1].primary.charger.id, 'free120');
      expect(sites[1].score, greaterThan(sites.first.score));
      expect(sites.firstWhere((s) => s.primary.charger.id == 'unknown').isPriority, isFalse);
    });
  });
}
