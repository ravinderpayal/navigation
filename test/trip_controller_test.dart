import 'package:flutter_test/flutter_test.dart';
import 'package:vinfast_copilot/core/air_along_route.dart';
import 'package:vinfast_copilot/core/charge_planner.dart';
import 'package:vinfast_copilot/core/charger.dart';
import 'package:vinfast_copilot/core/distance_tracker.dart';
import 'package:vinfast_copilot/core/energy.dart';
import 'package:vinfast_copilot/core/geo.dart';
import 'package:vinfast_copilot/core/route_profile.dart';
import 'package:vinfast_copilot/core/trip_controller.dart';

const _kmPerDegree = 111.195;
GeoPoint _north(double km) => GeoPoint(10 + km / _kmPerDegree, 77);
Charger _at(double km) => Charger(id: 'c$km', name: 'C$km', position: _north(km), dcKw: 60);

// Exactly 0.2 % per km.
const _energy = EnergyModel(kwhPer100Km: 20, batteryKwh: 100);

TripController _trip({double soc = 70, double km = 600, int? failAfter}) {
  var calls = 0;
  return TripController(
    startSoc: soc,
    energy: _energy,
    origin: _north(0),
    destination: _north(km),
    planner: ChargePlanner(
      freeChargers: [_at(120), _at(225), _at(450)],
      searchOtherChargers: (_, _) async => const [],
      checkDetour: (_, _) async => null,
    ),
    fetchRoute: (origin, destination, _) async {
      if (failAfter != null && ++calls > failAfter) throw Exception('offline');
      return RouteProfile(points: [origin, destination]);
    },
  );
}

