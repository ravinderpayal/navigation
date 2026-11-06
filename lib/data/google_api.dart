import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/charge_planner.dart';
import '../core/charger.dart';
import '../core/charger_options.dart';
import '../core/geo.dart';
import '../core/route_profile.dart';

class GoogleApiException implements Exception {
  GoogleApiException(this.message);
  final String message;

  @override
  String toString() => message;
}

class PlaceSuggestion {
  const PlaceSuggestion({required this.placeId, required this.title, required this.subtitle});
  final String placeId;
  final String title;
  final String subtitle;
}

class Place {
  const Place({required this.name, required this.position});
  final String name;
  final GeoPoint position;
}

/// Google Places API (New) and Routes API.
class GoogleApi {
  GoogleApi({required this.apiKey, http.Client? client, String baseOverride = ''})
      : _client = client ?? http.Client(),
        _placesBase = baseOverride.isEmpty ? 'https://places.googleapis.com' : baseOverride,
        _routesBase = baseOverride.isEmpty ? 'https://routes.googleapis.com' : baseOverride;

  static const _requestTimeout = Duration(seconds: 15);
  static const _ccs2 = 'EV_CONNECTOR_TYPE_CCS_COMBO_2';
  static const _chargerFieldMask = 'places.id,places.displayName,places.formattedAddress,'
      'places.location,places.businessStatus,places.evChargeOptions';

  /// Google only names congestion levels, so these are estimates of what they mean.
  static const _slowSpeedFactor = 0.6;
  static const _jamSpeedFactor = 0.25;

  /// A walk from the car while it charges.
  static const _restaurantRadiusMeters = 500.0;
  static const _greatRestaurantRating = 4.2;

  /// A few friendly reviews don't make a place highly rated.
  static const _greatRestaurantMinRatings = 100;

  final String apiKey;
  final http.Client _client;
  final String _placesBase;
  final String _routesBase;

  Future<List<PlaceSuggestion>> autocomplete(
    String input, {
    required String sessionToken,
    GeoPoint? near,
  }) async {
    final json = await _post('$_placesBase/v1/places:autocomplete', {
      'input': input,
      'sessionToken': sessionToken,
      'includedRegionCodes': ['in'],
      'languageCode': 'en',
      if (near != null)
        'locationBias': {
          'circle': {'center': near.toLatLngJson(), 'radius': 50000.0},
        },
    });
    final suggestions = <PlaceSuggestion>[];
    for (final s in (json['suggestions'] as List? ?? const [])) {
      final p = s['placePrediction'];
      if (p == null) continue;
      suggestions.add(PlaceSuggestion(
        placeId: p['placeId'] as String,
        title: (p['structuredFormat']?['mainText']?['text'] ?? p['text']?['text'] ?? '') as String,
        subtitle: (p['structuredFormat']?['secondaryText']?['text'] ?? '') as String,
      ));
    }
    return suggestions;
  }

  Future<Place> placeDetails(String placeId, {required String sessionToken}) async {
    final uri = Uri.parse('$_placesBase/v1/places/$placeId')
        .replace(queryParameters: {'sessionToken': sessionToken});
    final json = _decode(await _client.get(uri, headers: {
      'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask': 'displayName,location',
    }).timeout(_requestTimeout));
    final location = json['location'];
    if (location == null) throw GoogleApiException('Google returned no location for this place.');
    return Place(
      name: (json['displayName']?['text'] ?? 'Destination') as String,
      position: GeoPoint(
          (location['latitude'] as num).toDouble(), (location['longitude'] as num).toDouble()),
    );
  }

  /// The best traffic-aware driving route, optionally through [via] first.
  Future<RouteProfile> computeRoute({
    required GeoPoint origin,
    required GeoPoint destination,
    GeoPoint? via,
  }) async {
    final json = await _post('$_routesBase/directions/v2:computeRoutes', {
      'origin': _waypoint(origin),
      'destination': _waypoint(destination),
      if (via != null) 'intermediates': [_waypoint(via)],
      'travelMode': 'DRIVE',
      'routingPreference': 'TRAFFIC_AWARE',
      'extraComputations': ['TRAFFIC_ON_POLYLINE'],
      'polylineEncoding': 'ENCODED_POLYLINE',
      'languageCode': 'en-IN',
      'regionCode': 'IN',
      'units': 'METRIC',
    }, fieldMask: 'routes.duration,routes.polyline.encodedPolyline,routes.routeToken,'
        'routes.legs.steps.distanceMeters,routes.legs.steps.staticDuration,'
        'routes.travelAdvisory.speedReadingIntervals');
    final routes = json['routes'] as List? ?? const [];
    if (routes.isEmpty) throw GoogleApiException('No driving route found to this destination.');
    return parseRoute(routes.first as Map<String, dynamic>);
  }

