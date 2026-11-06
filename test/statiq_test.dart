import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinfast_copilot/core/battery_forecast.dart';
import 'package:vinfast_copilot/core/charger.dart';
import 'package:vinfast_copilot/core/energy.dart';
import 'package:vinfast_copilot/core/geo.dart';
import 'package:vinfast_copilot/core/live_status.dart';
import 'package:vinfast_copilot/core/route_profile.dart';
import 'package:vinfast_copilot/data/live_status_hub.dart';
import 'package:vinfast_copilot/data/statiq_service.dart';

const _kmPerDegree = 111.195;
GeoPoint _north(double km) => GeoPoint(10 + km / _kmPerDegree, 77);
const _energy = EnergyModel(kwhPer100Km: 20, batteryKwh: 100); // 0.2 % per km

Map<String, dynamic> _connector(bool availability, String status, {String error = 'Faulted', String type = 'CCS-2'}) =>
    {'availability': availability, 'connector_status': status, 'error_message': error, 'connector_type': type};

Map<String, dynamic> _plugin(List<Map<String, dynamic>> connectors,
        {String type = 'DC', double kw = 118, String lastUsed = '30/10/2026'}) =>
    {'type': type, 'power_rating': kw, 'connectors': connectors, 'last_used_on': lastUsed};

final _now = DateTime(2026, 10, 31, 12);
StationCheck _parse(Map<String, dynamic> s) => StatiqService.parseStation(s, _now);

