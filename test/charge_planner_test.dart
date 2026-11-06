import 'package:flutter_test/flutter_test.dart';
import 'package:vinfast_copilot/core/charge_planner.dart';
import 'package:vinfast_copilot/core/charger.dart';
import 'package:vinfast_copilot/core/energy.dart';
import 'package:vinfast_copilot/core/geo.dart';
import 'package:vinfast_copilot/core/route_profile.dart';

/// A due-north route along lng 77: 1 degree of latitude is about 111.2 km.
const _kmPerDegree = 111.195;
RouteProfile _route(double km, {List<SlowStretch> slow = const []}) => RouteProfile(
      points: [const GeoPoint(10, 77), GeoPoint(10 + km / _kmPerDegree, 77)],
      slowStretches: slow,
    );

Charger _at(double km, {double offRouteKm = 0, String? id, double kw = 60, ChargerSource source = ChargerSource.free}) =>
    Charger(
      id: id ?? 'at$km+$offRouteKm',
      name: 'Charger at $km',
      position: GeoPoint(10 + km / _kmPerDegree, 77 + offRouteKm / (_kmPerDegree * 0.98)),
      dcKw: kw,
      source: source,
    );

// 20 kWh/100 km on a 100 kWh pack: exactly 0.2 % per km.
const _energy = EnergyModel(kwhPer100Km: 20, batteryKwh: 100);

ChargePlanner _planner(List<Charger> free,
        {List<Charger> other = const [], Map<String, double> realDetours = const {}, List<GeoPoint>? searches}) =>
    ChargePlanner(
      freeChargers: free,
      searchOtherChargers: (near, _) async {
        searches?.add(near);
        return other;
      },
      checkDetour: (_, place) async => realDetours[place.charger.id],
    );

