// ignore_for_file: avoid_print
// Plans a real trip with every real source: Google route and chargers, Open-Meteo
// weather, the status feed and Statiq. Run with the key from config/keys.json:
//   dart run tool/check_trip_plan.dart [startSoc] [kWh/100 km at 80] [ratedRangeKm]
import 'dart:convert';
import 'dart:io';

import 'package:vinfast_copilot/core/air_along_route.dart';
import 'package:vinfast_copilot/core/charge_planner.dart';
import 'package:vinfast_copilot/core/charger.dart';
import 'package:vinfast_copilot/core/cruise_speed.dart';
import 'package:vinfast_copilot/core/energy.dart';
import 'package:vinfast_copilot/core/geo.dart';
import 'package:vinfast_copilot/data/charger_status_service.dart';
import 'package:vinfast_copilot/data/google_api.dart';
import 'package:vinfast_copilot/data/live_status_hub.dart';
import 'package:vinfast_copilot/data/statiq_service.dart';
import 'package:vinfast_copilot/data/weather_service.dart';

const _delhi = GeoPoint(28.6139, 77.2090);
const _jaipur = GeoPoint(26.9124, 75.7873);

Future<void> main(List<String> args) async {
  final soc = args.isNotEmpty ? double.parse(args[0]) : 80.0;
  final energy = EnergyModel(
    kwhPer100Km: args.length > 1 ? double.parse(args[1]) : 16,
    batteryKwh: 70.8,
    ratedRangeKm: args.length > 2 ? double.parse(args[2]) : 532,
  );
  final keys = jsonDecode(File('config/keys.json').readAsStringSync()) as Map<String, dynamic>;
  final api = GoogleApi(apiKey: keys['MAPS_API_KEY'] as String);
  final raw = jsonDecode(File('assets/free_chargers.json').readAsStringSync()) as List;
  final free = raw.map((e) => Charger.fromJson(e as Map<String, dynamic>)).toList();

  final route = await api.computeRoute(origin: _delhi, destination: _jaipur);
  print('Route ${route.totalKm.round()} km, ${route.durationSeconds ~/ 60} min');

  final air = await WeatherService().airAlong(route);
  print('Weather samples: ${air?.samples.length ?? 0}');
  for (final s in air?.samples.take(3) ?? const <AirSample>[]) {
    print('  ${s.air.temperatureC} C, wind ${s.air.windKmh} km/h from ${s.air.windFromDegrees}, '
        'density ${s.air.densityKgM3.toStringAsFixed(3)}');
  }
  final calm = route.socUsed(0, route.totalKm, energy);
  route.air = air;
  print('Trip needs ${route.socUsed(0, route.totalKm, energy).toStringAsFixed(1)}% with weather, '
      '${calm.toStringAsFixed(1)}% without');

  final google180 = await api.chargersAlongRoute(route, minKw: 180, pages: 3);
  print('Google 180 kW+ along the route: ${google180.length}');
  for (final c in google180) {
    final p = route.project(c.position);
    print('  km ${p.alongKm.round()} off ${p.offRouteKm.toStringAsFixed(1)} km: ${c.name}, '
        '${c.dcKw.round()} kW, ${c.dcCount} guns, free ${c.freeGuns}');
  }

  final status = ChargerStatusService();
  await status.refresh();
  final statiq = StatiqService();
  final hub = LiveStatusHub(feed: status, statiq: statiq)
    ..setStatiqStations(await statiq.loadStations(route.points), free);
  final planner = ChargePlanner(
    freeChargers: free,
    live: hub,
    searchUltraFast: (_) async => withoutDuplicates(google180, free),
    searchOtherChargers: (near, radiusKm) async =>
        withoutDuplicates(await api.chargersNear(near, radiusKm), free),
    checkDetour: (r, place) => api.realDetourKm(r, place.alongKm, place.charger.position),
  );
  final onRoad = await planner.ultraFastOnRoute(route);
  print('180 kW+ on the road (free list and Google): ${onRoad.length}');
  for (final c in onRoad) {
    print('  km ${c.alongKm.round()}: ${c.charger.name} (${c.charger.source.name}, ${c.charger.dcKw.round()} kW)');
  }

  for (final kw in [30.0, 60.0, 120.0, 180.0]) {
    String m(double a, double b) => energy.chargeMinutes(a, b, kw).round().toString();
    print('${kw.round()} kW: 10-70% ${m(10, 70)} min, 20-80% ${m(20, 80)}, 80-90% ${m(80, 90)}, 90-100% ${m(90, 100)}');
  }
  const rules = PlannerRules();
  final arriveWith = rules.destinationSocFor(route.totalKm);
  final plan0 = await planner.plan(route: route, fromKm: 0, soc: soc, energy: energy, destinationSoc: arriveWith);
  final kws = plan0.stops.map((s) => s.place.charger.dcKw > 0 ? s.place.charger.dcKw : 50).toList();
  final chargerKw = kws.isEmpty ? 60.0 : kws.reduce((a, b) => a + b) / kws.length;
  for (final kw in {chargerKw, 30.0, 60.0, 120.0, 180.0}) {
    final advice = CruiseAdvisor.advise(route: route, startSoc: soc, energy: energy, arriveWith: arriveWith,
        chargerKw: kw, reserveSoc: rules.reserveSoc, chargeToSoc: rules.chargeToSoc,
        stopOverheadMinutes: rules.stopOverheadMinutes);
    print('Cruise advice with ${kw.round()} kW stops: best ${advice.best.kmh.round()} km/h');
    for (final o in advice.options) {
      print('  ${o.kmh.round()}: drive ${o.driveMinutes.round()} + charge ${o.chargeMinutes.round()} '
          '(${o.stops} stops) = ${o.totalMinutes.round()} min, uses ${o.socUsed.round()}%');
    }
  }
  print('Open road: ${(route.openRoadShare * 100).round()}% of the route');
  final plan = plan0;
  print('Plan from $soc%:');
  for (final s in plan.stops) {
    print('  ${s.kind.name} at km ${s.place.alongKm.round()}: ${s.place.charger.name} '
        '(${s.place.charger.source.name}, ${s.place.charger.dcKw.round()} kW, detour '
        '${s.place.detourKm.toStringAsFixed(1)} km${s.detourVerified ? ' by road' : ''}), arrive '
        '${s.arrivalSoc.toStringAsFixed(1)}%, ${s.chargeMinutes} min to ${s.departureSoc.toStringAsFixed(1)}%'
        '${s.belowFloor ? ', BELOW FLOOR' : ''}. ${s.place.charger.availabilityNote ?? 'no status'}');
  }
  print('  arrive ${plan.arrivalSoc.toStringAsFixed(1)}%, stranded at ${plan.strandedAtKm}');
  exit(0);
}
