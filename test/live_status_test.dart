import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinfast_copilot/core/charge_planner.dart';
import 'package:vinfast_copilot/core/charger.dart';
import 'package:vinfast_copilot/core/energy.dart';
import 'package:vinfast_copilot/core/geo.dart';
import 'package:vinfast_copilot/core/live_status.dart';
import 'package:vinfast_copilot/core/route_profile.dart';
import 'package:vinfast_copilot/data/charger_status_service.dart';

const _kmPerDegree = 111.195;
GeoPoint _north(double km) => GeoPoint(10 + km / _kmPerDegree, 77);
Charger _at(double km, {String? id, double kw = 60}) =>
    Charger(id: id ?? 'c$km', name: 'Charger $km', position: _north(km), dcKw: kw);
const _energy = EnergyModel(kwhPer100Km: 20, batteryKwh: 100); // 0.2 % per km

class _FakeLive extends LiveStatusSource {
  _FakeLive({this.status = const {}, this.checks = const {}});
  final Map<String, LiveStatus> status;
  final Map<String, StationCheck?> checks;
  final checked = <String>[];

  @override
  LiveStatus statusOf(Charger c) => status[c.id] ?? LiveStatus.unknown;

  @override
  Future<StationCheck?> check(Charger c) async {
    checked.add(c.id);
    return checks[c.id];
  }
}

Map<String, dynamic> _connector(bool available, {String? label, String type = 'IEC_62196_T2_COMBO', String current = 'DC'}) =>
    {'available': available, 'statusLabel': ?label, 'connectorType': type, 'currentType': current};

