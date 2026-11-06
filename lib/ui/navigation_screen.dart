import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart' as gps;
import 'package:google_navigation_flutter/google_navigation_flutter.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../core/charge_planner.dart';
import '../core/charger.dart';
import '../core/charger_options.dart';
import '../core/energy.dart';
import '../core/geo.dart';
import '../core/route_profile.dart';
import '../core/trip_controller.dart';
import '../data/charger_repository.dart';
import '../data/charger_status_service.dart';
import '../data/live_status_hub.dart';
import '../data/statiq_service.dart';
import '../data/google_api.dart';
import '../data/weather_service.dart';
import '../core/approach_alerts.dart';
import 'charger_icons.dart';
import 'charger_options_sheet.dart';
import 'driver_alert_sound.dart';

LatLng _latLng(GeoPoint p) => LatLng(latitude: p.lat, longitude: p.lng);

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({
    super.key,
    required this.api,
    required this.startSoc,
    required this.energy,
    required this.origin,
    required this.destination,
  });

  final GoogleApi api;
  final double startSoc;
  final EnergyModel energy;
  final GeoPoint origin;
  final Place destination;

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  static const _replanDebounce = Duration(seconds: 3);
  static const _sessionTimeout = Duration(seconds: 30);
  static const _termsPatience = Duration(seconds: 20);

  /// The status download is about 700 KB, so this only runs when chargers are showing.
  static const _statusRefreshEvery = Duration(minutes: 10);

  /// How often to check the stations around the expected charging point.
  static const _healthCheckEvery = Duration(minutes: 3);

  /// Chargers this far either side of the forecast point get monitored.
  static const _monitorRangeKm = 20.0;

  /// The forecast must move this far before the monitored stations change.
  static const _monitorMoveKm = 5.0;

  /// Weather drifts slowly, and the car moves on into new weather.
  static const _weatherRefreshEvery = Duration(minutes: 30);

  /// How long an alert stays on screen.
  static const _alertShownFor = Duration(seconds: 20);


  static const _wantFoodKey = 'wantFoodNearChargers';

  /// As in Google's own example for this plugin.
  static const _navigationUiOffDelay = Duration(milliseconds: 500);

  static const _refitAfterResize = Duration(milliseconds: 400);

  /// How often the battery meter checks for a standing car.
  static const _meterTickEvery = Duration(seconds: 5);

  final _autoView = GoogleMapsAutoViewController();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _sessionSubscriptions = <StreamSubscription<dynamic>>[];
  bool _sessionOpen = false;
  final _markerChargers = <String, RouteCharger>{};

  TripController? _trip;
  ChargerOptionsBuilder? _options;
  GoogleNavigationViewController? _map;
  ChargerIcons? _icons;
  Timer? _replanTimer;
  Timer? _statusTimer;
  Timer? _healthTimer;
  Timer? _weatherTimer;
  Timer? _alertTimer;
  Timer? _meterTimer;
  Timer? _refitTimer;
  DriverAlert? _alert;

  /// Whether restaurants count in the charger ranking. Remembered between trips.
  bool _wantFood = true;
  LiveStatusHub? _hub;
  List<Charger> _freeChargers = const [];
  double? _monitoredKm;

  String? _sessionError;
  bool _sessionReady = false;
  bool _guiding = false;
  bool _starting = false;
  bool _settingDestinations = false;
  bool _autoAvailable = false;
  Size? _mapSize;
  String? _drawnMarkers;
  String? _drawnRoute;
  String? _announcedStopId;

  @override
  void initState() {
    super.initState();
    _restoreWantFood();
    _start();
  }

  @override
  void dispose() {
    _replanTimer?.cancel();
    _statusTimer?.cancel();
    _healthTimer?.cancel();
    _weatherTimer?.cancel();
    _alertTimer?.cancel();
    _meterTimer?.cancel();
    _refitTimer?.cancel();
    for (final s in [..._subscriptions, ..._sessionSubscriptions]) {
      s.cancel();
    }
    _trip?.removeListener(_onTripChanged);
    _trip?.dispose();
    if (_sessionOpen) unawaited(_closeSession());
    super.dispose();
  }

  Future<void> _closeSession() async {
    try {
      await GoogleMapsNavigator.stopGuidance();
      await GoogleMapsNavigator.clearDestinations();
      await GoogleMapsNavigator.cleanup();
    } catch (e) {
      debugPrint('Closing navigation failed: $e');
    }
  }

  Future<void> _start() async {
    final chargers = await ChargerRepository.load();
    if (!mounted) return;
    final status = ChargerStatusService(baseOverride: AppConfig.apiBaseOverride);
    final statiq = StatiqService(baseOverride: AppConfig.apiBaseOverride);
    final hub = LiveStatusHub(feed: status, statiq: statiq);
    final weather = WeatherService(baseOverride: AppConfig.apiBaseOverride);
    _hub = hub;
    _freeChargers = chargers;
    final ultraFastKw = const PlannerRules().ultraFastKw;

    // Google's 180 kW+ chargers along a route, fetched once per route.
    RouteProfile? searchedRoute;
    var googleUltraFast = const <Charger>[];
    Future<List<Charger>> ultraFastAlong(RouteProfile route) async {
      if (!identical(searchedRoute, route)) {
        try {
          googleUltraFast = await widget.api.chargersAlongRoute(route, minKw: ultraFastKw, pages: 3);
          searchedRoute = route;
        } catch (e) {
          // Not remembered, so the next status refresh tries again.
          debugPrint('Fast charger search failed: $e');
          googleUltraFast = const [];
        }
      }
      final statiqFast = hub.statiqOnlyAtLeast(ultraFastKw);
      return [...withoutDuplicates(googleUltraFast, [...chargers, ...statiqFast]), ...statiqFast];
    }

    final trip = TripController(
      startSoc: widget.startSoc,
      energy: widget.energy,
      origin: widget.origin,
      destination: widget.destination.position,
      fetchRoute: (origin, destination, via) =>
          widget.api.computeRoute(origin: origin, destination: destination, via: via),
      refreshLiveStatus: status.refresh,
      fetchAir: weather.airAlong,
      speedDivisor: AppConfig.simulateDrive ? AppConfig.simulationSpeed.toDouble() : 1,
      planner: ChargePlanner(
        freeChargers: chargers,
        searchUltraFast: ultraFastAlong,
        live: hub,
        searchOtherChargers: (near, radiusKm) async {
          final found = await widget.api.chargersNear(near, radiusKm);
          final statiqNearby = hub.statiqOnlyChargers
              .where((c) => distanceKm(c.position, near) <= radiusKm)
              .toList();
          return [...withoutDuplicates(found, [...chargers, ...statiqNearby]), ...statiqNearby];
        },
        checkDetour: (route, place) =>
            widget.api.realDetourKm(route, place.alongKm, place.charger.position),
      ),
    );
    _options = ChargerOptionsBuilder(
      planner: trip.planner,
      findRestaurant: widget.api.greatRestaurantNear,
      findOtherChargers: (route) async {
        final statiqOnRoute = hub.statiqOnlyChargers.where((c) {
          final projection = route.projectNearby(c.position);
          return projection != null && projection.offRouteKm <= 6;
        }).toList();
        var found = const <Charger>[];
        try {
          found = await widget.api.chargersAlongRoute(route);
        } catch (e) {
          debugPrint('Charger search failed: $e');
        }
        // The general search is capped at 20, so the fastest ones are added on.
        final fast = (await ultraFastAlong(route)).where((c) => c.source == ChargerSource.other);
        final google = <String, Charger>{for (final c in [...found, ...fast]) c.id: c}.values.toList();
        return [...withoutDuplicates(google, [...chargers, ...statiqOnRoute]), ...statiqOnRoute];
      },
    );
    trip.addListener(_onTripChanged);
    setState(() => _trip = trip);
    _statusTimer = Timer.periodic(_statusRefreshEvery, (_) {
      if (trip.chargersVisible) trip.refreshChargerStatus();
    });

    _subscriptions.add(gps.Geolocator.getPositionStream(
      locationSettings: const gps.LocationSettings(
        accuracy: gps.LocationAccuracy.high,
        distanceFilter: 25,
      ),
    ).listen((p) {
      final point = GeoPoint(p.latitude, p.longitude);
      trip.tracker.addGpsFix(point);
      trip.updatePosition(point);
    }, onError: (Object e) => debugPrint('GPS error: $e')));

    _healthTimer = Timer.periodic(_healthCheckEvery, (_) => _checkMonitoredStations());
    _weatherTimer = Timer.periodic(_weatherRefreshEvery, (_) => trip.refreshAir());
    _meterTimer = Timer.periodic(_meterTickEvery, (_) {
      if (_guiding) trip.tick();
    });
    await Future.wait([_loadTrip(trip, hub, statiq), _initNavigation()]);
  }

  Future<void> _loadTrip(TripController trip, LiveStatusHub hub, StatiqService statiq) async {
    await trip.load();
    final route = trip.route;
    if (route == null) return;
    // Slow, and the trip can start without it: runs once in the background.
    unawaited(statiq.loadStations(route.points).then((stations) async {
      if (!mounted) return;
      hub.setStatiqStations(stations, _freeChargers);
      _monitoredKm = null;
      await trip.applyLiveStatus();
    }));
  }

  /// Keeps the monitored stations centred on where the battery should reach 30%.
  void _updateMonitoredStations(TripController trip, LiveStatusHub hub) {
    final route = trip.route;
    if (route == null) return;
    final forecast = trip.forecast;
    if (forecast == null) {
      _monitoredKm = null;
      hub.stopWatching();
      return;
    }
    final last = _monitoredKm;
    if (last != null && (forecast.km - last).abs() < _monitorMoveKm) return;
    _monitoredKm = forecast.km;
    hub.watchAround(route, forecast.km, _monitorRangeKm, fromKm: trip.progressKm);
    unawaited(_checkMonitoredStations(onlyDue: true));
  }

  Future<void> _checkMonitoredStations({bool onlyDue = false}) async {
    final hub = _hub;
    final trip = _trip;
    if (hub == null || trip == null || !_guiding) return;
    await hub.checkWatched(onlyDue: onlyDue);
    if (mounted) await trip.applyLiveStatus();
  }

  Future<void> _initNavigation() async {
    try {
      if (!await GoogleMapsNavigator.areTermsAccepted()) {
        // Google's dialog never appears when the API key is rejected, and nothing
        // reports that. It can't time out as such, since the driver may be reading it.
        final notice = Timer(_termsPatience, () {
          _setSessionError('Navigation has not started. If no Google terms are showing, '
              'check the Google API key and your connection.');
        });
        final accepted = await GoogleMapsNavigator.showTermsAndConditionsDialog(
          'Vinfast Copilot',
          'Vinfast Copilot',
        );
        notice.cancel();
        if (mounted) setState(() => _sessionError = null);
        if (!accepted) {
          _setSessionError('Google Navigation terms must be accepted to navigate.');
          return;
        }
      }
      await _openSession();
      await _initCarScreen();
      if (mounted) setState(() => _sessionReady = true);
    } on SessionInitializationException catch (e) {
      _setSessionError(switch (e.code) {
        SessionInitializationError.notAuthorized =>
          'Google rejected the API key. It must be valid and have the Navigation SDK enabled.',
        SessionInitializationError.termsNotAccepted => 'Google Navigation terms were not accepted.',
        SessionInitializationError.locationPermissionMissing => 'Location permission is missing.',
      });
    } on TimeoutException {
      _setSessionError('Navigation did not start. Check your connection and the Google API key.');
    } catch (e) {
      _setSessionError('Could not start navigation: $e');
    }
  }

  /// Starts the navigation session and listens to it. Ending navigation closes
  /// the session, so starting again opens a new one.
  Future<void> _openSession() async {
    await GoogleMapsNavigator.initializeNavigationSession().timeout(_sessionTimeout);
    _sessionSubscriptions.add(await GoogleMapsNavigator.setRoadSnappedLocationUpdatedListener((event) {
      final point = GeoPoint(event.location.latitude, event.location.longitude);
      _trip?.tracker.addSnappedFix(point);
      _trip?.updatePosition(point);
    }));
    _sessionSubscriptions.add(GoogleMapsNavigator.setOnArrivalListener(_onArrival));
    _sessionSubscriptions.add(GoogleMapsNavigator.setOnRouteChangedListener(_onRouteChanged));
    _sessionSubscriptions.add(GoogleMapsNavigator.setOnRemainingTimeOrDistanceChangedListener(
      (event) => _trip?.updateRemainingTime(event.remainingTime),
      remainingTimeThresholdSeconds: 60,
      remainingDistanceThresholdMeters: 1000,
    ));
    _sessionOpen = true;
  }

  Future<void> _closeSessionKeepingMap() async {
    for (final s in _sessionSubscriptions) {
      await s.cancel();
    }
    _sessionSubscriptions.clear();
    _sessionOpen = false;
    // Also clears the route and stops any simulation. Clearing destinations
    // alone often leaves the old route drawn on Android.
    await GoogleMapsNavigator.cleanup();
  }

  void _setSessionError(String message) {
    if (mounted) setState(() => _sessionError = message);
  }

  Future<void> _initCarScreen() async {
    _autoAvailable = await _autoView.isAutoScreenAvailable();
    _autoView.listenForAutoScreenAvailibilityChangedEvent((event) {
      _autoAvailable = event.isAvailable;
      _drawnMarkers = null;
      _drawnRoute = null;
      _announcedStopId = null;
      _onTripChanged();
    });
    _autoView.listenForCustomNavigationAutoEvents((event) {
      switch (event.event) {
        case 'GoToCharger':
          final stop = _trip?.recommendedStop;
          if (stop != null) _goToCharger(stop.place);
        // The driver stopped navigation on the car screen.
        case 'HostStopNavigation':
          unawaited(_endNavigation());
      }
    });
  }

  void _onTripChanged() {
    if (!mounted) return;
    final trip = _trip, hub = _hub;
    if (_guiding && trip != null && hub != null) _updateMonitoredStations(trip, hub);
    if (_guiding && trip != null) _raiseAlert(trip.checkAlerts());
    unawaited(_syncMap());
    unawaited(_announceStopToCar());
    setState(() {});
  }

  Future<void> _syncMap() async {
    final map = _map;
    final trip = _trip;
    final route = trip?.route;
    if (map == null || trip == null || route == null) return;

    final routeKey = route.points.length.toString() + route.totalKm.toString();
    if (routeKey != _drawnRoute) {
      _drawnRoute = routeKey;
      await _drawRoutePreview(map, route);
    }
    await _syncMarkers(map, trip);
  }

  Future<void> _drawRoutePreview(GoogleNavigationViewController map, RouteProfile route) async {
    await map.clearPolylines();
    if (_guiding) return; // Navigation draws its own route line.
    await map.addPolylines([
      PolylineOptions(
        points: route.points.map(_latLng).toList(),
        strokeColor: const Color(0xFF1A73E8),
        strokeWidth: 12,
      ),
    ]);
    await _fitRoute(map, route);
  }

  Future<void> _fitRoute(GoogleNavigationViewController map, RouteProfile route) async {
    var south = route.points.first.lat, north = south;
    var west = route.points.first.lng, east = west;
    for (final p in route.points) {
      if (p.lat < south) south = p.lat;
      if (p.lat > north) north = p.lat;
      if (p.lng < west) west = p.lng;
      if (p.lng > east) east = p.lng;
    }
    await map.moveCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(latitude: south, longitude: west),
        northeast: LatLng(latitude: north, longitude: east),
      ),
      // In logical pixels, on each side: the map can be short with cards below it.
      padding: 32,
    ));
  }

  Future<void> _syncMarkers(GoogleNavigationViewController map, TripController trip) async {
    final icons = _icons;
    if (icons == null) return;
    final chargers = trip.chargersToShow;
    final key = chargers.map((c) => '${c.charger.id}:${trip.isRecommended(c.charger)}').join(',');
    if (key == _drawnMarkers) return;
    _drawnMarkers = key;

    final options = [
      for (final place in chargers)
        MarkerOptions(
          position: _latLng(place.charger.position),
          icon: trip.isRecommended(place.charger)
              ? icons.recommended
              : (trip.isUltraFast(place.charger)
                  ? icons.ultraFast
                  : (place.charger.isFree ? icons.free : icons.other)),
          zIndex: trip.isRecommended(place.charger) ? 2 : 1,
          consumeTapEvents: true,
          infoWindow: InfoWindow(
            title: place.charger.name,
            snippet: place.charger.dcKw > 0 ? '${place.charger.dcKw.round()} kW' : null,
          ),
        ),
    ];
    await map.clearMarkers();
    final markers = await map.addMarkers(options);
    _markerChargers.clear();
    for (var i = 0; i < markers.length; i++) {
      final marker = markers[i];
      if (marker != null) _markerChargers[marker.markerId] = chargers[i];
    }
    if (_autoAvailable) {
      await _autoView.clearMarkers();
      await _autoView.addMarkers(options);
    }
  }

  /// Chime, vibrate, and show it on the phone and the car screen.
  void _raiseAlert(DriverAlert? alert) {
    if (alert == null) return;
    debugPrint('Driver alert (${alert.urgent ? 'urgent' : 'heads-up'}): ${alert.message}');
    unawaited(DriverAlertSound.play(urgent: alert.urgent));
    _alertTimer?.cancel();
    _alertTimer = Timer(_alertShownFor, () {
      if (mounted) setState(() => _alert = null);
    });
    _alert = alert;
    if (_autoAvailable) {
      unawaited(_autoView.sendCustomNavigationAutoEvent('ChargeStop', {'message': alert.message}));
    }
  }

  /// Tells the car screen about a new suggestion, once for each charger.
  Future<void> _announceStopToCar() async {
    final stop = _trip?.recommendedStop;
    if (!_autoAvailable || stop == null) return;
    final charger = stop.place.charger;
    if (_announcedStopId == charger.id) return;
    _announcedStopId = charger.id;
    final km = (stop.place.alongKm - _trip!.progressKm).clamp(0, double.infinity).round();
    final kind = stop.kind == StopKind.topUp ? 'Quick top-up' : (charger.isFree ? 'Free charger' : 'Paid charger');
    await _autoView.sendCustomNavigationAutoEvent('ChargeStop', {
      'message': '$kind in $km km: ${charger.name}',
    });
  }

  Destinations _destinations({RouteCharger? via, String? routeToken}) => Destinations(
        waypoints: [
          if (via != null)
            NavigationWaypoint.withLatLngTarget(
                title: via.charger.name, target: _latLng(via.charger.position)),
          NavigationWaypoint.withLatLngTarget(
              title: widget.destination.name, target: _latLng(widget.destination.position)),
        ],
        displayOptions: NavigationDisplayOptions(showDestinationMarkers: true),
        routeTokenOptions: routeToken == null
            ? null
            : RouteTokenOptions(routeToken: routeToken, travelMode: NavigationTravelMode.driving),
      );

  Future<bool> _setDestinations({RouteCharger? via, String? routeToken}) async {
    _settingDestinations = true;
    try {
      if (!_sessionOpen) await _openSession();
      var status = await GoogleMapsNavigator.setDestinations(
          _destinations(via: via, routeToken: routeToken));
      debugPrint('setDestinations (token: ${routeToken != null}): ${status.name}');
      if (status != NavigationRouteStatus.statusOk && routeToken != null) {
        // Tokens expire. Navigation can still find the route by itself.
        status = await GoogleMapsNavigator.setDestinations(_destinations(via: via));
        debugPrint('setDestinations retry without token: ${status.name}');
      }
      if (status == NavigationRouteStatus.statusOk) return true;
      _showMessage(switch (status) {
        NavigationRouteStatus.apiKeyNotAuthorized =>
          'Google rejected the API key for navigation. Check that the Navigation SDK is enabled.',
        NavigationRouteStatus.networkError => 'No connection. Try again.',
        NavigationRouteStatus.routeNotFound => 'No route found.',
        NavigationRouteStatus.locationUnavailable => 'Waiting for GPS. Try again in a moment.',
        NavigationRouteStatus.quotaExceeded => 'Google Maps quota exceeded.',
        _ => 'Could not start navigation (${status.name}).',
      });
      return false;
    } catch (e) {
      debugPrint('setDestinations threw: $e');
      _showMessage('Could not start navigation: $e');
      return false;
    } finally {
      _settingDestinations = false;
    }
  }

  Future<void> _startGuidance() async {
    setState(() => _starting = true);
    try {
      if (await _setDestinations(routeToken: _trip?.route?.routeToken)) {
        await _enterGuidance();
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _enterGuidance() async {
    final map = _map;
    if (map == null) return;
    await map.clearPolylines();
    await map.setPadding(EdgeInsets.zero);
    await map.setNavigationUIEnabled(true);
    await GoogleMapsNavigator.startGuidance();
    await map.followMyLocation(CameraPerspective.tilted);
    await map.setSpeedometerEnabled(true);
    if (_autoAvailable) await _autoView.setNavigationUIEnabled(true);
    if (AppConfig.simulateDrive) {
      await GoogleMapsNavigator.simulator.simulateLocationsAlongExistingRouteWithOptions(
        SimulationOptions(speedMultiplier: AppConfig.simulationSpeed.toDouble()),
      );
    }
    if (mounted) setState(() => _guiding = true);
    final trip = _trip, hub = _hub;
    if (trip != null && hub != null) _updateMonitoredStations(trip, hub);
  }

  Future<void> _goToCharger(RouteCharger place) async {
    final trip = _trip;
    // A second tap would cancel the route being set by the first.
    if (trip == null || _settingDestinations) return;
    if (await _setDestinations(via: place)) {
      trip.goToCharger(place);
      if (!_guiding) {
        await _enterGuidance();
      } else {
        await GoogleMapsNavigator.startGuidance();
      }
    }
  }

  Future<void> _cancelCharger() async {
    final trip = _trip;
    if (trip == null) return;
    if (await _setDestinations()) {
      trip.cancelStop();
      await GoogleMapsNavigator.startGuidance();
    }
  }

  void _onArrival(OnArrivalEvent event) {
    unawaited(_handleArrival(event));
  }

  Future<void> _handleArrival(OnArrivalEvent event) async {
    final trip = _trip;
    if (trip == null) return;
    final stop = trip.activeStop;
    if (stop != null && event.waypoint.title == stop.charger.name) {
      await GoogleMapsNavigator.continueToNextDestination();
      await GoogleMapsNavigator.startGuidance();
      if (mounted) await _askForSoc(title: 'Charged at ${stop.charger.name}?');
    } else {
      await GoogleMapsNavigator.stopGuidance();
      _showMessage('You have arrived. About ${trip.soc.round()}% left.');
    }
  }

  void _onRouteChanged() {
    // Our own setDestinations also fires this, and the plan is already right then.
    if (!_guiding || _settingDestinations || _trip?.activeStop != null) return;
    _replanTimer?.cancel();
    _replanTimer = Timer(_replanDebounce, () => _trip?.replanFromHere());
  }

  Future<void> _askForSoc({required String title}) async {
    final trip = _trip;
    if (trip == null) return;
    final value = await showDialog<double>(
      context: context,
      builder: (_) => _SocDialog(title: title, initial: trip.soc),
    );
    if (value != null) await trip.updateSoc(value);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showChargerOptions() {
    final trip = _trip;
    final options = _options;
    final route = trip?.route;
    if (trip == null || options == null || route == null) return;
    final stops = trip.plan?.stops ?? const <ChargeStop>[];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => ChargerOptionsSheet(
        outlook: () => _batteryOutlook(context, trip),
        wantFood: _wantFood,
        onWantFoodChanged: _rememberWantFood,
        load: (wantFood) => options.load(
          route: route,
          progressKm: trip.progressKm,
          soc: trip.soc,
          energy: trip.energy,
          suggestedChargerId: stops.isEmpty ? null : stops.first.place.charger.id,
          wantFood: wantFood,
        ),
        onSelected: (site) {
          Navigator.of(context).pop();
          _goToCharger(site.primary);
        },
      ),
    );
  }

  Future<void> _restoreWantFood() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _wantFood = prefs.getBool(_wantFoodKey) ?? true;
    } catch (_) {
      // Food counts unless the driver turned it off.
    }
  }

  Future<void> _rememberWantFood(bool value) async {
    _wantFood = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_wantFoodKey, value);
    } catch (_) {
      // Not remembering is harmless.
    }
  }

  String _batteryOutlook(BuildContext context, TripController trip) {
    final forecast = trip.forecast;
    final level = TripController.forecastLevel.round();
    if (forecast == null) return 'The battery should stay above $level% for this trip.';
    final km = (forecast.km - trip.progressKm).round();
    if (km <= 0) return 'The battery is at about $level% or lower now.';
    final at = TimeOfDay.fromDateTime(DateTime.now().add(Duration(seconds: forecast.secondsAway)));
    final road = switch (forecast.roadKind) {
      RoadKind.expressway => ', on an expressway',
      RoadKind.highway => ', on a highway',
      RoadKind.city => ', on city roads',
      null => '',
    };
    final hub = _hub;
    final checked = hub?.checkedWatchedCount ?? 0;
    // Says nothing until there are results: unchecked mustn't read as unhealthy.
    final health = checked == 0
        ? ''
        : ' ${hub!.healthyWatchedCount} of the $checked closest Statiq-listed stations look healthy.';
    return 'The battery should reach $level% in about $km km, around '
        '${at.format(context)}$road.$health';
  }

  void _showChargerSheet(RouteCharger place) {
    final trip = _trip;
    if (trip == null) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => _ChargerSheet(
        place: place,
        distanceKm: place.alongKm - trip.progressKm,
        onGo: () {
          Navigator.of(context).pop();
          _goToCharger(place);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final trip = _trip;
    return PopScope(
      canPop: !_guiding,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmEndNavigation();
      },
      child: Scaffold(
        // The map gets the space the cards don't need, so nothing covers it.
        body: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: LayoutBuilder(builder: (context, constraints) {
                      _onMapResized(constraints.biggest);
                      return _buildMap();
                    }),
                  ),
                  if (!_guiding)
                    Positioned(
                      top: 0,
                      left: 0,
                      child: SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: PointerInterceptor(
                            child: IconButton.filledTonal(
                              key: const Key('backButton'),
                              tooltip: 'Back',
                              icon: const Icon(Icons.arrow_back),
                              onPressed: () => Navigator.of(context).maybePop(),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (trip != null)
              Material(
                elevation: 8,
                color: Theme.of(context).colorScheme.surface,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    child: _buildPanel(trip),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The preview route is fitted to the map, so it's fitted again when the map
  /// changes size as cards come and go.
  void _onMapResized(Size size) {
    if (_mapSize == size) return;
    _mapSize = size;
    if (_guiding) return;
    // The native map resizes a little after Flutter's layout. Fitting sooner
    // fits the old size and cuts the route off.
    _refitTimer?.cancel();
    _refitTimer = Timer(_refitAfterResize, () {
      final map = _map, route = _trip?.route;
      if (mounted && !_guiding && map != null && route != null) unawaited(_fitRoute(map, route));
    });
  }

  Future<void> _confirmEndNavigation() async {
    final end = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('End navigation?'),
        content: const Text('Guidance stops. The route stays, so you can start again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep going')),
          FilledButton(
            key: const Key('confirmEndButton'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('End'),
          ),
        ],
      ),
    );
    if (end == true) await _endNavigation();
  }

  /// Stops guidance and goes back to the route preview, like Google Maps.
  Future<void> _endNavigation() async {
    if (!_guiding) return;
    setState(() => _guiding = false);
    _alertTimer?.cancel();
    _alert = null;
    _trip?.cancelStop();
    _hub?.stopWatching();
    _monitoredKm = null;
    try {
      await _closeSessionKeepingMap();
      // Switched off straight after cleanup, Android can keep the old route drawn.
      await Future<void>.delayed(_navigationUiOffDelay);
      final map = _map;
      if (map != null) {
        await map.setNavigationUIEnabled(false);
        await map.setSpeedometerEnabled(false);
      }
      if (_autoAvailable) await _autoView.setNavigationUIEnabled(false);
    } catch (e) {
      debugPrint('Ending navigation failed: $e');
    }
    _drawnRoute = null;
    _drawnMarkers = null;
    await _syncMap();
  }

  Widget _buildMap() {
    if (_sessionError != null) {
      return ColoredBox(color: Theme.of(context).colorScheme.surfaceContainerHighest);
    }
    if (!_sessionReady) return const Center(child: CircularProgressIndicator());
    return GoogleMapsNavigationView(
      initialNavigationUIEnabledPreference: NavigationUIEnabledPreference.disabled,
      initialCameraPosition: CameraPosition(target: _latLng(widget.origin), zoom: 12),
      onViewCreated: (controller) async {
        _map = controller;
        // Made once the map exists, so the Maps SDK is ready to take the images.
        _icons = await ChargerIcons.create();
        // A new map view starts empty, whatever was drawn on the last one.
        _drawnMarkers = null;
        _drawnRoute = null;
        await controller.setMyLocationEnabled(true);
        await _syncMap();
      },
      onMarkerClicked: (markerId) {
        final place = _markerChargers[markerId];
        if (place != null) _showChargerSheet(place);
      },
    );
  }

  Widget _buildPanel(TripController trip) {
    if (_guiding) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_alert != null) ...[
            _AlertCard(alert: _alert!, onDismiss: () => setState(() => _alert = null)),
            const SizedBox(height: 8),
          ],
          if (trip.recommendedStop != null) ...[
            _StopCard(
              stop: trip.recommendedStop!,
              arrivalSoc: trip.arrivalSocAt(trip.recommendedStop!.place),
              distanceKm: trip.recommendedStop!.place.alongKm - trip.progressKm,
              onGo: () => _goToCharger(trip.recommendedStop!.place),
            ),
            const SizedBox(height: 8),
          ],
          if (trip.activeStop != null) ...[
            _HeadingToCard(
              place: trip.activeStop!,
              estimate: trip.activeStopEstimate,
              overheadMinutes: trip.planner.rules.stopOverheadMinutes,
              onCancel: _cancelCharger,
            ),
            const SizedBox(height: 8),
          ],
          if (trip.plan?.strandedAtKm != null && trip.chargersVisible) ...[
            _NoChargerCard(km: trip.plan!.strandedAtKm! - trip.progressKm),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              _EndButton(onTap: _confirmEndNavigation),
              const SizedBox(width: 8),
              Expanded(child: _SocPill(trip: trip, onTap: () => _askForSoc(title: 'Update battery charge'))),
              const SizedBox(width: 8),
              _ChargersButton(onTap: _showChargerOptions),
            ],
          ),
        ],
      );
    }
    return _PreviewCard(
      trip: trip,
      destinationName: widget.destination.name,
      sessionError: _sessionError,
      canStart: _sessionReady && _map != null && trip.route != null && !_starting,
      starting: _starting,
      onStart: _startGuidance,
      onRetry: trip.load,
    );
  }
}

