import 'package:flutter_test/flutter_test.dart';
import 'package:vinfast_copilot/core/approach_alerts.dart';
import 'package:vinfast_copilot/core/charge_planner.dart';
import 'package:vinfast_copilot/core/charger.dart';
import 'package:vinfast_copilot/core/geo.dart';

RouteCharger _stop(double km, {double detour = 0}) => RouteCharger(
      charger: Charger(id: 'c$km', name: 'Highway Charger', position: const GeoPoint(0, 0), dcKw: 180),
      alongKm: km,
      detourKm: detour,
    );

void main() {
  late ApproachAlerts alerts;
  setUp(() => alerts = ApproachAlerts());

  DriverAlert? at(double progressKm, {RouteCharger? target, bool heading = true, double? kmh = 100, double soc = 50}) =>
      alerts.check(target: target, heading: heading, progressKm: progressKm, speedKmh: kmh, soc: soc);

  test('at 100 km/h: heads-up 90 s before the turn-off, then urgent 30 s before, once each', () {
    final stop = _stop(100);
    expect(at(96, target: stop), isNull, reason: '4 km is over 90 s away');
    final headsUp = at(97.6, target: stop)!; // 2.4 km: 86 s
    expect(headsUp.urgent, isFalse);
    expect(headsUp.message, 'Charger turn-off in 2.4 km. Start slowing down.');
    expect(at(98, target: stop), isNull);
    final urgent = at(99.2, target: stop)!; // 800 m: 29 s
    expect(urgent.urgent, isTrue);
    expect(urgent.message, 'Charger turn-off in 800 m. Slow down now.');
    expect(at(99.5, target: stop), isNull);
  });

  test('slower driving warns closer, but never under 1 km and 300 m', () {
    final stop = _stop(50);
    expect(at(48.8, target: stop, kmh: 30), isNull);
    expect(at(49.1, target: stop, kmh: 30)!.urgent, isFalse);
    expect(at(49.75, target: stop, kmh: 30)!.urgent, isTrue);
  });

  test('a long detour leaves the route earlier, so warnings come earlier', () {
    final stop = _stop(100, detour: 6); // turn-off about 2 km before
    expect(at(95.6, target: stop)!.urgent, isFalse);
  });

  test('a suggestion not yet accepted says to tap Go', () {
    final alert = at(99.5, target: _stop(100), heading: false)!;
    expect(alert.urgent, isTrue);
    expect(alert.message, contains('Tap Go now'));
    expect(alert.message, contains('Highway Charger'));
  });

  test('jumping straight into the urgent zone skips the heads-up', () {
    final stop = _stop(10);
    expect(at(9.9, target: stop)!.urgent, isTrue);
    expect(at(9.95, target: stop), isNull);
  });

  test('no warning once the turn-off is behind', () {
    expect(at(100.5, target: _stop(100)), isNull);
  });

  test('battery: a heads-up near 20%, an urgent warning below it, each once', () {
    expect(at(0, soc: 25), isNull);
    expect(at(0, soc: 21.5)!.urgent, isFalse);
    expect(at(0, soc: 21), isNull);
    final low = at(0, soc: 19.6)!;
    expect(low.urgent, isTrue);
    expect(low.message, contains('below the 20% safe level'));
    expect(at(0, soc: 15), isNull);
    alerts.resetBattery();
    expect(at(0, soc: 15)!.urgent, isTrue);
  });
}
