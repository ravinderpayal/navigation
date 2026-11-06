import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinfast_copilot/core/air_along_route.dart';
import 'package:vinfast_copilot/core/energy.dart';
import 'package:vinfast_copilot/core/geo.dart';
import 'package:vinfast_copilot/core/route_profile.dart';
import 'package:vinfast_copilot/data/weather_service.dart';

const _kmPerDegree = 111.195;
GeoPoint _north(double km) => GeoPoint(10 + km / _kmPerDegree, 77);

// A VF 7 as a driver might describe it.
const _vf7 = EnergyModel(kwhPer100Km: 16, batteryKwh: 70.8, ratedRangeKm: 532, dragCd: 0.29);

void main() {
  group('consumption curve', () {
    test('80 km/h is exactly the driver\'s figure', () {
      expect(_vf7.kwhPer100At(80), closeTo(16, 1e-9));
      expect(_vf7.factorAt(80), closeTo(1, 1e-9));
    });

    test('passes through the ARAI range as drivers really get it, three quarters of it', () {
      // ARAI's cycle averages about 34 km/h and includes stops.
      const car = EnergyModel(kwhPer100Km: 16, batteryKwh: 70.8, ratedRangeKm: 600);
      expect(car.kwhPer100At(34, stopStart: true), closeTo(70.8 / (600 * 0.75) * 100, 0.01));
    });

    test('an EPA figure is already real-world, so it\'s taken as it is', () {
      const car = EnergyModel(kwhPer100Km: 16, batteryKwh: 70.8, ratedRangeKm: 480, rating: RangeRating.epa);
      expect(car.kwhPer100At(48, stopStart: true), closeTo(70.8 / 480 * 100, 0.01));
    });

    test('town driving costs more than the lab figure suggests', () {
      // VF 7: ARAI says 13.3 kWh/100 km; town with stops and AC is well above that.
      expect(_vf7.kwhPer100At(30, stopStart: true), greaterThan(17));
      expect(_vf7.kwhPer100At(30, stopStart: true), greaterThan(_vf7.kwhPer100At(80)));
    });

    test('stops cost what speeding up takes, less what regenerative braking wins back', () {
      // 2.1 t from 35 km/h: 99 kJ in, 60% of it back out.
      final one = _vf7.kineticKwh(0, 35) + _vf7.kineticKwh(35, 0);
      expect(one * 3600, closeTo(99.2 / 0.9 - 99.2 * 0.6, 1));
      expect(_vf7.stopStartKwhPer100, closeTo(1.5 * 100 * one, 1e-9));
      expect(_vf7.stopStartKwhPer100, inInclusiveRange(1.5, 3));
    });

    test('drag makes each step up in speed cost more than the last', () {
      final at100 = _vf7.kwhPer100At(100), at120 = _vf7.kwhPer100At(120);
      expect(at100, greaterThan(16));
      expect(at120 - at100, greaterThan(at100 - 16));
      expect(_vf7.factorAt(120), inInclusiveRange(1.3, 1.7));
    });

    test('crawling costs more per km than a steady 40, because the AC keeps running', () {
      expect(_vf7.kwhPer100At(10), greaterThan(_vf7.kwhPer100At(40)));
    });

    test('a slipperier car loses less at speed', () {
      const sleek = EnergyModel(kwhPer100Km: 16, batteryKwh: 70.8, ratedRangeKm: 532, dragCd: 0.24);
      const boxy = EnergyModel(kwhPer100Km: 16, batteryKwh: 70.8, ratedRangeKm: 532, dragCd: 0.36);
      expect(sleek.factorAt(120), lessThan(boxy.factorAt(120)));
    });

    test('thin air and a tailwind help, a headwind hurts', () {
      const leh = AirConditions(densityKgM3: 0.85);
      expect(_vf7.factorAt(100, air: leh), lessThan(_vf7.factorAt(100)));
      expect(_vf7.factorAt(100, headwindKmh: 20), greaterThan(_vf7.factorAt(100)));
      expect(_vf7.factorAt(100, headwindKmh: -20), lessThan(_vf7.factorAt(100)));
    });

    test('an implausible rated range keeps accessories within bounds', () {
      const optimistic = EnergyModel(kwhPer100Km: 16, batteryKwh: 70.8, ratedRangeKm: 1400);
      const pessimistic = EnergyModel(kwhPer100Km: 16, batteryKwh: 70.8, ratedRangeKm: 150);
      expect(optimistic.accessoryKw, 0.3);
      expect(pessimistic.accessoryKw, 3.0);
      expect(optimistic.factorAt(80), closeTo(1, 1e-9));
    });

    test('matches VinFast\'s 10-70% in about 25 minutes on a fast charger', () {
      expect(_vf7.chargeMinutes(10, 70, 180), inInclusiveRange(23, 26));
      // The car is the limit there, so a faster charger doesn't help.
      expect(_vf7.chargeMinutes(10, 70, 360), _vf7.chargeMinutes(10, 70, 180));
    });

    test('charging crawls past 75%', () {
      final early = _vf7.chargeMinutes(20, 25, 180), late = _vf7.chargeMinutes(75, 80, 180);
      expect(late, greaterThan(early * 1.5));
      expect(_vf7.chargeMinutes(80, 100, 180), greaterThan(_vf7.chargeMinutes(20, 60, 180)));
    });

    test('a slow charger is the limit until the car\'s own taper drops below it', () {
      // 42.5 kWh at 90% of 30 kW.
      expect(_vf7.chargeMinutes(20, 80, 30), closeTo(42.48 / 27 * 60, 0.5));
    });

    test('the car\'s own peak caps a fast charger', () {
      const capped = EnergyModel(kwhPer100Km: 16, batteryKwh: 70.8, maxChargeKw: 50);
      expect(capped.chargeMinutes(20, 50, 180), closeTo(21.24 / 50 * 60, 0.1));
      expect(capped.peakChargeKw, 50);
      expect(_vf7.peakChargeKw, EnergyModel.defaultMaxChargeKw);
    });

    test('charging for the minutes a range takes reaches the end of it, never past the cap', () {
      final minutes = _vf7.chargeMinutes(30, 70, 60);
      expect(_vf7.socAfterCharging(30, minutes, 60), closeTo(70, 0.01));
      expect(_vf7.socAfterCharging(30, 500, 60, maxSoc: 80), 80);
    });

    test('a burn scale changes predictions but not the curve', () {
      final scaled = _vf7.withBurnScale(1.2);
      expect(scaled.socPerKm, closeTo(_vf7.socPerKm * 1.2, 1e-12));
      expect(scaled.curveKey, _vf7.curveKey);
    });
  });

  group('air', () {
    test('standard air from the weather comes out at the textbook density', () {
      final air = AirConditions.fromWeather(temperatureC: 15, relativeHumidity: 0, pressureHpa: 1013.25);
      expect(air.densityKgM3, closeTo(1.225, 0.002));
    });

    test('hot, humid plains air is thinner', () {
      final air = AirConditions.fromWeather(temperatureC: 35, relativeHumidity: 70, pressureHpa: 1000);
      expect(air.densityKgM3, closeTo(1.12, 0.01));
    });

    test('headwind depends on where the wind comes from', () {
      const northerly = AirConditions(densityKgM3: 1.2, windKmh: 20, windFromDegrees: 0);
      expect(northerly.headwindKmh(0), closeTo(14, 0.01), reason: '70% of 10 m wind, straight on');
      expect(northerly.headwindKmh(180), closeTo(-14, 0.01));
      expect(northerly.headwindKmh(90).abs(), lessThan(0.01));
    });
  });

  group('weather along a route', () {
    RouteProfile road() => RouteProfile(
          points: [const GeoPoint(10, 77), _north(200)],
          speedBands: const [SpeedBand(0, 300, 100)],
        );

    test('a headwind makes the same road cost more, and the route updates', () {
      final route = road();
      final calm = route.socUsed(0, 200, _vf7);
      route.air = AirAlongRoute([
        AirSample(_north(100), const AirConditions(densityKgM3: 1.2, windKmh: 30, windFromDegrees: 0)),
      ]);
      expect(route.socUsed(0, 200, _vf7), greaterThan(calm * 1.05));
      route.air = AirAlongRoute([
        AirSample(_north(100), const AirConditions(densityKgM3: 1.2, windKmh: 30, windFromDegrees: 180)),
      ]);
      expect(route.socUsed(0, 200, _vf7), lessThan(calm * 0.95));
    });

    test('kmAfterSoc still reverses socUsed with weather', () {
      final route = road()
        ..air = AirAlongRoute([AirSample(_north(50), AirConditions.fromWeather(
            temperatureC: 38, relativeHumidity: 30, pressureHpa: 980, windKmh: 25, windFromDegrees: 20))]);
      final km = route.kmAfterSoc(10, 30, _vf7);
      expect(route.socUsed(10, km, _vf7), closeTo(30, 0.05));
    });

    test('Open-Meteo: asks for every sample point at once and reads the list back', () async {
      late Uri sent;
      final service = WeatherService(client: MockClient((r) async {
        sent = r.url;
        final count = r.url.queryParameters['latitude']!.split(',').length;
        return http.Response(jsonEncode([
          for (var i = 0; i < count; i++)
            {'current': {'temperature_2m': 30.0 + i, 'relative_humidity_2m': 40, 'surface_pressure': 990.0,
              'wind_speed_10m': 12.0, 'wind_direction_10m': 270}},
        ]), 200);
      }));
      final air = await service.airAlong(road());
      expect(sent.host, 'api.open-meteo.com');
      expect(sent.queryParameters['current'], contains('surface_pressure'));
      expect(sent.queryParameters['wind_speed_unit'], 'kmh');
      final count = sent.queryParameters['latitude']!.split(',').length;
      expect(count, sent.queryParameters['longitude']!.split(',').length);
      expect(count, greaterThanOrEqualTo(9), reason: 'every 25 km over 200 km, plus the end');
      expect(air!.samples.length, count);
      expect(air.nearest(_north(0))!.temperatureC, 30);
      expect(air.nearest(_north(200))!.windKmh, 12);
    });

    test('Open-Meteo: one location comes back as a single object', () {
      final samples = WeatherService.parse({
        'current': {'temperature_2m': 20.0, 'relative_humidity_2m': 50, 'surface_pressure': 1000.0},
      }, const [GeoPoint(28, 77)]);
      expect(samples.single.air.windKmh, 0);
    });

    test('Open-Meteo down means no weather, not a broken trip', () async {
      final down = WeatherService(client: MockClient((_) async => http.Response('busy', 503)));
      expect(await down.airAlong(road()), isNull);
      final offline = WeatherService(client: MockClient((_) async => throw Exception('offline')));
      expect(await offline.airAlong(road()), isNull);
    });
  });
}