String _statusText(Charger charger) => charger.availabilityNote ?? 'Status not checked';

String _formatDuration(int seconds) {
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '$minutes min';
  return '${minutes ~/ 60} h ${minutes % 60} min';
}

/// The cruising speed that gets there soonest, and what faster would cost.
String? _cruiseText(TripController trip) {
  final advice = trip.cruise;
  if (advice == null) return null;
  final arrive = trip.destinationSoc.round();
  final best = advice.best, fast = advice.fastest;
  if (!advice.slowerPays) {
    return 'Cruise at up to ${best.kmh.round()} km/h where allowed: quickest overall, arriving with '
        '$arrive%. Driving slower would save less charging time than it costs.';
  }
  final drive = (best.driveMinutes - fast.driveMinutes).round();
  final charge = (fast.chargeMinutes - best.chargeMinutes).round();
  return 'Cruise at up to ${best.kmh.round()} km/h: quickest overall, arriving with $arrive%. '
      'At ${fast.kmh.round()} you\'d drive $drive min less but charge $charge min more.';
}

/// The weather at the start, which the estimates include.
String? _weatherText(TripController trip) {
  final air = trip.route?.airAt(trip.progressKm);
  if (air == null) return null;
  final temperature = air.temperatureC == null ? '' : '${air.temperatureC!.round()} °C, ';
  return 'Weather in the estimates: ${temperature}wind ${air.windKmh.round()} km/h, '
      'air ${air.densityKgM3.toStringAsFixed(2)} kg/m³';
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.trip,
    required this.destinationName,
    required this.sessionError,
    required this.canStart,
    required this.starting,
    required this.onStart,
    required this.onRetry,
  });

  final TripController trip;
  final String destinationName;
  final String? sessionError;
  final bool canStart;
  final bool starting;
  final VoidCallback onStart;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final route = trip.route;
    final plan = trip.plan;
    return Card(
      key: const Key('previewCard'),
      margin: EdgeInsets.zero,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(destinationName, style: theme.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            if (trip.loading) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('Finding the best route and charging stops'),
            ] else if (trip.error != null) ...[
              Text(trip.error!, style: TextStyle(color: theme.colorScheme.error)),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
            ] else if (route != null && plan != null) ...[
              Text(
                '${route.totalKm.round()} km · ${_formatDuration(route.durationSeconds)} · '
                'now ${trip.soc.round()}%',
                style: theme.textTheme.bodyLarge,
              ),
              if (_weatherText(trip) != null)
                Text(_weatherText(trip)!, key: const Key('weatherLine'), style: theme.textTheme.bodySmall),
              if (_cruiseText(trip) != null) ...[
                const SizedBox(height: 8),
                _SummaryLine(icon: Icons.speed, text: _cruiseText(trip)!),
              ],
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
                child: SingleChildScrollView(child: _PlanSummary(plan: plan, live: trip.liveArrivals)),
              ),
            ],
            if (sessionError != null) ...[
              const SizedBox(height: 8),
              Text(sessionError!, style: TextStyle(color: theme.colorScheme.error)),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const Key('startButton'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: canStart ? onStart : null,
              icon: const Icon(Icons.navigation),
              label: Text(starting ? 'Starting' : 'Start'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlanSummary extends StatelessWidget {
  const _PlanSummary({required this.plan, required this.live});

  final ChargePlan plan;

  /// Arrival charges from the charge now and the current rate of use.
  final ({List<double> stops, double destination})? live;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final arrive = (live?.destination ?? plan.arrivalSoc).round();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (plan.stops.isEmpty && plan.strandedAtKm == null)
          _SummaryLine(
            icon: Icons.battery_charging_full,
            text: 'No charging needed. Arrive with about $arrive%.',
          ),
        for (final (index, stop) in plan.stops.indexed)
          _SummaryLine(
            icon: stop.kind == StopKind.topUp ? Icons.local_cafe : Icons.ev_station,
            color: stop.belowFloor
                ? theme.colorScheme.error
                : (stop.place.charger.dcKw >= const PlannerRules().ultraFastKw
                    ? ChargerIcons.ultraFastColor
                    : (stop.place.charger.isFree ? const Color(0xFF0F9D58) : const Color(0xFFE8710A))),
            text: _stopText(index, stop, live?.stops[index] ?? stop.arrivalSoc),
          ),
        if (plan.stops.isNotEmpty && plan.strandedAtKm == null)
          _SummaryLine(
            icon: Icons.flag,
            text: 'Arrive with about $arrive%.',
          ),
        if (plan.strandedAtKm != null)
          _SummaryLine(
            icon: Icons.warning_amber,
            color: theme.colorScheme.error,
            text: 'No charger reachable above ${const PlannerRules().hardFloorSoc.round()}% near '
                'km ${plan.strandedAtKm!.round()}. Plan your charging before leaving.',
          ),
      ],
    );
  }
}

