import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/charger.dart';
import '../core/geo.dart';
import '../core/live_status.dart';

/// Live charger status from chargeindia.com. Every failure here means "unknown":
/// a status outage must never stop a trip from being planned.
class ChargerStatusService extends LiveStatusSource {
  ChargerStatusService({http.Client? client, String baseOverride = '', DateTime Function()? clock})
      : _client = client ?? http.Client(),
        _base = baseOverride.isEmpty ? 'https://chargeindia.com' : baseOverride,
        _clock = clock ?? DateTime.now;

  static const _requestTimeout = Duration(seconds: 10);

  /// Older data than this could hide chargers that have since come back.
  static const _maxAge = Duration(minutes: 30);
  static const _ccs2 = 'IEC_62196_T2_COMBO';
  static const _busyLabel = 'In use';

  final http.Client _client;
  final String _base;
  final DateTime Function() _clock;

  StationMatcher? _matcher;
  DateTime? _dataTime;

  bool get _fresh {
    final time = _dataTime;
    return time != null && _clock().difference(time) < _maxAge;
  }

  /// Downloads the station list. Keeps the previous one if that fails.
  Future<void> refresh() async {
    try {
      final response = await _client
          .get(Uri.parse('$_base/api/stations/discovery'))
          .timeout(_requestTimeout);
      if (response.statusCode != 200) return;
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      final stations = <LiveStation>[];
      for (final s in (json['stations'] as List? ?? const [])) {
        final lat = s['latitude'], lng = s['longitude'], id = s['id'];
        if (lat is! num || lng is! num || id is! String) continue;
        stations.add(LiveStation(
          id: id,
          name: (s['name'] ?? '') as String,
          position: GeoPoint(lat.toDouble(), lng.toDouble()),
          available: s['available'] == true,
        ));
      }
      if (stations.isEmpty) return;
      _matcher = StationMatcher(stations);
      _dataTime = DateTime.tryParse((json['updatedAt'] ?? '') as String) ?? _clock();
    } catch (_) {
      // Stays on the previous data until that goes stale.
    }
  }

  @override
  LiveStatus statusOf(Charger charger) {
    if (!_fresh) return LiveStatus.unknown;
    final station = _matcher?.match(charger);
    if (station == null) return LiveStatus.unknown;
    return station.available ? LiveStatus.available : LiveStatus.unavailable;
  }

  @override
  Future<StationCheck?> check(Charger charger) async {
    final station = _fresh ? _matcher?.match(charger) : null;
    if (station == null) return null;
    try {
      final response = await _client
          .get(Uri.parse('$_base/api/stations/${station.id}'))
          .timeout(_requestTimeout);
      if (response.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      return parseStation(json['station'] as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Judges a station by its CCS2 DC connectors alone: a free AC socket doesn't
  /// help a car that needs a fast charge. Null when there are no connectors to judge.
  static StationCheck? parseStation(Map<String, dynamic> station) {
    final connectors = (station['connectors'] as List? ?? const []).cast<Map<String, dynamic>>();
    if (station['isUpcoming'] == true) return const StationCheck(StationState.dead);
    if (connectors.isEmpty) return null;

    final usable = connectors
        .where((c) => c['connectorType'] == _ccs2 && c['currentType'] == 'DC')
        .toList();
    if (usable.isEmpty) return const StationCheck(StationState.dead);

    final free = usable.where((c) => c['available'] == true).length;
    if (free > 0) {
      return StationCheck(StationState.free,
          note: '$free of ${usable.length} free now', freeGuns: free, totalGuns: usable.length);
    }
    if (usable.any((c) => c['statusLabel'] == _busyLabel)) {
      return StationCheck(StationState.busy,
          note: 'In use now', freeGuns: 0, totalGuns: usable.length);
    }
    return const StationCheck(StationState.dead);
  }
}