  /// Extra km driven to visit [charger] from the route, using real roads.
  /// Null when the check fails, so a network blip never blocks a plan.
  Future<double?> realDetourKm(RouteProfile route, double alongKm, GeoPoint charger) async {
    // Routing between points just either side of the charger keeps the direction
    // of travel, so a charger on the far side of a divided highway costs what it should.
    const halfSpanKm = 1.0;
    final startKm = (alongKm - halfSpanKm).clamp(0.0, route.totalKm);
    final endKm = (alongKm + halfSpanKm).clamp(0.0, route.totalKm);
    try {
      final json = await _post('$_routesBase/directions/v2:computeRoutes', {
        'origin': _waypoint(route.pointAt(startKm)),
        'destination': _waypoint(route.pointAt(endKm)),
        'intermediates': [_waypoint(charger)],
        'travelMode': 'DRIVE',
        'routingPreference': 'TRAFFIC_UNAWARE',
        'units': 'METRIC',
      }, fieldMask: 'routes.distanceMeters');
      final routes = json['routes'] as List? ?? const [];
      if (routes.isEmpty) return null;
      final meters = routes.first['distanceMeters'] as num?;
      if (meters == null) return null;
      final extra = meters / 1000 - (endKm - startKm);
      return extra < 0 ? 0.0 : extra;
    } catch (_) {
      return null;
    }
  }

  /// CCS2 fast chargers near a point. Closed stations are left out, and so are
  /// stations Google reports as having no free connector.
  Future<List<Charger>> chargersNear(GeoPoint point, double radiusKm) async {
    final json = await _post('$_placesBase/v1/places:searchText', {
      'textQuery': 'EV charging station',
      'includedType': 'electric_vehicle_charging_station',
      'evOptions': {
        'connectorTypes': [_ccs2],
        'minimumChargingRateKw': 20,
      },
      'locationBias': {
        'circle': {'center': point.toLatLngJson(), 'radius': radiusKm * 1000},
      },
      'rankPreference': 'DISTANCE',
      'pageSize': 20,
    }, fieldMask: _chargerFieldMask);
    return _parseChargers(json).where((c) => distanceKm(point, c.position) <= radiusKm).toList();
  }

  /// CCS2 chargers of at least [minKw] along a route, with the same filtering as
  /// [chargersNear]. Each page holds up to 20; Google gives up to 3.
  Future<List<Charger>> chargersAlongRoute(RouteProfile route, {double minKw = 20, int pages = 1}) async {
    final polyline = route.encodedPolyline;
    if (polyline == null) return const [];
    final chargers = <Charger>[];
    String? pageToken;
    for (var page = 0; page < pages; page++) {
      final json = await _post('$_placesBase/v1/places:searchText', {
        'textQuery': 'EV charging station',
        'includedType': 'electric_vehicle_charging_station',
        'evOptions': {
          'connectorTypes': [_ccs2],
          'minimumChargingRateKw': minKw,
        },
        'searchAlongRouteParameters': {
          'polyline': {'encodedPolyline': polyline},
        },
        'pageSize': 20,
        'pageToken': ?pageToken,
      }, fieldMask: '$_chargerFieldMask,nextPageToken');
      chargers.addAll(_parseChargers(json).where((c) => c.dcKw >= minKw));
      pageToken = json['nextPageToken'] as String?;
      if (pageToken == null) break;
    }
    return chargers;
  }

  /// The best-rated popular restaurant close to a point, if any is highly rated.
  Future<Restaurant?> greatRestaurantNear(GeoPoint point) async {
    final json = await _post('$_placesBase/v1/places:searchNearby', {
      'includedTypes': ['restaurant'],
      'maxResultCount': 10,
      'rankPreference': 'POPULARITY',
      'locationRestriction': {
        'circle': {'center': point.toLatLngJson(), 'radius': _restaurantRadiusMeters},
      },
    }, fieldMask: 'places.displayName,places.rating,places.userRatingCount,places.businessStatus');
    Restaurant? best;
    for (final p in (json['places'] as List? ?? const [])) {
      if ((p['businessStatus'] ?? 'OPERATIONAL') != 'OPERATIONAL') continue;
      final rating = (p['rating'] as num?)?.toDouble() ?? 0;
      final count = (p['userRatingCount'] as num?)?.toInt() ?? 0;
      if (rating < _greatRestaurantRating || count < _greatRestaurantMinRatings) continue;
      if (best == null || rating > best.rating) {
        best = Restaurant(
            name: (p['displayName']?['text'] ?? 'Restaurant') as String,
            rating: rating,
            ratingCount: count);
      }
    }
    return best;
  }