void main() {
  group('reading Statiq health', () {
    test('your sample: two free CCS2 guns, despite the Faulted message', () {
      final check = _parse({
        'is_connected': true,
        'highest_power_rating': 238.0,
        'plugin_details': [
          _plugin([_connector(true, 'available'), _connector(true, 'available')]),
          _plugin([_connector(true, 'available', type: 'Type-2')], type: 'AC', kw: 13, lastUsed: '29/10/2026'),
        ],
      });
      expect(check.state, StationState.free);
      expect(check.freeGuns, 2);
      expect(check.totalGuns, 2);
      expect(check.kw, 118);
      expect(check.healthNote, 'Used yesterday');
    });

    test('disconnected is dead, even when connectors claim otherwise', () {
      for (final connector in [_connector(true, 'available'), _connector(false, 'charging')]) {
        final check = _parse({'is_connected': false, 'plugin_details': [_plugin([connector])]});
        expect(check.state, StationState.dead);
      }
    });

    test('charging and finishing mean busy', () {
      for (final status in ['charging', 'finishing']) {
        final check = _parse({'is_connected': true, 'plugin_details': [_plugin([_connector(false, status, error: 'Charging')])]});
        expect(check.state, StationState.busy, reason: status);
      }
    });

    test('faulted and unavailable connectors are dead', () {
      for (final status in ['faulted', 'unavailable']) {
        final check = _parse({'is_connected': true, 'plugin_details': [_plugin([_connector(false, status)])]});
        expect(check.state, StationState.dead, reason: status);
      }
    });

    test('one working gun among faulted ones is still usable', () {
      final check = _parse({'is_connected': true, 'plugin_details': [
        _plugin([_connector(false, 'faulted'), _connector(true, 'available')]),
      ]});
      expect(check.state, StationState.free);
      expect(check.freeGuns, 1);
      expect(check.totalGuns, 2);
    });

    test('an AC-only station is no use', () {
      final check = _parse({'is_connected': true, 'plugin_details': [
        _plugin([_connector(true, 'available', type: 'Type-2')], type: 'AC'),
      ]});
      expect(check.state, StationState.dead);
    });

    test('says how long ago it was used, when it can', () {
      String? note(String date) => _parse({'is_connected': true, 'plugin_details': [
            _plugin([_connector(true, 'available')], lastUsed: date),
          ]}).healthNote;
      expect(note('31/10/2026'), 'Used today');
      expect(note('01/10/2026'), 'Last used 30 days ago');
      expect(note(''), isNull);
    });
  });

  test('map request covers the route, asks for CCS2, and sends no browser identity', () async {
    late http.Request sent;
    final service = StatiqService(client: MockClient((r) async {
      sent = r;
      return http.Response(jsonEncode({'data': {'stations': [
        {'station_id': 1159, 'station_name': 'Galleria', 'latitude': 28.4, 'longitude': 77.0, 'address': 'DLF'},
        {'station_name': 'no id', 'latitude': 28.4, 'longitude': 77.0},
      ]}}), 200);
    }));
    final stations = await service.loadStations(const [GeoPoint(28, 77), GeoPoint(26, 75)]);
    expect(stations.single.id, '1159');
    expect(stations.single.address, 'DLF');
    expect(sent.url.toString(), 'https://backend.statiq.co.in/station/v1/markers');
    expect(sent.headers.keys.map((k) => k.toLowerCase()), isNot(contains('origin')));
    final body = jsonDecode(sent.body);
    expect(body['connector_id'], [1]);
    final corners = (body['vertices'] as List).cast<List>();
    expect(corners.first, corners.last, reason: 'A closed ring');
    final lngs = corners.map((c) => c[0] as num), lats = corners.map((c) => c[1] as num);
    expect(lngs.reduce((a, b) => a < b ? a : b), lessThan(75));
    expect(lngs.reduce((a, b) => a > b ? a : b), greaterThan(77));
    expect(lats.reduce((a, b) => a < b ? a : b), lessThan(26));
    expect(lats.reduce((a, b) => a > b ? a : b), greaterThan(28));
  });

  test('a failed map request just means no Statiq stations', () async {
    final service = StatiqService(client: MockClient((_) async => throw Exception('slow')));
    expect(await service.loadStations(const [GeoPoint(28, 77)]), isEmpty);
    expect(await service.check('12'), isNull);
    expect(await service.check('not-a-number'), isNull);
  });

  group('road-aware energy and time', () {
    RouteProfile road({int duration = 0}) => RouteProfile(
          points: [const GeoPoint(10, 77), _north(300)],
          durationSeconds: duration,
          speedBands: const [
            SpeedBand(0, 100, 40), // city
            SpeedBand(100, 200, 70), // highway
            SpeedBand(200, 400, 110), // expressway
          ],
        );

    test('with no speed data everything is flat, as before', () {
      final route = RouteProfile(points: [const GeoPoint(10, 77), _north(300)]);
      expect(route.socUsed(0, 100, _energy), closeTo(20, 0.1));
      expect(route.kmAfterSoc(0, 20, _energy), closeTo(100, 0.5));
    });

    test('expressways cost more than the 80 km/h figure, towns pay for their stops', () {
      final route = road();
      expect(route.socUsed(0, 50, _energy), closeTo(50 * 0.2 * _energy.factorAt(40, stopStart: true), 0.05));
      expect(route.socUsed(100, 150, _energy), closeTo(50 * 0.2 * _energy.factorAt(70), 0.05));
      expect(route.socUsed(200, 250, _energy), closeTo(50 * 0.2 * _energy.factorAt(110), 0.05));
      expect(_energy.factorAt(40, stopStart: true), greaterThan(_energy.factorAt(40)));
      expect(_energy.factorAt(70), lessThan(1));
      expect(_energy.factorAt(110), greaterThan(1.2));
    });

    test('kmAfterSoc reverses socUsed across road types', () {
      final route = road();
      for (final soc in [5.0, 30.0, 45.0]) {
        final km = route.kmAfterSoc(20, soc, _energy);
        expect(route.socUsed(20, km, _energy), closeTo(soc, 0.05));
      }
    });

    test('congestion slows time and shifts consumption', () {
      final clear = road();
      final jammed = RouteProfile(
        points: [const GeoPoint(10, 77), _north(300)],
        speedBands: clear.speedBands,
        trafficBands: const [TrafficBand(200, 400, 0.1)], // 11 km/h crawl
      );
      expect(jammed.secondsBetween(200, 250), greaterThan(clear.secondsBetween(200, 250) * 5));
      expect(jammed.socUsed(200, 250, _energy), lessThan(clear.socUsed(200, 250, _energy)));
    });

    test('times add up to Google\'s predicted total but keep the road shape', () {
      final route = road(duration: 3 * 3600);
      expect(route.secondsBetween(0, route.totalKm), closeTo(3 * 3600, 2));
      expect(route.secondsBetween(0, 50), greaterThan(route.secondsBetween(220, 270) * 2));
    });
  });

  group('30% forecast', () {
    final route = RouteProfile(
      points: [const GeoPoint(10, 77), _north(500)],
      durationSeconds: 5 * 3600,
      speedBands: const [SpeedBand(0, 200, 60), SpeedBand(200, 600, 110)],
    );

    BatteryForecast? at(double soc, {double progress = 0, double scale = 1}) => forecastBatteryLevel(
        route: route, progressKm: progress, soc: soc, energy: _energy, level: 30, timeScale: scale);

    // 80 to 30 is 50%. The first 200 km cost less than the 80 km/h figure, then
    // the rest goes at the dearer expressway rate.
    final firstPart = 200 * 0.2 * _energy.factorAt(60);
    final expectedKm = 200 + (50 - firstPart) / (0.2 * _energy.factorAt(110));

    test('finds the point, accounting for costlier expressway ahead', () {
      final f = at(80)!;
      expect(f.km, closeTo(expectedKm, 1));
      expect(f.roadKind, RoadKind.expressway);
      expect(distanceKm(f.position, _north(f.km)), lessThan(1));
    });

    test('moves as the car drives', () {
      final soFar = route.socUsed(0, 50, _energy);
      expect(at(80 - soFar, progress: 50)!.km, closeTo(expectedKm, 1));
    });

    test('null when the battery stays above the level', () {
      expect(at(100, progress: 450), isNull);
    });

    test('already below means here and now', () {
      final f = at(25, progress: 40)!;
      expect(f.km, 40);
      expect(f.secondsAway, 0);
    });

    test('live traffic stretches the arrival time, not the place', () {
      final normal = at(80)!, late = at(80, scale: 1.5)!;
      expect(late.km, normal.km);
      expect(late.secondsAway, closeTo(normal.secondsAway * 1.5, 2));
    });
  });

  group('merging sources', () {
    LiveStation station(String id, String name, GeoPoint at) =>
        LiveStation(id: id, name: name, position: at, available: false);
    Charger csv(String id, String name, GeoPoint at) =>
        Charger(id: id, name: name, position: at, dcKw: 60);
    const here = GeoPoint(28.5, 77.2);
    const m100 = GeoPoint(28.5009, 77.2);

    StatiqService service({StationCheck? Function(String id)? check}) => _FixedStatiq(check ?? (_) => null);
    LiveStatusHub hubWith({StatiqService? statiq, DateTime Function()? clock}) =>
        LiveStatusHub(feed: _NoFeed(), statiq: statiq ?? service(), clock: clock);

    test('the same site in the CSV and Statiq becomes one record', () {
      final hub = hubWith();
      hub.setStatiqStations([station('7', 'Earthtron EV Sector 15', m100)], [csv('c', 'EARTHTRON EV Sector 15 Faridabad', here)]);
      expect(hub.statiqOnlyChargers, isEmpty);
    });

    test('several Statiq ids at one address stay separate chargers', () {
      final hub = hubWith();
      hub.setStatiqStations([station('1', 'Hub', here), station('2', 'Hub', here), station('3', 'Hub', here)], const []);
      expect(hub.statiqOnlyChargers.length, 3);
    });

    test('one CSV record claims only one of them, so guns are not lost or doubled', () {
      final hub = hubWith();
      hub.setStatiqStations([station('1', 'Hub', here), station('2', 'Hub', here)], [csv('c', 'Hub', here)]);
      expect(hub.statiqOnlyChargers.length, 1);
    });

    test('two CSV ids at one spot do not share a station', () {
      final matcher = StationMatcher([station('s', 'Hub', here)]);
      expect(matcher.match(csv('a', 'Hub', here)), isNotNull);
      expect(matcher.match(csv('b', 'Hub', here)), isNull);
      expect(matcher.match(csv('a', 'Hub', here)), isNotNull, reason: 'Same id keeps its match');
    });

    test('a Google result for a known site is dropped, a new one is kept', () {
      final known = csv('c', 'Tata Power Sector 15', here);
      final dup = Charger(id: 'places:1', name: 'Tata Power Charging', position: m100, dcKw: 60, source: ChargerSource.other);
      final other = Charger(id: 'places:2', name: 'Relux Hub', position: _north(5), dcKw: 60, source: ChargerSource.other);
      expect(withoutDuplicates([dup, other], [known]).map((c) => c.id), ['places:2']);
    });

    test('Statiq status reaches the same charger through a CSV link', () async {
      final hub = hubWith(statiq: service(check: (_) => const StationCheck(StationState.dead)));
      final c = csv('c', 'Hub', here);
      hub.setStatiqStations([station('1', 'Hub', here)], [c]);
      expect(hub.statusOf(c), LiveStatus.unknown);
      expect((await hub.check(c))!.state, StationState.dead);
      expect(hub.statusOf(c), LiveStatus.unavailable);
    });
  });

  group('monitoring', () {
    final route = RouteProfile(points: [const GeoPoint(10, 77), _north(400)]);
    LiveStation station(String id, double km, {double offRoute = 0}) => LiveStation(
        id: id, name: 'S$id', available: false,
        position: GeoPoint(10 + km / _kmPerDegree, 77 + offRoute / (_kmPerDegree * 0.98)));

    test('watches only stations within 20 km of the point and 6 km of the route', () async {
      final asked = <String>[];
      final hub = LiveStatusHub(feed: _NoFeed(), statiq: _FixedStatiq((id) {
        asked.add(id);
        return const StationCheck(StationState.free, freeGuns: 1, totalGuns: 1);
      }));
      hub.setStatiqStations([
        station('near', 205),
        station('edge', 219),
        station('before', 185),
        station('a', 195),
        station('b', 210),
        station('far', 230),
        station('off', 200, offRoute: 8),
      ], const []);
      hub.watchAround(route, 200, 20);
      await hub.checkWatched();
      expect(asked.toSet(), {'near', 'edge', 'before', 'a', 'b'});
      expect(hub.watchedCount, 5);
      expect(hub.healthyWatchedCount, 5);
    });

    test('unchecked stations are not counted as unhealthy', () async {
      final hub = LiveStatusHub(feed: _NoFeed(), statiq: _FixedStatiq((id) =>
          id == 'a' ? const StationCheck(StationState.dead) : null));
      hub.setStatiqStations([station('a', 200), station('b', 205)], const []);
      hub.watchAround(route, 200, 20);
      expect(hub.checkedWatchedCount, 0);
      await hub.checkWatched();
      expect(hub.checkedWatchedCount, 1, reason: "b's check failed");
      expect(hub.healthyWatchedCount, 0);
    });

    test('on a bare stretch it watches the nearest stations instead of nothing', () {
      final hub = LiveStatusHub(feed: _NoFeed(), statiq: _FixedStatiq((_) => null));
      hub.setStatiqStations([for (final k in [20, 40, 60, 80, 100, 120, 330]) station('s$k', k.toDouble())], const []);
      hub.watchAround(route, 200, 20);
      expect(hub.watchedCount, 5);
    });

    test('stations already behind the car are not watched', () async {
      final asked = <String>[];
      final hub = LiveStatusHub(feed: _NoFeed(), statiq: _FixedStatiq((id) {
        asked.add(id);
        return null;
      }));
      hub.setStatiqStations([for (var k = 0; k < 8; k++) station('s$k', 185.0 + k * 5)], const []);
      hub.watchAround(route, 200, 20, fromKm: 195);
      await hub.checkWatched();
      expect(asked.toSet(), {'s2', 's3', 's4', 's5', 's6', 's7'});
    });

    test('caps how many it watches, nearest first', () {
      final hub = LiveStatusHub(feed: _NoFeed(), statiq: _FixedStatiq((_) => null));
      hub.setStatiqStations([for (var k = 0; k < 50; k++) station('s$k', 190 + k * 0.4)], const []);
      hub.watchAround(route, 200, 20);
      expect(hub.watchedCount, 30);
    });

    test('a station going down is noticed, and old results stop counting', () async {
      var state = StationState.free;
      var clock = _now;
      final hub = LiveStatusHub(
        feed: _NoFeed(),
        clock: () => clock,
        statiq: _FixedStatiq((_) => StationCheck(state, freeGuns: 1, totalGuns: 1)),
      );
      final charger = Charger(id: 'statiq:a', name: 'Sa', position: _north(200), dcKw: 0, source: ChargerSource.statiq);
      hub.setStatiqStations([station('a', 200)], const []);
      hub.watchAround(route, 200, 20);
      await hub.checkWatched();
      expect(hub.statusOf(charger), LiveStatus.available);
      state = StationState.dead;
      await hub.checkWatched();
      expect(hub.statusOf(charger), LiveStatus.unavailable);
      clock = _now.add(const Duration(minutes: 11));
      expect(hub.statusOf(charger), LiveStatus.unknown);
    });

    test('only due checks skip stations checked moments ago', () async {
      var calls = 0;
      final hub = LiveStatusHub(feed: _NoFeed(), statiq: _FixedStatiq((_) {
        calls++;
        return const StationCheck(StationState.free);
      }));
      hub.setStatiqStations([station('a', 200)], const []);
      hub.watchAround(route, 200, 20);
      await hub.checkWatched();
      await hub.checkWatched(onlyDue: true);
      expect(calls, 1);
      await hub.checkWatched();
      expect(calls, 2);
    });

    test('a check says how fresh it is', () async {
      var clock = _now;
      final hub = LiveStatusHub(feed: _NoFeed(), clock: () => clock, statiq: _FixedStatiq((_) =>
          const StationCheck(StationState.free, healthNote: 'Used today')));
      final charger = Charger(id: 'statiq:a', name: 'Sa', position: _north(200), dcKw: 0, source: ChargerSource.statiq);
      hub.setStatiqStations([station('a', 200)], const []);
      expect((await hub.check(charger))!.healthNote, 'Used today · Checked just now');
      clock = _now.add(const Duration(seconds: 90));
      expect((await hub.check(charger))!.healthNote, 'Used today · Checked 1 min ago');
    });
  });
}

class _FixedStatiq extends StatiqService {
  _FixedStatiq(this.answer);
  final StationCheck? Function(String id) answer;

  @override
  Future<StationCheck?> check(String stationId) async => answer(stationId);
}

class _NoFeed extends LiveStatusSource {
  @override
  LiveStatus statusOf(Charger charger) => LiveStatus.unknown;

  @override
  Future<StationCheck?> check(Charger charger) async => null;
}
