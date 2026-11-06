import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/geo.dart';
import '../core/live_status.dart';

/// Statiq's station map and live station details.
class StatiqService {
  StatiqService({http.Client? client, String baseOverride = '', DateTime Function()? clock})
      : _client = client ?? http.Client(),
        _base = baseOverride.isEmpty ? 'https://backend.statiq.co.in' : baseOverride,
        _clock = clock ?? DateTime.now;

  /// The station map is slow, and only ever loaded once for a trip.
  static const _markersTimeout = Duration(seconds: 120);
  static const _detailTimeout = Duration(seconds: 12);

  /// Keeps stations just outside the route's bounding box in the results.
  static const _boxPaddingDegrees = 0.07;
  static const _ccs2ConnectorTypeId = 1;

  final http.Client _client;
  final String _base;
  final DateTime Function() _clock;

  /// CCS2 stations in a box around the route. Empty if the request fails, because
  /// the trip works without them.
  Future<List<LiveStation>> loadStations(List<GeoPoint> route) async {
    try {
      final response = await _client
          .post(Uri.parse('$_base/station/v1/markers'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode(markersRequest(route)))
          .timeout(_markersTimeout);
      if (response.statusCode != 200) return const [];
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final stations = <LiveStation>[];
      for (final s in (json['data']?['stations'] as List? ?? const [])) {
        final lat = s['latitude'], lng = s['longitude'], id = s['station_id'];
        if (lat is! num || lng is! num || id == null) continue;
        stations.add(LiveStation(
          id: '$id',
          name: (s['station_name'] ?? '') as String,
          address: (s['address'] ?? '') as String,
          position: GeoPoint(lat.toDouble(), lng.toDouble()),
          available: false, // Not in this feed: only details tell.
        ));
      }
      return stations;
    } catch (_) {
      return const [];
    }
  }

  static Map<String, dynamic> markersRequest(List<GeoPoint> route) {
    var south = route.first.lat, north = south, west = route.first.lng, east = west;
    for (final p in route) {
      if (p.lat < south) south = p.lat;
      if (p.lat > north) north = p.lat;
      if (p.lng < west) west = p.lng;
      if (p.lng > east) east = p.lng;
    }
    south -= _boxPaddingDegrees;
    north += _boxPaddingDegrees;
    west -= _boxPaddingDegrees;
    east += _boxPaddingDegrees;
    return {
      'latitude': (south + north) / 2,
      'longitude': (west + east) / 2,
      'all_chargers': 0,
      'connector_id': [_ccs2ConnectorTypeId],
      // A closed ring of [longitude, latitude] corners.
      'vertices': [
        [west, north],
        [east, north],
        [east, south],
        [west, south],
        [west, north],
      ],
    };
  }

  /// Null when the check itself fails.
  Future<StationCheck?> check(String stationId) async {
    final id = int.tryParse(stationId);
    if (id == null) return null;
    try {
      final response = await _client
          .post(Uri.parse('$_base/station/v1/details'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'latitude': 0, 'longitude': 0, 'station_id': id}))
          .timeout(_detailTimeout);
      if (response.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final station = json['data']?['station_detail'];
      if (station is! Map<String, dynamic>) return null;
      return parseStation(station, _clock());
    } catch (_) {
      return null;
    }
  }

  /// Judges a station by its CCS2 DC connectors. From a sample of real responses:
  /// - `is_connected` decides first. Disconnected stations can still report
  ///   `charging`, with a last use months ago, so their connector status is stale.
  /// - `error_message` is ignored. It often says "Faulted" on working connectors.
  static StationCheck parseStation(Map<String, dynamic> station, DateTime now) {
    if (station['is_connected'] != true) return const StationCheck(StationState.dead);

    var total = 0, free = 0, busy = 0;
    var kw = 0.0;
    DateTime? lastUsed;
    for (final plugin in (station['plugin_details'] as List? ?? const [])) {
      if (plugin['type'] != 'DC') continue;
      var hasCcs2 = false;
      for (final connector in (plugin['connectors'] as List? ?? const [])) {
        if (connector['connector_type'] != 'CCS-2') continue;
        hasCcs2 = true;
        total++;
        if (connector['availability'] == true) {
          free++;
        } else if (const {'charging', 'finishing', 'suspendedev', 'suspendedevse'}
            .contains('${connector['connector_status']}'.toLowerCase())) {
          busy++;
        }
      }
      if (!hasCcs2) continue;
      final rating = (plugin['power_rating'] as num?)?.toDouble() ?? 0;
      if (rating > kw) kw = rating;
      final used = _parseDate(plugin['last_used_on']);
      if (used != null && (lastUsed == null || used.isAfter(lastUsed))) lastUsed = used;
    }

    final usedNote = _usedNote(lastUsed, now);
    if (free > 0) {
      return StationCheck(StationState.free,
          note: '$free of $total free now', freeGuns: free, totalGuns: total, kw: kw, healthNote: usedNote);
    }
    if (busy > 0) {
      return StationCheck(StationState.busy,
          note: 'In use now', freeGuns: 0, totalGuns: total, kw: kw, healthNote: usedNote);
    }
    return const StationCheck(StationState.dead);
  }

  /// Dates arrive as dd/MM/yyyy.
  static DateTime? _parseDate(Object? value) {
    final parts = '$value'.split('/');
    if (parts.length != 3) return null;
    final day = int.tryParse(parts[0]), month = int.tryParse(parts[1]), year = int.tryParse(parts[2]);
    return day == null || month == null || year == null ? null : DateTime(year, month, day);
  }

  static String? _usedNote(DateTime? lastUsed, DateTime now) {
    if (lastUsed == null) return null;
    final days = DateTime(now.year, now.month, now.day).difference(lastUsed).inDays;
    if (days <= 0) return 'Used today';
    return days == 1 ? 'Used yesterday' : 'Last used $days days ago';
  }
}