void main() {
  test('chargers stay hidden until the estimate drops below 50%', () async {
    final trip = _trip();
    await trip.load();
    expect(trip.chargersToShow, isEmpty);
    expect(trip.recommendedStop, isNull);

    trip.addDistanceForTest(0.5);
    expect(trip.soc, closeTo(69.9, 0.05));
    expect(trip.chargersToShow, isEmpty);
  });

  test('driving past 50% reveals chargers and the 25% stop', () async {
    final trip = _trip(soc: 50.5);
    await trip.load();
    expect(trip.chargersToShow, isEmpty);

    trip.addDistanceForTest(5); // 1% used
    trip.updatePosition(_north(5));

    expect(trip.soc, closeTo(49.5, 0.1));
    expect(trip.chargersVisible, isTrue);
    expect(trip.recommendedStop!.place.charger.id, _at(120).id);
    expect(trip.chargersToShow.map((c) => c.charger.id), containsAll([_at(120).id, _at(225).id]));
  });

  test('progress follows position, and passed chargers drop off the map', () async {
    final trip = _trip(soc: 40);
    await trip.load();
    expect(trip.chargersToShow.any((c) => c.charger.id == _at(120).id), isTrue);
    trip.updatePosition(_north(300));
    expect(trip.progressKm, closeTo(300, 1));
    expect(trip.chargersToShow.any((c) => c.charger.id == _at(225).id), isFalse);
  });

  test('a new reading after charging replans from the current position', () async {
    final trip = _trip(soc: 45);
    await trip.load();
    trip.updatePosition(_north(100));
    trip.goToCharger(trip.recommendedStop!.place);
    expect(trip.recommendedStop, isNull, reason: 'Already heading to one');

    await trip.updateSoc(80);
    expect(trip.soc, 80);
    expect(trip.activeStop, isNull);
    expect(trip.origin.lat, closeTo(_north(100).lat, 1e-6));
    expect(trip.route!.totalKm, closeTo(500, 1));
    expect(trip.chargersVisible, isFalse);
  });

  test('heading to a charger: arrival charge, and time back to 80% with parking', () async {
    final trip = _trip(soc: 45);
    await trip.load();
    expect(trip.activeStopEstimate, isNull);
    trip.updatePosition(_north(100));
    trip.goToCharger(RouteCharger(charger: _at(120), alongKm: 120, detourKm: 0));
    final estimate = trip.activeStopEstimate!;
    // 20 km at 0.2% per km.
    expect(estimate.arrivalSoc, closeTo(41, 0.3));
    // 39 kWh, mostly at 54 kW (90% of 60), then the car's taper near 80%: 44 min.
    // Plus 3 + 2 + 3 to park, connect and leave.
    expect(estimate.chargeMinutes, 44);
    expect(estimate.totalMinutes, 52);
    expect(estimate.chargeToSoc, 80);

    // Closer, and a little more used: the numbers follow.
    trip.addDistanceForTest(10);
    trip.updatePosition(_north(110));
    expect(trip.activeStopEstimate!.arrivalSoc, closeTo(41, 0.3));
  });

  test('heading to a charger with no listed power: arrival charge only', () async {
    final trip = _trip(soc: 45);
    await trip.load();
    trip.goToCharger(RouteCharger(
        charger: Charger(id: 'x', name: 'X', position: _north(50), dcKw: 0), alongKm: 50, detourKm: 4));
    final estimate = trip.activeStopEstimate!;
    expect(estimate.arrivalSoc, closeTo(45 - 10 - 0.4, 0.3), reason: 'half the detour counts');
    expect(estimate.chargeMinutes, isNull);
    expect(estimate.totalMinutes, isNull);
  });

  test('a failed replan keeps the current route', () async {
    final trip = _trip(failAfter: 1);
    await trip.load();
    final before = trip.route;
    await trip.replanFromHere();
    expect(trip.route, same(before));
    expect(trip.error, isNull);
  });

  test('a failed first load reports the error', () async {
    final trip = _trip(failAfter: 0);
    await trip.load();
    expect(trip.route, isNull);
    expect(trip.error, contains('offline'));
    expect(trip.loading, isFalse);
  });

  group('speed and burn rate', () {
    late List<GeoPoint> fetchedFrom;
    TripController drive({double speedDivisor = 1, List<Charger> fast = const [], double soc = 90}) {
      fetchedFrom = [];
      return TripController(
        startSoc: soc,
        energy: _energy,
        origin: _north(0),
        destination: _north(600),
        speedDivisor: speedDivisor,
        planner: ChargePlanner(
          freeChargers: [_at(120), _at(225), _at(450)],
          searchUltraFast: (_) async => fast,
          searchOtherChargers: (_, _) async => const [],
          checkDetour: (_, _) async => null,
        ),
        fetchRoute: (origin, destination, _) async {
          fetchedFrom.add(origin);
          // No speed data: every km is predicted at the 80 km/h figure.
          return RouteProfile(points: [origin, destination]);
        },
      );
    }

    test('driving at the predicted speed keeps the burn rate at 1', () async {
      final trip = drive();
      await trip.load();
      for (var i = 0; i < 20; i++) {
        trip.addDistanceForTest(0.5, kmh: 80);
      }
      expect(trip.speedKmh, closeTo(80, 0.01));
      expect(trip.burnScale, closeTo(1, 0.01));
      expect(trip.soc, closeTo(88, 0.05));
      expect(trip.liveKwhPer100, closeTo(20, 0.01));
    });

    test('driving faster burns more, and predictions ahead use it', () async {
      final trip = drive();
      await trip.load();
      final planned = trip.route!.socUsed(0, 300, trip.energy);
      for (var i = 0; i < 40; i++) {
        trip.addDistanceForTest(0.5, kmh: 100);
      }
      final factor = _energy.factorAt(100);
      expect(trip.soc, closeTo(90 - 20 * 0.2 * factor, 0.2), reason: 'the speed actually driven');
      final expected = factor;
      expect(expected, greaterThan(1.1));
      expect(trip.burnScale, closeTo(expected, 0.05));
      expect(trip.energy.socPerKm, closeTo(0.2 * trip.burnScale, 1e-9));
      expect(trip.route!.socUsed(0, 300, trip.energy), closeTo(planned * trip.burnScale, 0.1));
      expect(trip.liveKwhPer100, closeTo(20 * factor, 0.2));
    });

    test('the burn rate needs a few km before it counts, and stays within bounds', () async {
      final trip = drive();
      await trip.load();
      trip.addDistanceForTest(1, kmh: 200);
      expect(trip.burnScale, 1);
      for (var i = 0; i < 40; i++) {
        trip.addDistanceForTest(0.5, kmh: 200);
      }
      expect(trip.burnScale, 1.5);
    });

    test('speed is smoothed, so one wild GPS fix does not swing it', () async {
      final trip = drive();
      await trip.load();
      for (var i = 0; i < 10; i++) {
        trip.addDistanceForTest(0.03, kmh: 100);
      }
      trip.addDistanceForTest(0.03, kmh: 200);
      expect(trip.speedKmh, lessThan(120));
    });

    test('a simulated 5x drive is scaled back to real speed', () async {
      final trip = drive(speedDivisor: 5);
      await trip.load();
      for (var i = 0; i < 10; i++) {
        trip.addDistanceForTest(0.5, kmh: 400);
      }
      expect(trip.speedKmh, closeTo(80, 0.5));
    });

    test('180 kW chargers are on the map whatever the charge', () async {
      final fast = Charger(id: 'ultra', name: 'Ultra', position: _north(300), dcKw: 180,
          source: ChargerSource.other);
      final trip = drive(fast: [fast]);
      await trip.load();
      expect(trip.chargersVisible, isFalse);
      expect(trip.chargersToShow.map((c) => c.charger.id), ['ultra']);
      expect(trip.isUltraFast(fast), isTrue);
    });

    test('driving past the suggested stop replans from where the car is', () async {
      final trip = drive(soc: 45);
      await trip.load();
      final stopKm = trip.plan!.stops.first.place.alongKm;
      trip.updatePosition(_north(stopKm + 5));
      await pumpEventQueue();
      expect(fetchedFrom.length, 2);
      expect(fetchedFrom.last.lat, closeTo(_north(stopKm + 5).lat, 1e-6));
      expect(trip.plan!.stops.first.place.alongKm, greaterThan(0));
    });
  });

  group('live battery meter', () {
    late DateTime now;
    late int fetches;
    TripController meter({double soc = 45}) {
      now = DateTime(2026, 11, 4, 9);
      fetches = 0;
      return TripController(
        startSoc: soc,
        energy: _energy,
        origin: _north(0),
        destination: _north(600),
        clock: () => now,
        planner: ChargePlanner(
          freeChargers: [_at(120), _at(225), _at(450)],
          searchOtherChargers: (_, _) async => const [],
          checkDetour: (_, _) async => null,
        ),
        fetchRoute: (origin, destination, _) async {
          fetches++;
          return RouteProfile(points: [origin, destination]);
        },
      );
    }

    test('a standing car still uses its AC and screens', () async {
      final trip = meter(soc: 70);
      await trip.load();
      trip.addDistanceForTest(0.5, kmh: 30);
      final moving = trip.soc;
      now = now.add(const Duration(seconds: 20));
      trip.tick();
      for (var i = 0; i < 120; i++) {
        now = now.add(const Duration(seconds: 5));
        trip.tick();
      }
      // 10 minutes at the default 1 kW: 0.17 kWh of a 100 kWh pack.
      expect(moving - trip.soc, closeTo(0.167, 0.01));
      expect(trip.speedKmh, 0);
    });

    test('just stopping at a light for a few seconds costs nothing extra', () async {
      final trip = meter(soc: 70);
      await trip.load();
      trip.addDistanceForTest(0.5, kmh: 30);
      final moving = trip.soc;
      now = now.add(const Duration(seconds: 5));
      trip.tick();
      now = now.add(const Duration(seconds: 5));
      trip.tick();
      expect(trip.soc, moving);
    });

    test('speeding up costs energy, braking wins some back', () async {
      final steady = meter(soc: 70), stopStart = meter(soc: 70);
      await steady.load();
      await stopStart.load();
      for (var i = 0; i < 10; i++) {
        steady.addDistanceForTest(0.2, kmh: 40);
        stopStart.addDistanceForTest(0.2, kmh: i.isEven ? 40 : 10);
      }
      expect(stopStart.soc, lessThan(steady.soc));
    });

    test('the arrival charges follow how the car is really being driven', () async {
      final trip = meter();
      await trip.load();
      final before = trip.liveArrivals!;
      expect(before.stops.first, closeTo(trip.plan!.stops.first.arrivalSoc, 0.5));
      // 10 km at 130 km/h: much dearer than planned.
      for (var i = 0; i < 20; i++) {
        trip.addDistanceForTest(0.5, kmh: 130);
      }
      trip.updatePosition(_north(10));
      final after = trip.liveArrivals!;
      expect(trip.burnScale, greaterThan(1.3));
      expect(after.stops.first, lessThan(before.stops.first - 10 * 0.2 - 3));
      expect(after.destination, lessThan(before.destination));
      expect(trip.arrivalSocAt(trip.plan!.stops.first.place), closeTo(after.stops.first, 0.01));
    });

    test('a stop slipping under 20% at the current rate brings a new plan', () async {
      final trip = meter();
      await trip.load();
      expect(fetches, 1);
      for (var i = 0; i < 30; i++) {
        trip.addDistanceForTest(0.5, kmh: 150);
      }
      await pumpEventQueue();
      expect(fetches, 2);
      // Not again straight away.
      trip.addDistanceForTest(0.5, kmh: 150);
      await pumpEventQueue();
      expect(fetches, 2);
    });
  });

  test('a planned stop within 30 km is brought up even above 50%', () async {
    final trip = _trip(soc: 70);
    await trip.load();
    final stop = trip.plan!.stops.first;
    expect(trip.recommendedStop, isNull);
    trip.updatePosition(_north(stop.place.alongKm - 25));
    expect(trip.chargersVisible, isFalse);
    expect(trip.recommendedStop!.place.charger.id, stop.place.charger.id);
  });

  test('weather is fetched with the route and kept for reroutes', () async {
    var fetches = 0;
    final trip = TripController(
      startSoc: 70,
      energy: _energy,
      origin: _north(0),
      destination: _north(600),
      planner: ChargePlanner(
        freeChargers: [_at(120), _at(225), _at(450)],
        searchOtherChargers: (_, _) async => const [],
        checkDetour: (_, _) async => null,
      ),
      fetchRoute: (origin, destination, _) async => RouteProfile(points: [origin, destination]),
      fetchAir: (_) async {
        fetches++;
        return AirAlongRoute([AirSample(_north(300), const AirConditions(densityKgM3: 1.1, windKmh: 30))]);
      },
    );
    await trip.load();
    expect(trip.route!.air, isNotNull);
    expect(trip.route!.airAt(10)!.densityKgM3, 1.1);
    // A northerly wind on a northbound trip: everything costs more.
    expect(trip.route!.socUsed(0, 600, trip.energy), greaterThan(600 * 0.2 * 1.1));
    await trip.replanFromHere();
    expect(trip.route!.air, isNotNull);
    expect(fetches, 1);
  });

  group('DistanceTracker', () {
    late DateTime clock;
    late double total;
    late List<double?> speeds;
    late DistanceTracker tracker;

    setUp(() {
      clock = DateTime(2026);
      total = 0;
      speeds = [];
      tracker = DistanceTracker(
          onDistance: (km, kmh) {
            total += km;
            speeds.add(kmh);
          },
          clock: () => clock);
    });

    void advance(int seconds) => clock = clock.add(Duration(seconds: seconds));

    test('adds distance between fixes', () {
      tracker.addGpsFix(_north(0));
      advance(60);
      tracker.addGpsFix(_north(1));
      expect(total, closeTo(1, 0.01));
      expect(speeds.single, closeTo(60, 1), reason: '1 km in a minute');
    });

    test('parked GPS jitter adds nothing', () {
      tracker.addGpsFix(_north(0));
      for (var i = 0; i < 100; i++) {
        advance(5);
        tracker.addGpsFix(_north(i.isEven ? 0.005 : 0));
      }
      expect(total, 0);
    });

    test('an impossible jump is ignored but tracking continues', () {
      tracker.addGpsFix(_north(0));
      advance(10);
      tracker.addGpsFix(_north(50));
      expect(total, 0);
      advance(60);
      tracker.addGpsFix(_north(51));
      expect(total, closeTo(1, 0.01));
    });

    test('raw GPS does not double count while snapped fixes flow', () {
      tracker.addSnappedFix(_north(0));
      advance(5);
      tracker.addGpsFix(_north(0.5));
      expect(total, 0);
      advance(1);
      tracker.addSnappedFix(_north(1));
      expect(total, closeTo(1, 0.01));
    });

    test('raw GPS takes over when snapped fixes stop', () {
      tracker.addSnappedFix(_north(0));
      advance(60);
      tracker.addGpsFix(_north(1));
      expect(total, closeTo(1, 0.01));
    });
  });
}