String _stopText(int index, ChargeStop stop, double arrivalSoc) {
  final charger = stop.place.charger;
  final power = charger.dcKw > 0 ? '${charger.dcKw.round()} kW, ' : '';
  final cost = charger.isFree ? 'free' : 'paid';
  final floor = stop.belowFloor
      ? ' Arrives below the ${const PlannerRules().hardFloorSoc.round()}% safe level: nothing closer was found.'
      : '';
  if (stop.kind == StopKind.topUp) {
    return 'Quick top-up and break at km ${stop.place.alongKm.round()}: ${charger.name}. '
        '$power$cost, arrive ${arrivalSoc.round()}%, ${stop.chargeMinutes} min to '
        '${stop.departureSoc.round()}%. ${_statusText(charger)}.$floor';
  }
  return 'Stop ${index + 1} at km ${stop.place.alongKm.round()}: ${charger.name}. '
      '$power$cost, arrive ${arrivalSoc.round()}%, about ${stop.chargeMinutes} min to '
      '${stop.departureSoc.round()}%. ${_statusText(charger)}.$floor';
}

class _SummaryLine extends StatelessWidget {
  const _SummaryLine({required this.icon, required this.text, this.color});

  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

class _StopCard extends StatelessWidget {
  const _StopCard({required this.stop, required this.arrivalSoc, required this.distanceKm, required this.onGo});