void main() {
  group('SocEstimator', () {
    test('drops by consumption over battery size', () {
      final soc = SocEstimator(
          startSoc: 80, energy: const EnergyModel(kwhPer100Km: 15, batteryKwh: 59.6));
      soc.addDistance(100);
      expect(soc.soc, closeTo(80 - 25.17, 0.01));
    });

    test('never goes below zero, ignores negative distance, resets', () {
      final soc = SocEstimator(startSoc: 10, energy: _energy);
      soc.addDistance(-5);
      expect(soc.soc, 10);
      soc.addDistance(1000);
      expect(soc.soc, 0);
      soc.reset(70);
      expect(soc.soc, 70);
      soc.addDistance(50);
      expect(soc.soc, closeTo(60, 0.001));
    });
  });

  group('route', () {
    test('decodes a polyline (Google documented example)', () {
      final p = decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
      expect(p.length, 3);
      expect(p[0].lat, closeTo(38.5, 1e-5));
      expect(p[0].lng, closeTo(-120.2, 1e-5));
      expect(p[2].lng, closeTo(-126.453, 1e-5));
    });

    test('projects points onto the route', () {
      final route = _route(300);
      expect(route.totalKm, closeTo(300, 0.5));
      final p = route.projectNearby(_at(150, offRouteKm: 3).position)!;
      expect(p.alongKm, closeTo(150, 0.6));
      expect(p.offRouteKm, closeTo(3, 0.2));
      expect(route.projectNearby(_at(150, offRouteKm: 60).position), isNull);
    });
  });

  group('choosing a stop', () {
    // Start at 75%: reaches 25% at 250 km, and the 20% floor at 275 km.
    final route = _route(600);

    test('no stop when the destination is reached above reserve', () async {
      final plan = await _planner([_at(100)]).plan(route: _route(200), fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops, isEmpty);
      expect(plan.arrivalSoc, closeTo(35, 0.5));
    });

    test('picks the free charger nearest the 25% point', () async {
      final plan = await _planner([_at(120), _at(240), _at(280), _at(400)])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, _at(240).id);
      expect(plan.stops.first.arrivalSoc, closeTo(27, 0.5));
    });

    test('never plans past the floor while anything above it is in reach', () async {
      final plan = await _planner([_at(240), _at(280)]).plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      // 280 km would be 19%, under the floor.
      expect(plan.stops.first.place.charger.id, _at(240).id);
      expect(plan.stops.first.belowFloor, isFalse);
    });

    test('with nothing above the floor, the nearest below it is planned, with a warning', () async {
      final plan = await _planner([_at(300)]).plan(route: _route(450), fromKm: 0, soc: 75, energy: _energy);
      // 300 km would be 15%: better than running flat.
      expect(plan.stops.first.place.charger.id, _at(300).id);
      expect(plan.stops.first.arrivalSoc, closeTo(15, 0.5));
      expect(plan.stops.first.belowFloor, isTrue);
      expect(plan.strandedAtKm, isNull);
    });

    test('a free charger early beats a paid one on target', () async {
      final plan = await _planner([_at(160)], other: [_at(250, id: 'paid', source: ChargerSource.other)])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.isFree, isTrue);
    });

    test('open-road free charger within 15 km detour is used', () async {
      final plan = await _planner([_at(250, offRouteKm: 5, id: 'near')])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'near');
      expect(plan.stops.first.place.detourKm, closeTo(13, 0.8));
    });

    test('open-road charger beyond 15 km detour falls back to paid', () async {
      final plan = await _planner([_at(250, offRouteKm: 8, id: 'far')],
              other: [_at(255, id: 'paid', source: ChargerSource.other)])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'paid');
    });

    test('in a city only a 6 km detour is allowed', () async {
      final city = _route(600, slow: const [SlowStretch(200, 300)]);
      final options = [_at(250, offRouteKm: 5, id: 'too-far-for-city'), _at(255, offRouteKm: 2, id: 'ok')];
      final found = _planner(options).freeChargersOnRoute(city);
      expect(found.map((c) => c.charger.id), ['ok']);
    });

    test('real road distance overrides the straight-line guess', () async {
      // Looks close, but is across a river: the road detour is 40 km.
      final plan = await _planner(
        [_at(250, offRouteKm: 1, id: 'river'), _at(235, id: 'good')],
        realDetours: const {'river': 40, 'good': 1},
      ).plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'good');
      expect(plan.stops.first.detourVerified, isTrue);
      expect(plan.stops.first.place.detourKm, 1);
    });

    test('a free charger with plenty of charge left beats paying on target', () async {
      // 110 km in leaves 53%, above the usual stopping window.
      final plan = await _planner([_at(110, id: 'early')],
              other: [_at(250, id: 'paid', source: ChargerSource.other)])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'early');
    });

    test('a free charger with too much charge left is not worth the stop', () async {
      // 50 km in leaves 65%: pay on target instead.
      final plan = await _planner([_at(50, id: 'too-early')],
              other: [_at(250, id: 'paid', source: ChargerSource.other)])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'paid');
    });

    test('keeps looking past many bad road checks before paying', () async {
      // The eight closest to the target all turn out far by road, like a river crossing.
      final bad = [for (var k = 0; k < 8; k++) _at(250.0 - k, id: 'bad$k')];
      final plan = await _planner(
        [...bad, _at(200, id: 'good')],
        other: [_at(250, id: 'paid', source: ChargerSource.other)],
        realDetours: {for (final c in bad) c.id: 40.0, 'good': 2.0, 'paid': 1.0},
      ).plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'good');
    });

    test('a real detour that drops arrival below the floor rules a charger out', () async {
      // Reachable at 19% by the guess. 14 km real detour means 7 km more, so 17.6%.
      final plan = await _planner([_at(280, id: 'edge'), _at(200, id: 'safe')],
              realDetours: const {'edge': 14, 'safe': 1})
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'safe');
    });

    test('a paid charger far by road loses to a paid one close by road', () async {
      final plan = await _planner(const [], other: [
        _at(250, id: 'looks-close', source: ChargerSource.other),
        _at(230, id: 'really-close', source: ChargerSource.other),
      ], realDetours: const {'looks-close': 30, 'really-close': 2})
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'really-close');
      expect(plan.stops.first.detourVerified, isTrue);
    });

    test('if every charger is far by road, the least bad beats being stranded', () async {
      final plan = await _planner(const [], other: [
        _at(250, id: 'a', source: ChargerSource.other),
        _at(240, id: 'b', source: ChargerSource.other),
      ], realDetours: const {'a': 50, 'b': 20})
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'b');
      expect(plan.stops.first.place.detourKm, 20);
    });

    test('slow AC-only and low-power sites are not route stops', () async {
      final plan = await _planner([_at(250, kw: 0), _at(240, kw: 7.4)],
              other: [_at(245, id: 'paid', source: ChargerSource.other)])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'paid');
    });

    test('prefers a faster charger when both are near the target', () async {
      final plan = await _planner([_at(250, kw: 30, id: 'slow'), _at(245, kw: 120, id: 'fast')])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'fast');
    });

    test('reports stranded when there is no charger at all', () async {
      final plan = await _planner(const []).plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops, isEmpty);
      expect(plan.strandedAtKm, closeTo(250, 0.5));
    });

    test('searches for other chargers at the target, just past it, then further back', () async {
      final searches = <GeoPoint>[];
      await _planner(const [], searches: searches).plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      double kmOf(GeoPoint p) => distanceKm(const GeoPoint(10, 77), p);
      expect(kmOf(searches[0]), closeTo(250, 1));
      expect(kmOf(searches[1]), closeTo(270, 1));
      expect(kmOf(searches[2]), closeTo(230, 1));
      expect(kmOf(searches.last), closeTo(130, 1));
    });

    test('a charger found a long way back still saves the trip', () async {
      final plan = await _planner(const [], other: [_at(140, id: 'far-back', source: ChargerSource.other)])
          .plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.first.place.charger.id, 'far-back');
    });

    test('starting below reserve still finds the next reachable charger', () async {
      final plan = await _planner([_at(20), _at(90)]).plan(route: route, fromKm: 0, soc: 15, energy: _energy);
      expect(plan.stops.first.place.charger.id, _at(20).id);
      expect(plan.stops.first.arrivalSoc, closeTo(11, 0.5));
    });

    test('planning from mid-route ignores chargers already passed', () async {
      final plan = await _planner([_at(100), _at(380)]).plan(route: route, fromKm: 300, soc: 40, energy: _energy);
      expect(plan.stops.first.place.charger.id, _at(380).id);
    });

    test('chains stops, and charges only what the rest of the trip needs', () async {
      final plan = await _planner([_at(250), _at(500)]).plan(route: route, fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.map((s) => s.place.charger.id), [_at(250).id, _at(500).id]);
      // 100 km left after the last stop = 20% + 25% reserve + 5% buffer.
      expect(plan.stops.last.departureSoc, closeTo(50, 0.5));
      expect(plan.arrivalSoc, closeTo(30, 0.5));
      expect(plan.strandedAtKm, isNull);
      expect(plan.stops.first.chargeMinutes, greaterThan(0));
    });

    test('never recharges at the same place forever', () async {
      final plan = await _planner([_at(250)]).plan(route: _route(2000), fromKm: 0, soc: 75, energy: _energy);
      expect(plan.stops.length, 1);
      expect(plan.strandedAtKm, isNotNull);
    });
  });
}