  /// Closed stations are left out, and so are stations Google reports as having
  /// no free connector.
  List<Charger> _parseChargers(Map<String, dynamic> json) {
    final chargers = <Charger>[];
    for (final p in (json['places'] as List? ?? const [])) {
      final location = p['location'];
      if (location == null) continue;
      if ((p['businessStatus'] ?? 'OPERATIONAL') != 'OPERATIONAL') continue;
      final position = GeoPoint(
          (location['latitude'] as num).toDouble(), (location['longitude'] as num).toDouble());

      var maxKw = 0.0;
      int? total, available;
      for (final a in (p['evChargeOptions']?['connectorAggregation'] as List? ?? const [])) {
        if (a['type'] != _ccs2) continue;
        final kw = (a['maxChargeRateKw'] as num?)?.toDouble() ?? 0;
        if (kw > maxKw) maxKw = kw;
        total = (total ?? 0) + ((a['count'] as num?)?.toInt() ?? 0);
        final free = a['availableCount'] as num?;
        if (free != null) available = (available ?? 0) + free.toInt();
      }
      if (available == 0) continue;
      chargers.add(Charger(
        id: 'places:${p['id']}',
        name: (p['displayName']?['text'] ?? 'EV charging station') as String,
        address: (p['formattedAddress'] ?? '') as String,
        position: position,
        dcKw: maxKw,
        dcCount: total == null || total < 1 ? 1 : total,
        freeGuns: available,
        source: ChargerSource.other,
        availabilityNote: available == null || total == null ? null : '$available of $total free',
      ));
    }
    return chargers;
  }

  static RouteProfile parseRoute(Map<String, dynamic> route) {
    final encoded = route['polyline']['encodedPolyline'] as String;
    final points = decodePolyline(encoded);
    if (points.length < 2) throw GoogleApiException('Google returned an empty route.');

    final totalMeters = [
      for (final leg in (route['legs'] as List? ?? const []))
        for (final step in (leg['steps'] as List? ?? const [])) ((step['distanceMeters'] as num?) ?? 0),
    ].fold<num>(0, (a, b) => a + b);
    var polylineKm = 0.0;
    for (var i = 1; i < points.length; i++) {
      polylineKm += distanceKm(points[i - 1], points[i]);
    }
    // The simplified line is a little shorter than the true road, so steps are scaled to fit it.
    final kmScale = totalMeters > 0 ? polylineKm / (totalMeters / 1000) : 1.0;

    final stretches = <SlowStretch>[];
    final speedBands = <SpeedBand>[];
    var km = 0.0;
    for (final leg in (route['legs'] as List? ?? const [])) {
      for (final step in (leg['steps'] as List? ?? const [])) {
        final realKm = ((step['distanceMeters'] as num?) ?? 0) / 1000;
        final stepKm = realKm * kmScale;
        final seconds = _seconds(step['staticDuration']);
        if (realKm > 0 && seconds > 0) {
          final kmh = realKm / (seconds / 3600);
          speedBands.add(SpeedBand(km, km + stepKm, kmh));
          if (kmh < const PlannerRules().cityBelowKmh) stretches.add(SlowStretch(km, km + stepKm));
        }
        km += stepKm;
      }
    }

    // Traffic intervals are given as polyline point indexes.
    final trafficBands = <TrafficBand>[];
    final pointKm = <double>[0];
    for (var i = 1; i < points.length; i++) {
      pointKm.add(pointKm.last + distanceKm(points[i - 1], points[i]));
    }
    for (final interval in (route['travelAdvisory']?['speedReadingIntervals'] as List? ?? const [])) {
      final speed = interval['speed'];
      if (speed != 'SLOW' && speed != 'TRAFFIC_JAM') continue;
      final start = ((interval['startPolylinePointIndex'] as num?) ?? 0).toInt();
      final end = ((interval['endPolylinePointIndex'] as num?) ?? 0).toInt();
      if (start >= pointKm.length || end >= pointKm.length) continue;
      stretches.add(SlowStretch(pointKm[start], pointKm[end]));
      trafficBands.add(TrafficBand(pointKm[start], pointKm[end], speed == 'TRAFFIC_JAM' ? _jamSpeedFactor : _slowSpeedFactor));
    }

    return RouteProfile(
      points: points,
      slowStretches: stretches,
      durationSeconds: _seconds(route['duration']),
      routeToken: route['routeToken'] as String?,
      encodedPolyline: encoded,
      speedBands: speedBands,
      trafficBands: trafficBands,
    );
  }

  /// Parses a protobuf duration such as "1234s".
  static int _seconds(Object? value) =>
      value is String ? (double.tryParse(value.replaceAll('s', '')) ?? 0).round() : 0;

  Map<String, dynamic> _waypoint(GeoPoint p) => {
        'location': {'latLng': p.toLatLngJson()},
      };

  Future<Map<String, dynamic>> _post(
    String url,
    Map<String, dynamic> body, {
    String? fieldMask,
  }) async {
    final response = await _client
        .post(Uri.parse(url),
            headers: {
              'Content-Type': 'application/json',
              'X-Goog-Api-Key': apiKey,
              'X-Goog-FieldMask': ?fieldMask,
            },
            body: jsonEncode(body))
        .timeout(_requestTimeout);
    return _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic>? json;
    try {
      json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {}
    if (response.statusCode != 200 || json == null) {
      final detail = json?['error']?['message'] ?? 'HTTP ${response.statusCode}';
      throw GoogleApiException('Google API error: $detail');
    }
    return json;
  }
}
