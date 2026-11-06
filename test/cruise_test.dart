import 'package:flutter_test/flutter_test.dart';
import 'package:vinfast_copilot/core/charge_planner.dart';
import 'package:vinfast_copilot/core/charger.dart';
import 'package:vinfast_copilot/core/cruise_speed.dart';
import 'package:vinfast_copilot/core/energy.dart';
import 'package:vinfast_copilot/core/geo.dart';
import 'package:vinfast_copilot/core/route_profile.dart';

const _kmPerDegree = 111.195;
GeoPoint _north(double km, {double off = 0}) => GeoPoint(10 + km / _kmPerDegree, 77 + off / (_kmPerDegree * 0.98));

// A VF 7 as a driver might describe it.
const _vf7 = EnergyModel(kwhPer100Km: 16, batteryKwh: 70.8, ratedRangeKm: 532);

/// Google's typical speed on an expressway is well under the limit.
RouteProfile _expressway(double km) =>
    RouteProfile(points: [const GeoPoint(10, 77), _north(km)], speedBands: [SpeedBand(0, km + 1, 90)]);

CruiseAdvice _advise(RouteProfile route, double kw, {double soc = 80}) => CruiseAdvisor.advise(
      route: route,
      startSoc: soc,
      energy: _vf7,
      arriveWith: 55,
      chargerKw: kw,
      reserveSoc: 25,
      chargeToSoc: 80,
      stopOverheadMinutes: 8,
    );

void main() {
  group('cruising speed', () {
    test('faster saves driving time but uses more battery, ever more steeply', () {
      final options = _advise(_expressway(300), 120).options;
      for (var i = 1; i < options.length; i++) {
        expect(options[i].driveMinutes, lessThan(options[i - 1].driveMinutes));
        expect(options[i].socUsed, greaterThan(options[i - 1].socUsed));
      }
      final at80 = options.firstWhere((o) => o.kmh == 80), at100 = options.firstWhere((o) => o.kmh == 100);
      final at120 = options.last;
      expect(at120.socUsed - at100.socUsed, greaterThan(at100.socUsed - at80.socUsed));
    });

    test('slow chargers make slower cruising pay', () {
      final slow = _advise(_expressway(300), 30).best.kmh;
      final fast = _advise(_expressway(300), 180).best.kmh;
      expect(slow, lessThan(fast));
    });

    test('the quickest overall really is quickest, charging included', () {
      final advice = _advise(_expressway(300), 60);
      for (final o in advice.options) {
        expect(advice.best.totalMinutes, lessThanOrEqualTo(o.totalMinutes + CruiseAdvisor.tieMinutes));
      }
    });

    test('with no charging needed, the limit is quickest', () {
      final advice = _advise(_expressway(60), 60, soc: 100);
      expect(advice.best.chargeMinutes, 0);
      expect(advice.best.kmh, 120);
      expect(advice.slowerPays, isFalse);
    });

    test('national highways stay at 100 and towns at their own pace, whatever the advice', () {
      final route = RouteProfile(
        points: [const GeoPoint(10, 77), _north(200)],
        speedBands: const [SpeedBand(0, 100, 70), SpeedBand(100, 201, 35)],
      );
      final at120 = route.drivingSeconds(cruiseKmh: 120);
      expect(at120, closeTo(100 * 3600 / 100 + 100 * 3600 / 35, 60));
      expect(route.drivingSeconds(cruiseKmh: 100), at120);
      expect(route.openRoadShare, closeTo(0.5, 0.01));
    });

    test('congestion takes the pace out of the driver\'s hands', () {
      final route = RouteProfile(
        points: [const GeoPoint(10, 77), _north(100)],
        speedBands: const [SpeedBand(0, 101, 100)],
        trafficBands: const [TrafficBand(0, 50, 0.25)],
      );
      expect(route.openRoadShare, closeTo(0.5, 0.02));
    });

    test('the plan costs open road at the advised speed', () {
      final route = _expressway(300);
      final at90 = route.socUsed(0, 300, _vf7.withCruise(90));
      final at120 = route.socUsed(0, 300, _vf7.withCruise(120));
      expect(at120 / at90, closeTo(_vf7.factorAt(120) / _vf7.factorAt(90), 0.01));
    });
  });

  group('arriving with 55%', () {
    // 0.2% per km on a 100 kWh pack.
    const energy = EnergyModel(kwhPer100Km: 20, batteryKwh: 100);
    RouteProfile route(double km) => RouteProfile(points: [const GeoPoint(10, 77), _north(km)]);
    Charger charger(double km, {double kw = 60, double off = 0, ChargerSource source = ChargerSource.free}) =>
        Charger(id: 'c$km', name: 'C$km', position: _north(km, off: off), dcKw: kw, source: source);
    ChargePlanner planner(List<Charger> free, {List<Charger> other = const []}) => ChargePlanner(
          freeChargers: free,
          searchOtherChargers: (_, _) async => other,
          checkDetour: (_, _) async => null,
        );

    test('long trips plan for 55% at the destination, short ones keep the reserve', () {
      const rules = PlannerRules();
      expect(rules.destinationSocFor(300), 55);
      expect(rules.destinationSocFor(60), 25);
    });

    test('charges enough on the way to arrive with 55%', () async {
      final plan = await planner([charger(200)])
          .plan(route: route(300), fromKm: 0, soc: 80, energy: energy, destinationSoc: 55);
      expect(plan.stops.single.departureSoc, closeTo(75, 0.5));
      expect(plan.arrivalSoc, closeTo(55, 0.5));
    });

    test('the drive back from a charger off the route is charged for too', () async {
      final plan = await planner([], other: [charger(280, off: 3, source: ChargerSource.other)])
          .plan(route: route(300), fromKm: 0, soc: 80, energy: energy, destinationSoc: 55);
      expect(plan.stops, hasLength(1), reason: 'not the same charger again and again');
      expect(plan.arrivalSoc, greaterThanOrEqualTo(54.5));
    });

    test('a much faster paid charger beats a slow one at the ideal spot', () async {
      final plan = await planner([], other: [
        charger(250, kw: 30, source: ChargerSource.other),
        charger(225, kw: 120, source: ChargerSource.other),
      ]).plan(route: route(600), fromKm: 0, soc: 75, energy: energy);
      expect(plan.stops.first.place.charger.id, 'c225.0');
    });
  });
}