  /// Live, from the charge now and the current rate of use.
  final double arrivalSoc;

  final ChargeStop stop;
  final double distanceKm;
  final VoidCallback onGo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final charger = stop.place.charger;
    final details = [
      if (stop.kind == StopKind.topUp) '${stop.chargeMinutes} min top-up',
      charger.isFree ? 'Free' : 'Paid',
      if (charger.dcKw > 0) '${charger.dcKw.round()} kW',
      '${distanceKm.clamp(0, double.infinity).round()} km ahead',
      'arrive ${arrivalSoc.round()}%',
      if (stop.place.detourKm >= 1) '${stop.place.detourKm.round()} km detour',
      _statusText(charger),
    ].join(' · ');
    return Card(
      key: const Key('stopCard'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.ev_station, size: 44, color: charger.isFree ? const Color(0xFF0F9D58) : const Color(0xFFE8710A)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(charger.name, style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text(details, style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(72, 56)),
              onPressed: onGo,
              child: const Text('Go'),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeadingToCard extends StatelessWidget {
  const _HeadingToCard({
    required this.place,
    required this.estimate,
    required this.overheadMinutes,
    required this.onCancel,
  });

  final RouteCharger place;
  final StopEstimate? estimate;
  final int overheadMinutes;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final e = estimate;
    final highlight = theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700);
    final lowArrival = e != null && e.arrivalSoc < const PlannerRules().hardFloorSoc;
    return Card(
      key: const Key('headingToCard'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            const Icon(Icons.ev_station, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Going to ${place.charger.name}',
                      style: theme.textTheme.titleMedium, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (e != null) ...[
                    const SizedBox(height: 6),
                    Text.rich(TextSpan(children: [
                      const TextSpan(text: 'Arrive '),
                      TextSpan(
                        text: '~${e.arrivalSoc.round()}%',
                        style: highlight?.copyWith(color: lowArrival ? colors.error : null),
                      ),
                      if (e.totalMinutes != null) ...[
                        const TextSpan(text: '  ·  '),
                        TextSpan(text: _formatDuration(e.totalMinutes! * 60), style: highlight),
                        TextSpan(text: ' to ${e.chargeToSoc.round()}%'),
                      ],
                    ])),
                    Text(
                      e.chargeMinutes == null
                          ? 'Charging time unknown: power not listed'
                          : '${e.chargeMinutes} min charging + $overheadMinutes min to park, plug in and leave',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            TextButton(onPressed: onCancel, child: const Text('Skip')),
          ],
        ),
      ),
    );
  }
}

class _NoChargerCard extends StatelessWidget {
  const _NoChargerCard({required this.km});

  final double km;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          'No charger reachable above ${const PlannerRules().hardFloorSoc.round()}% near where the '
          'battery runs low, about ${km.clamp(0, double.infinity).round()} km ahead.',
          style: TextStyle(color: colors.onErrorContainer),
        ),
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  const _AlertCard({required this.alert, required this.onDismiss});

  final DriverAlert alert;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = alert.urgent ? colors.error : colors.tertiaryContainer;
    final foreground = alert.urgent ? colors.onError : colors.onTertiaryContainer;
    return Card(
      key: const Key('alertCard'),
      margin: EdgeInsets.zero,
      color: background,
      child: InkWell(
        onTap: onDismiss,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(alert.urgent ? Icons.warning_rounded : Icons.notifications_active, color: foreground, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Text(alert.message,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(color: foreground)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EndButton extends StatelessWidget {
  const _EndButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: 'End navigation',
      child: Material(
        key: const Key('endButton'),
        color: colors.errorContainer,
        elevation: 3,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 56,
            height: 56,
            child: Icon(Icons.close, color: colors.onErrorContainer, semanticLabel: 'End navigation'),
          ),
        ),
      ),
    );
  }
}

class _ChargersButton extends StatelessWidget {
  const _ChargersButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // Round, like the End button, so the battery reading between them has room.
    return Tooltip(
      message: 'Chargers on your route',
      child: Material(
        key: const Key('chargersButton'),
        color: colors.primaryContainer,
        elevation: 3,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 56,
            height: 56,
            child: Icon(Icons.ev_station, color: colors.onPrimaryContainer, semanticLabel: 'Chargers'),
          ),
        ),
      ),
    );
  }
}

class _SocPill extends StatelessWidget {
  const _SocPill({required this.trip, required this.onTap});

