import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'air_along_route.dart';
import 'approach_alerts.dart';
import 'battery_forecast.dart';
import 'charge_planner.dart';
import 'charger.dart';
import 'cruise_speed.dart';
import 'distance_tracker.dart';
import 'energy.dart';
import 'geo.dart';
import 'live_status.dart';
import 'route_profile.dart';

/// Fetches a route. Separate from GoogleApi so trips can be tested without it.
typedef RouteFetcher = Future<RouteProfile> Function(GeoPoint origin, GeoPoint destination, GeoPoint? via);

/// What a stop at the chosen charger looks like from here.
class StopEstimate {
  const StopEstimate({required this.arrivalSoc, required this.chargeToSoc, this.chargeMinutes, this.totalMinutes});
  final double arrivalSoc;
  final double chargeToSoc;

  /// Null when the charger's power isn't known.
  final int? chargeMinutes;

  /// Charging plus parking, connecting and leaving.
  final int? totalMinutes;
}

/// Weather along a route, or null when it can't be had.
typedef AirFetcher = Future<AirAlongRoute?> Function(RouteProfile route);

/// The live state of one trip: estimated charge, the route and the stop plan.
class TripController extends ChangeNotifier {
  TripController({
    required double startSoc,
    required EnergyModel energy,
    required this.origin,
    required this.destination,
    required this.planner,
    required this.fetchRoute,
    this.refreshLiveStatus,
    this.fetchAir,
    this.speedDivisor = 1,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _soc = SocEstimator(startSoc: startSoc, energy: energy) {
    tracker = DistanceTracker(onDistance: _onDistance);
  }

  static const _maxChargersOnMap = 25;

  /// Speed readings are smoothed over about this long.
  static const _speedSmoothingSeconds = 8.0;

  /// Recent driving counts most: its weight halves about every 10 km.
  static const _burnMemoryKm = 15.0;

  /// The burn rate needs this many km of driving before it's trusted.
  static const _minBurnKm = 3.0;
  static const _minBurnScale = 0.8;
  static const _maxBurnScale = 1.5;

  /// A suggested stop this far behind the car was missed.
  static const _missedStopKm = 1.0;

  /// Speed changes smaller than this are GPS wobble, not speeding up or braking.
  static const _speedChangeKmh = 5.0;

  /// No movement for this long means the car is standing, AC still running.
  static const _standingAfter = Duration(seconds: 15);

  /// The consumption shown is the average over about the last 2 km.
  static const _meterMemoryKm = 2.0;
  static const _minMeterKm = 0.3;

  /// Replans for a stop slipping out of reach no more often than this.
  static const _reachReplanEvery = Duration(minutes: 2);

  /// The level to forecast, ahead of the planner's 25% target so there's time to act.
  static const forecastLevel = 30.0;

  /// How far navigation's live estimate may reasonably differ from the plan.
  static const _minTimeScale = 0.5;
  static const _maxTimeScale = 2.0;

  final GeoPoint destination;
  final ChargePlanner planner;
  final RouteFetcher fetchRoute;
  final Future<void> Function()? refreshLiveStatus;
  final AirFetcher? fetchAir;

  /// A simulated drive runs faster than real time. Its speeds are scaled back.
  final double speedDivisor;
  final SocEstimator _soc;
  late final DistanceTracker tracker;
  late final ApproachAlerts alerts = ApproachAlerts(floorSoc: planner.rules.hardFloorSoc);

  GeoPoint origin;
  RouteProfile? route;
  ChargePlan? plan;
  String? error;
  bool loading = false;

  /// The charger the driver chose to go to next.
  RouteCharger? activeStop;

  GeoPoint? _position;
  double _progressKm = 0;
  double _timeScale = 1;
  bool _applyingStatus = false;
  List<RouteCharger> _freeOnRoute = const [];
  List<RouteCharger> _ultraFastOnRoute = const [];
  AirAlongRoute? _air;
  double? _speedKmh;
  final DateTime Function() _clock;

  // Battery use is in "80 km/h km": the energy a km takes at 80 km/h.
  double _recentActual = 0;
  double _recentPredicted = 0;
  double _meterUse = 0;
  double _meterKm = 0;
  double? _anchorKmh;
  DateTime? _lastMoved;
  DateTime? _lastTick;
  DateTime? _lastReachReplan;
  bool _replanningMissedStop = false;
  double? _destinationSoc;

  /// The cruising speed that gets there soonest, charging included.
  CruiseAdvice? cruise;

  /// Where the battery should reach [forecastLevel], from everything known now.
  BatteryForecast? get forecast {
    final current = route;
    if (current == null) return null;
    return forecastBatteryLevel(
      route: current,
      progressKm: _progressKm,
      soc: soc,
      energy: energy,
      level: forecastLevel,
      timeScale: _timeScale,
    );
  }

  /// Corrects predicted times using navigation's live time to the destination.
  void updateRemainingTime(double seconds) {
    final current = route;
    // Going via a charger, navigation's total covers a different route.
    if (current == null || activeStop != null) return;
    final predicted = current.secondsBetween(_progressKm, current.totalKm);
    if (predicted <= 0 || seconds <= 0) return;
    _timeScale = (seconds / predicted).clamp(_minTimeScale, _maxTimeScale);
  }

  double get soc => _soc.soc;

  /// The car as the driver described it, adjusted for how driving is going and
  /// assuming the advised cruising speed.
  EnergyModel get energy => _soc.energy.withBurnScale(burnScale).withCruise(cruiseKmh);

  /// The advised speed on open road, up to the limit there.
  double? get cruiseKmh => cruise?.best.kmh;

  /// Charge to arrive with: more on a long trip, so there's no hunt for a charger
  /// in city traffic on arrival. Decided once, from the whole trip.
  double get destinationSoc => _destinationSoc ?? planner.rules.reserveSoc;

  /// Smoothed GPS speed, once the car has moved.
  double? get speedKmh => _speedKmh;

  /// How recent driving compares with what the route predicted: 1.2 means the
  /// battery is going 20% faster. Predictions ahead use this.
  double get burnScale => _recentPredicted < _minBurnKm
      ? 1
      : (_recentActual / _recentPredicted).clamp(_minBurnScale, _maxBurnScale);

  /// Consumption right now, at this speed and in this weather, in kWh per 100 km.
  /// Measured over about the last 2 km: speed, speeding up and braking, the
  /// weather, and the AC while standing.
  double? get liveKwhPer100 =>
      _meterKm < _minMeterKm ? null : _meterUse / _meterKm * _soc.energy.kwhPer100Km;

  AirAlongRoute? get air => _air;

  /// Chargers of 180 kW or more right on the road. Shown whatever the charge.
  List<RouteCharger> get ultraFastOnRoute =>
      _ultraFastOnRoute.where((c) => c.alongKm >= _progressKm).toList();

  bool isUltraFast(Charger charger) => charger.dcKw >= planner.rules.ultraFastKw;
  double get progressKm => _progressKm;
  double get remainingKm => route == null ? 0 : route!.totalKm - _progressKm;
  bool get chargersVisible => soc < planner.rules.showChargersBelowSoc;

  /// A planned stop this close is brought up whatever the charge, since fast
  /// chargers and top-ups can be planned above 50%.
  static const _bringUpStopWithinKm = 30.0;

  /// The stop to suggest now, once the charge is low enough or the stop is near.
  ChargeStop? get recommendedStop {
    if (activeStop != null) return null;
    final stops = plan?.stops ?? const <ChargeStop>[];
    if (stops.isEmpty) return null;
    final stop = stops.first;
    if (!chargersVisible && stop.place.alongKm - _progressKm > _bringUpStopWithinKm) return null;
    return stop;
  }

  /// Everything to draw on the map: free chargers still ahead, and the plan's stops.
  List<RouteCharger> get chargersToShow {
    final byId = <String, RouteCharger>{for (final c in ultraFastOnRoute) c.charger.id: c};
    if (!chargersVisible) return byId.values.toList();
    for (final stop in plan?.stops ?? const <ChargeStop>[]) {
      byId[stop.place.charger.id] = stop.place;
    }
    final active = activeStop;
    if (active != null) byId[active.charger.id] = active;
    for (final c in _freeOnRoute) {
      if (byId.length >= _maxChargersOnMap) break;
      if (c.alongKm >= _progressKm) byId.putIfAbsent(c.charger.id, () => c);
    }
    return byId.values.toList();
  }

  bool isRecommended(Charger charger) => recommendedStop?.place.charger.id == charger.id;

  /// Charge on arrival at the chosen charger, and how long the stop takes.
  StopEstimate? get activeStopEstimate {
    final place = activeStop;
    final current = route;
    if (place == null || current == null) return null;
    final rules = planner.rules;
    final scaled = energy;
    final arrival = arrivalSocAt(place);
    final kw = place.charger.dcKw;
    final chargeMinutes = kw > 0 ? scaled.chargeMinutes(arrival, rules.chargeToSoc, kw).ceil() : null;
    return StopEstimate(
      arrivalSoc: arrival,
      chargeToSoc: rules.chargeToSoc,
      chargeMinutes: chargeMinutes,
      totalMinutes: chargeMinutes == null ? null : chargeMinutes + rules.stopOverheadMinutes,
    );
  }

  /// What to warn the driver about now, if anything.
  DriverAlert? checkAlerts() {
    final active = activeStop;
    return alerts.check(
      target: active ?? recommendedStop?.place,
      heading: active != null,
      progressKm: _progressKm,
      speedKmh: _speedKmh,
      soc: soc,
    );
  }

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      final fresh = await fetchRoute(origin, destination, null);
      await refreshLiveStatus?.call();
      await _adoptRoute(fresh, fromKm: 0);
    } catch (e) {
      error = e.toString();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void updatePosition(GeoPoint position) {
    _position = position;
    final current = route;
    if (current != null) {
      _progressKm = current.project(position, fromKm: _progressKm).alongKm;
    }
    _replanIfStopMissed();
    notifyListeners();
  }

  /// Driving past the suggested stop leaves a plan that charges behind the car.
  void _replanIfStopMissed() {
    final stops = plan?.stops ?? const <ChargeStop>[];
    if (_replanningMissedStop || activeStop != null || stops.isEmpty) return;
    if (_progressKm - stops.first.place.alongKm < _missedStopKm) return;
    _replanningMissedStop = true;
    replanFromHere().whenComplete(() => _replanningMissedStop = false);
  }

  void _onDistance(double km, double? stepKmh) {
    final current = route;
    final base = _soc.energy;
    _lastMoved = _clock();
    if (stepKmh != null && stepKmh > 0) {
      final kmh = stepKmh / speedDivisor;
      final previous = _speedKmh;
      final seconds = km / kmh * 3600 / speedDivisor;
      final weight = 1 - math.exp(-seconds / _speedSmoothingSeconds);
      _speedKmh = previous == null ? kmh : previous + (kmh - previous) * weight;
    }
    // Each km costs what it cost at the speed actually driven, in the weather
    // there, plus what speeding up cost and braking won back.
    final predictedFactor = current?.energyFactorAt(_progressKm, base.withCruise(cruiseKmh)) ?? 1;
    final speed = _speedKmh;
    var actual = km * predictedFactor;
    if (speed != null) {
      actual = km * (current?.energyFactorAt(_progressKm, base, kmh: speed) ?? base.factorAt(speed)) +
          _speedChangeUse(speed, base);
    }
    _use(actual, km: km, predicted: km * predictedFactor);
    _replanIfStopOutOfReach();
    notifyListeners();
  }

  /// Energy to change speed since the last real change, as 80 km/h km.
  double _speedChangeUse(double kmh, EnergyModel energy) {
    final anchor = _anchorKmh;
    if (anchor == null) {
      _anchorKmh = kmh;
      return 0;
    }
    if ((kmh - anchor).abs() < _speedChangeKmh) return 0;
    _anchorKmh = kmh;
    return energy.kineticKwh(anchor, kmh) / (energy.kwhPer100Km / 100);
  }

  void _use(double actual, {required double km, required double predicted}) {
    _soc.addDistance(actual);
    final fade = math.exp(-km / _burnMemoryKm);
    _recentActual = _recentActual * fade + actual;
    _recentPredicted = _recentPredicted * fade + predicted;
    final meterFade = math.exp(-km / _meterMemoryKm);
    _meterUse = _meterUse * meterFade + actual;
    _meterKm = _meterKm * meterFade + km;
  }

  /// Call every few seconds while driving. A standing car still runs its AC and
  /// screens, which distance alone never shows.
  void tick() {
    final now = _clock();
    final last = _lastTick;
    _lastTick = now;
    final moved = _lastMoved;
    if (last == null || moved == null || now.difference(moved) < _standingAfter) return;
    final energy = _soc.energy;
    final hours = now.difference(last).inMilliseconds / 3600000;
    _speedKmh = 0;
    _anchorKmh = 0;
    _use(energy.accessoryKw * hours / (energy.kwhPer100Km / 100), km: 0, predicted: 0);
    _replanIfStopOutOfReach();
    notifyListeners();
  }

  /// Charge on reaching [place] from here, at the current rate of use.
  double arrivalSocAt(RouteCharger place) {
    final current = route;
    if (current == null) return soc;
    final scaled = energy;
    final ahead = math.max(0.0, place.alongKm - _progressKm);
    return (soc - current.socUsed(_progressKm, _progressKm + ahead, scaled) - place.detourKm / 2 * scaled.socPerKm)
        .clamp(0.0, soc);
  }

  /// Charge on arrival at each planned stop ahead, then at the destination,
  /// from the charge now and the current rate of use. Stops charge to what the
  /// plan says.
  ({List<double> stops, double destination})? get liveArrivals {
    final current = route;
    final planned = plan;
    if (current == null || planned == null) return null;
    final scaled = energy;
    var level = soc, km = _progressKm;
    final stops = <double>[];
    for (final stop in planned.stops) {
      if (stop.place.alongKm < km) {
        stops.add(stop.arrivalSoc);
        continue;
      }
      level -= current.socUsed(km, stop.place.alongKm, scaled) + stop.place.detourKm / 2 * scaled.socPerKm;
      stops.add(level);
      level = math.max(level, stop.departureSoc) - stop.place.detourKm / 2 * scaled.socPerKm;
      km = stop.place.alongKm;
    }
    return (stops: stops, destination: level - current.socUsed(km, current.totalKm, scaled));
  }

  /// Driving harder than planned can leave the next stop out of safe reach.
  void _replanIfStopOutOfReach() {
    final stops = plan?.stops ?? const <ChargeStop>[];
    if (activeStop != null || stops.isEmpty || _replanningMissedStop) return;
    final next = stops.first;
    if (next.place.alongKm < _progressKm || next.belowFloor) return;
    if (arrivalSocAt(next.place) >= planner.rules.hardFloorSoc - 0.5) return;
    final now = _clock(), last = _lastReachReplan;
    if (last != null && now.difference(last) < _reachReplanEvery) return;
    _lastReachReplan = now;
    _replanningMissedStop = true;
    replanFromHere().whenComplete(() => _replanningMissedStop = false);
  }

  @visibleForTesting
  void addDistanceForTest(double km, {double? kmh}) => _onDistance(km, kmh);

  /// Fresh weather, for the current route and any after a reroute.
  Future<void> refreshAir() async {
    final current = route;
    final fetch = fetchAir;
    if (current == null || fetch == null) return;
    final fresh = await _fetchAirSafely(current);
    if (fresh == null) return;
    _air = fresh;
    current.air = fresh;
    notifyListeners();
  }

  Future<AirAlongRoute?> _fetchAirSafely(RouteProfile route) async {
    try {
      return await fetchAir?.call(route);
    } catch (e) {
      debugPrint('Weather failed: $e');
      return null;
    }
  }

  /// The driver chose this charger: guidance goes there first.
  void goToCharger(RouteCharger place) {
    activeStop = place;
    notifyListeners();
  }

  void cancelStop() {
    activeStop = null;
    notifyListeners();
  }

  /// The driver gave a new reading, usually after charging. Replans from here.
  Future<void> updateSoc(double value) async {
    _soc.reset(value);
    alerts.resetBattery();
    activeStop = null;
    await replanFromHere();
  }

  /// Recalculates after a reroute or a new reading. Keeps the old route on failure.
  Future<void> replanFromHere() async {
    final here = _position ?? origin;
    try {
      final fresh = await fetchRoute(here, destination, null);
      origin = here;
      _progressKm = 0;
      await _adoptRoute(fresh, fromKm: 0);
      error = null;
    } catch (e) {
      debugPrint('Replan failed: $e');
    }
    notifyListeners();
  }

  /// Picks up chargers going down or coming back mid-trip. The plan only changes
  /// when the suggested stop itself has gone down.
  Future<void> refreshChargerStatus() async {
    final current = route;
    final refresh = refreshLiveStatus;
    if (current == null || refresh == null) return;
    await refresh();
    await applyLiveStatus();
  }

  /// Uses the latest status: updates map pins, and replans if the suggested stop went down.
  Future<void> applyLiveStatus() async {
    final current = route;
    if (current == null || _applyingStatus) return;
    _applyingStatus = true;
    try {
      _freeOnRoute = planner.freeChargersOnRoute(current);
      _ultraFastOnRoute = await planner.ultraFastOnRoute(current);
      final stop = recommendedStop;
      if (stop != null && planner.live?.statusOf(stop.place.charger) == LiveStatus.unavailable) {
        plan = await planner.plan(
            route: current, fromKm: _progressKm, soc: soc, energy: energy, destinationSoc: destinationSoc);
      }
    } finally {
      _applyingStatus = false;
    }
    notifyListeners();
  }

  Future<void> _adoptRoute(RouteProfile fresh, {required double fromKm}) async {
    // Weather is by place, so the last reading still fits a reroute nearby.
    fresh.air = _air ?? (_air = await _fetchAirSafely(fresh));
    _freeOnRoute = planner.freeChargersOnRoute(fresh);
    _ultraFastOnRoute = await planner.ultraFastOnRoute(fresh);
    _destinationSoc ??= planner.rules.destinationSocFor(fresh.totalKm);
    final asDriven = _soc.energy.withBurnScale(burnScale);
    var planned = await planner.plan(
        route: fresh, fromKm: fromKm, soc: soc, energy: asDriven, destinationSoc: destinationSoc);
    // How fast to cruise depends on how fast the stops charge, and the stops on
    // how much charge the driving uses. One round of each settles it.
    final rules = planner.rules;
    final advice = CruiseAdvisor.advise(
      route: fresh,
      startSoc: soc,
      energy: asDriven,
      arriveWith: destinationSoc,
      chargerKw: _typicalChargerKw(planned),
      reserveSoc: rules.reserveSoc,
      chargeToSoc: rules.chargeToSoc,
      stopOverheadMinutes: rules.stopOverheadMinutes,
    );
    // Mostly town roads: the road sets the pace, so there's nothing to advise.
    cruise = fresh.openRoadShare >= _minOpenRoadShare ? advice : null;
    planned = await planner.plan(
        route: fresh, fromKm: fromKm, soc: soc, energy: energy, destinationSoc: destinationSoc);
    plan = planned;
    route = fresh;
  }

  /// Fast chargers are what make fast cruising pay, so the advice uses the power
  /// of the stops planned, or a common 60 kW when none are.
  double _typicalChargerKw(ChargePlan planned) {
    final kws = [
      for (final stop in planned.stops)
        stop.place.charger.dcKw > 0 ? stop.place.charger.dcKw : planner.rules.unlistedChargerKw,
    ];
    return kws.isEmpty ? _defaultAdviceKw : kws.reduce((a, b) => a + b) / kws.length;
  }

  static const _defaultAdviceKw = 60.0;
  static const _minOpenRoadShare = 0.2;
}
