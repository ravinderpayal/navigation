import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vinfast_copilot/core/charge_planner.dart';
import 'package:vinfast_copilot/core/charger.dart';
import 'package:vinfast_copilot/core/energy.dart';
import 'package:vinfast_copilot/core/geo.dart';
import 'package:vinfast_copilot/core/route_profile.dart';

/// Runs the planner over the real charger list.
void main() {
  final raw = jsonDecode(File('assets/free_chargers.json').readAsStringSync()) as List;
  final chargers = raw.map((e) => Charger.fromJson(e as Map<String, dynamic>)).toList();
  const vf7 = EnergyModel(kwhPer100Km: 20, batteryKwh: 70.8);

  ChargePlanner planner() => ChargePlanner(
        freeChargers: chargers,
        searchOtherChargers: (_, _) async => const [],
        checkDetour: (_, _) async => null,
      );

  // Straight approximations of NH-48 style corridors, point by point.
  RouteProfile delhiJaipur() => RouteProfile(points: const [
        GeoPoint(28.6139, 77.2090),
        GeoPoint(28.4595, 77.0266),
        GeoPoint(28.2000, 76.8200),
        GeoPoint(27.9000, 76.4000),
        GeoPoint(27.5500, 76.1000),
        GeoPoint(26.9124, 75.7873),
      ]);
  RouteProfile delhiMumbai() => RouteProfile(points: const [
        GeoPoint(28.6139, 77.2090),
        GeoPoint(26.9124, 75.7873),
        GeoPoint(25.3407, 74.6313),
        GeoPoint(24.5854, 73.7125),
        GeoPoint(23.0225, 72.5714),
        GeoPoint(22.3072, 73.1812),
        GeoPoint(21.1702, 72.8311),
        GeoPoint(19.0760, 72.8777),
      ]);

  test('data has no junk and only plausible coordinates', () {
    expect(chargers.length, greaterThan(6000));
    for (final c in chargers) {
      expect(c.position.lat, inInclusiveRange(6, 38), reason: c.name);
      expect(c.position.lng, inInclusiveRange(68, 98), reason: c.name);
      expect(c.name.toLowerCase(), isNot(contains('dummy')));
    }
    expect(chargers.where((c) => RegExp(r'\btest\b', caseSensitive: false).hasMatch(c.name)), isEmpty);
  });

  test('a short trip on a full battery needs no stop', () async {
    final plan = await planner().plan(route: delhiJaipur(), fromKm: 0, soc: 100, energy: vf7);
    expect(plan.stops, isEmpty);
    expect(plan.strandedAtKm, isNull);
    expect(plan.arrivalSoc, greaterThan(25));
  });

  test('stops at a free charger close to the 25% point', () async {
    final route = delhiJaipur();
    const soc = 60.0;
    final plan = await planner().plan(route: route, fromKm: 0, soc: soc, energy: vf7);
    expect(plan.stops, isNotEmpty);
    final stop = plan.stops.first;
    expect(stop.place.charger.isFree, isTrue);
    expect(stop.arrivalSoc, inInclusiveRange(20, 45));
    final targetKm = (soc - 25) / vf7.socPerKm;
    // A faster charger is worth stopping a little further from the target.
    expect((stop.place.alongKm - targetKm).abs(), lessThan(40),
        reason: 'A dense corridor should offer one near the target');
    expect(stop.place.detourKm, lessThanOrEqualTo(15));
  });

  test('a 1400 km trip gets a sane chain of free stops', () async {
    final route = delhiMumbai();
    final plan = await planner().plan(route: route, fromKm: 0, soc: 80, energy: vf7);
    expect(plan.strandedAtKm, isNull);
    expect(plan.stops.length, greaterThanOrEqualTo(4));
    var lastKm = 0.0;
    for (final stop in plan.stops) {
      expect(stop.place.alongKm, greaterThan(lastKm));
      // A straight test line misses some towns, so one stop may be an emergency.
      expect(stop.arrivalSoc, greaterThanOrEqualTo(stop.belowFloor ? 3 : 20));
      expect(stop.departureSoc, greaterThanOrEqualTo(stop.arrivalSoc));
      expect(stop.departureSoc, lessThanOrEqualTo(80));
      lastKm = stop.place.alongKm;
    }
    expect(plan.arrivalSoc, greaterThanOrEqualTo(25));
  });

  test('finds corridor chargers quickly', () {
    final watch = Stopwatch()..start();
    final found = planner().freeChargersOnRoute(delhiMumbai());
    watch.stop();
    expect(found, isNotEmpty);
    expect(watch.elapsedMilliseconds, lessThan(1000));
  });
}