  /// GPS speed wobbles, so a little over the advice isn't flagged.
  static const _cruiseSlack = 5.0;

  final TripController trip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final low = trip.soc <= trip.planner.rules.reserveSoc;
    return Material(
      key: const Key('socPill'),
      color: low ? colors.errorContainer : colors.surfaceContainerHighest,
      elevation: 3,
      borderRadius: BorderRadius.circular(28),
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(low ? Icons.battery_alert : Icons.battery_5_bar),
              const SizedBox(width: 6),
              Text('~${trip.soc.round()}%', style: Theme.of(context).textTheme.titleLarge),
              if (trip.liveKwhPer100 != null || trip.cruiseKmh != null) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (trip.liveKwhPer100 != null)
                        Text('${trip.liveKwhPer100!.toStringAsFixed(1)} kWh/100 km',
                            key: const Key('liveConsumption'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall),
                      if (trip.cruiseKmh != null)
                        Text(
                          'Best ${trip.cruiseKmh!.round()} km/h',
                          key: const Key('cruiseAdvice'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                                // Faster than advised: costing time at the charger.
                                color: (trip.speedKmh ?? 0) > trip.cruiseKmh! + _cruiseSlack ? colors.error : null,
                              ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ChargerSheet extends StatelessWidget {
  const _ChargerSheet({required this.place, required this.distanceKm, required this.onGo});

  final RouteCharger place;
  final double distanceKm;
  final VoidCallback onGo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final charger = place.charger;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(charger.name, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text([
              charger.isFree ? 'Free' : 'Paid',
              if (charger.dcKw > 0) '${charger.dcKw.round()} kW DC',
              '${distanceKm.clamp(0, double.infinity).round()} km ahead',
              '${place.detourKm.round()} km detour',
              _statusText(charger),
            ].join(' · ')),
            if (charger.address.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(charger.address, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: onGo,
              child: const Text('Navigate here first'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SocDialog extends StatefulWidget {
  const _SocDialog({required this.title, required this.initial});

  final String title;
  final double initial;

  @override
  State<_SocDialog> createState() => _SocDialogState();
}

class _SocDialogState extends State<_SocDialog> {
  late final _controller = TextEditingController(text: widget.initial.round().toString());

  double? get _value {
    final v = double.tryParse(_controller.text);
    return v != null && v > 0 && v <= 100 ? v : null;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: const Key('socDialogField'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(labelText: 'Battery now', suffixText: '%'),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _value == null ? null : () => Navigator.pop(context, _value),
          child: const Text('Update'),
        ),
      ],
    );
  }
}