void main() {
  group('matching', () {
    LiveStation station(String name, GeoPoint at) =>
        LiveStation(id: name, name: name, position: at, available: true);
    Charger charger(String name, GeoPoint at) =>
        Charger(id: name, name: name, position: at, dcKw: 60);
    const here = GeoPoint(28.5, 77.2);
    const m60 = GeoPoint(28.50054, 77.2); // About 60 m north.
    const m500 = GeoPoint(28.5045, 77.2); // About 500 m north.

    test('identical coordinates match even when the names differ', () {
      final m = StationMatcher([station('Totally Different', here)]);
      expect(m.match(charger('G.V.K. FUELS', here))?.name, 'Totally Different');
    });

    test('nearby different sites do not match', () {
      final m = StationMatcher([station('TN | Chennai | The Westin', m60)]);
      expect(m.match(charger('Muneesar Agencies', here)), isNull);
    });

    test('nearby with a similar name matches', () {
      final m = StationMatcher([station('Okhla NSIC Metro Station', m60)]);
      expect(m.match(charger('OKHLA NSIC METRO', here))?.name, 'Okhla NSIC Metro Station');
    });

    test('the same name far away does not match', () {
      final m = StationMatcher([station('Hotel Green', m500)]);
      expect(m.match(charger('Hotel Green', here)), isNull);
    });

    test('takes the closest of several candidates', () {
      final m = StationMatcher([station('Hotel Green Two', m60), station('Hotel Green', here)]);
      expect(m.match(charger('Hotel Green', here))?.name, 'Hotel Green');
    });
  });

  group('reading a station', () {
    StationState? state(Map<String, dynamic> s) => ChargerStatusService.parseStation(s)?.state;

    test('your example response: both guns free', () {
      final check = ChargerStatusService.parseStation({
        'availableCount': 2,
        'connectors': [_connector(true), _connector(true)],
      })!;
      expect(check.state, StationState.free);
      expect(check.note, '2 of 2 free now');
    });

    test('in use is busy, not dead', () {
      expect(state({'connectors': [_connector(false, label: 'In use')]}), StationState.busy);
    });

    for (final label in ['Out of service', 'Coming soon', 'Status unknown', 'Blocked']) {
      test('$label is dead', () {
        expect(state({'connectors': [_connector(false, label: label)]}), StationState.dead);
      });
    }

    test('a free AC socket does not make a dead DC station usable', () {
      expect(
          state({'connectors': [
            _connector(true, type: 'IEC_62196_T2', current: 'AC'),
            _connector(false, label: 'Out of service'),
          ]}),
          StationState.dead);
    });

    test('an AC-only station is no use', () {
      expect(state({'connectors': [_connector(true, type: 'IEC_62196_T2', current: 'AC')]}), StationState.dead);
    });

    test('upcoming is dead, and no connectors at all says nothing', () {
      expect(state({'isUpcoming': true, 'connectors': const []}), StationState.dead);
      expect(state({'connectors': const []}), isNull);
    });
  });

  group('the feed', () {
    final now = DateTime.utc(2026, 10, 31, 12);
    final charger = _at(100);

    String discovery({required bool available, DateTime? updatedAt}) => jsonEncode({
          'updatedAt': (updatedAt ?? now).toIso8601String(),
          'stations': [
            {'id': 'abc', 'name': charger.name, 'latitude': charger.position.lat,
              'longitude': charger.position.lng, 'connectors': [], 'available': available},
          ],
        });

    test('reports status, and calls the right URLs', () async {
      final urls = <String>[];
      final service = ChargerStatusService(clock: () => now, client: MockClient((r) async {
        urls.add(r.url.toString());
        return r.url.path.endsWith('discovery')
            ? http.Response(discovery(available: true), 200)
            : http.Response(jsonEncode({'station': {'connectors': [_connector(true)]}}), 200);
      }));
      expect(service.statusOf(charger), LiveStatus.unknown);
      await service.refresh();
      expect(service.statusOf(charger), LiveStatus.available);
      expect(service.statusOf(_at(300)), LiveStatus.unknown);
      expect((await service.check(charger))!.state, StationState.free);
      expect(await service.check(_at(300)), isNull);
      expect(urls, [
        'https://chargeindia.com/api/stations/discovery',
        'https://chargeindia.com/api/stations/abc',
      ]);
    });

    test('old data stops counting, so it cannot hide chargers forever', () async {
      var clock = now;
      final service = ChargerStatusService(clock: () => clock,
          client: MockClient((_) async => http.Response(discovery(available: false), 200)));
      await service.refresh();
      expect(service.statusOf(charger), LiveStatus.unavailable);
      clock = now.add(const Duration(minutes: 31));
      expect(service.statusOf(charger), LiveStatus.unknown);
    });

    test('a failed refresh keeps the last good data', () async {
      var fail = false;
      final service = ChargerStatusService(clock: () => now, client: MockClient((_) async {
        if (fail) throw Exception('offline');
        return http.Response(discovery(available: true), 200);
      }));
      await service.refresh();
      fail = true;
      await service.refresh();
      expect(service.statusOf(charger), LiveStatus.available);
      expect(await service.check(charger), isNull);
    });

    test('garbage or errors mean unknown, never a crash', () async {
      for (final response in [http.Response('<html>', 200), http.Response('nope', 500), http.Response('{}', 200)]) {
        final service = ChargerStatusService(clock: () => now, client: MockClient((_) async => response));
        await service.refresh();
        expect(service.statusOf(charger), LiveStatus.unknown);
      }
    });
  });

  group('planning with live status', () {
    // 75% start: reaches 25% at 250 km. 180 km/h average makes 15 minutes 45 km.
    final route = RouteProfile(
      points: [const GeoPoint(10, 77), _north(600)],
      durationSeconds: (600 / 180 * 3600).round(),
    );

    ChargePlanner planner(List<Charger> free, _FakeLive live, {List<Charger> other = const []}) =>
        ChargePlanner(
          freeChargers: free,
          live: live,
          searchOtherChargers: (_, _) async => other,
          checkDetour: (_, _) async => null,
        );

    Future<ChargePlan> run(ChargePlanner p, {double soc = 75, double from = 0}) =>
        p.plan(route: route, fromKm: from, soc: soc, energy: _energy);

    test('a dead charger on target is skipped for the next one', () async {
      final live = _FakeLive(
        status: {'dead': LiveStatus.unavailable},
        checks: {'dead': const StationCheck(StationState.dead)},
      );
      final plan = await run(planner([_at(250, id: 'dead'), _at(230, id: 'ok')], live));
      expect(plan.stops.first.place.charger.id, 'ok');
      expect(plan.stops.first.place.charger.availabilityNote, isNull);
    });

    test('dead chargers are not on the map, and confirmed ones say so', () {
      final live = _FakeLive(status: {'dead': LiveStatus.unavailable, 'up': LiveStatus.available});
      final shown = planner([_at(100, id: 'dead'), _at(120, id: 'up'), _at(140, id: 'unknown')], live)
          .freeChargersOnRoute(route);
      expect(shown.map((c) => c.charger.id), ['up', 'unknown']);
      expect(shown.first.charger.availabilityNote, 'Available now');
      expect(shown.last.charger.availabilityNote, isNull);
    });

    test('prefers a confirmed charger slightly further from the target', () async {
      final live = _FakeLive(status: {'up': LiveStatus.available},
          checks: {'up': const StationCheck(StationState.free, note: '2 of 2 free now')});
      final plan = await run(planner([_at(250, id: 'unknown'), _at(238, id: 'up')], live));
      expect(plan.stops.first.place.charger.id, 'up');
      expect(plan.stops.first.place.charger.availabilityNote, '2 of 2 free now');
    });

    test('chargers missing from the feed are still used', () async {
      final plan = await run(planner([_at(250, id: 'unknown')], _FakeLive()));
      expect(plan.stops.first.place.charger.id, 'unknown');
    });

    test('a busy charger far enough away is acceptable', () async {
      final live = _FakeLive(status: {'busy': LiveStatus.unavailable},
          checks: {'busy': const StationCheck(StationState.busy, note: 'In use now')});
      final plan = await run(planner([_at(250, id: 'busy')], live));
      expect(plan.stops.first.place.charger.id, 'busy');
      expect(plan.stops.first.place.charger.availabilityNote, 'In use now, 83 min away');
    });

    test('a busy charger just ahead is not, so a paid one is used', () async {
      final live = _FakeLive(status: {'busy': LiveStatus.unavailable},
          checks: {'busy': const StationCheck(StationState.busy, note: 'In use now')});
      final paid = Charger(id: 'paid', name: 'Paid', position: _north(235), dcKw: 60, source: ChargerSource.other);
      final plan = await run(planner([_at(240, id: 'busy')], live, other: [paid]), soc: 30, from: 225);
      expect(plan.stops.first.place.charger.id, 'paid');
    });

    test('a failed check still lets a charger with no bad report through', () async {
      final live = _FakeLive(); // check returns null
      final plan = await run(planner([_at(250, id: 'x')], live));
      expect(plan.stops.first.place.charger.id, 'x');
    });

    test('a failed check does not clear a charger reported down', () async {
      final live = _FakeLive(status: {'down': LiveStatus.unavailable});
      final plan = await run(planner([_at(250, id: 'down')], live));
      expect(plan.stops, isEmpty);
      expect(plan.strandedAtKm, isNotNull);
    });

    test('only checks the few it may suggest, not every charger', () async {
      final live = _FakeLive(checks: {for (var k = 170; k < 280; k += 2) 'c$k.0': const StationCheck(StationState.dead)});
      await run(planner([for (var k = 170; k < 280; k += 2) _at(k.toDouble())], live));
      // 12 above the floor, then a second look below it before giving up.
      expect(live.checked.length, lessThanOrEqualTo(24));
    });
  });
}
