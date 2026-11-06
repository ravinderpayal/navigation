import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/air_along_route.dart';
import '../core/energy.dart';
import '../core/geo.dart';
import '../core/route_profile.dart';

/// Current weather along a route from Open-Meteo, which needs no key.
/// Its free tier is for non-commercial use.
class WeatherService {
  WeatherService({http.Client? client, String baseOverride = ''})
      : _client = client ?? http.Client(),
        _base = baseOverride.isEmpty ? 'https://api.open-meteo.com' : baseOverride;

  static const _timeout = Duration(seconds: 8);

  /// Weather changes over tens of km, so this is close enough.
  static const _sampleEveryKm = 25.0;
  static const _maxSamples = 40;

  final http.Client _client;
  final String _base;

  /// Null when the service can't be reached. The trip then assumes still, mild air.
  Future<AirAlongRoute?> airAlong(RouteProfile route) async {
    final step = route.totalKm / _maxSamples > _sampleEveryKm ? route.totalKm / _maxSamples : _sampleEveryKm;
    final points = <GeoPoint>[
      for (var km = 0.0; km < route.totalKm; km += step) route.pointAt(km),
      route.pointAt(route.totalKm),
    ];
    try {
      final uri = Uri.parse('$_base/v1/forecast').replace(queryParameters: {
        'latitude': points.map((p) => p.lat.toStringAsFixed(4)).join(','),
        'longitude': points.map((p) => p.lng.toStringAsFixed(4)).join(','),
        'current': 'temperature_2m,relative_humidity_2m,surface_pressure,wind_speed_10m,wind_direction_10m',
        'wind_speed_unit': 'kmh',
      });
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode != 200) return null;
      final samples = parse(jsonDecode(response.body), points);
      return samples.isEmpty ? null : AirAlongRoute(samples);
    } catch (_) {
      return null;
    }
  }

  /// One location comes back as an object, several as a list.
  static List<AirSample> parse(Object? json, List<GeoPoint> points) {
    final entries = json is List ? json : [json];
    final samples = <AirSample>[];
    for (var i = 0; i < entries.length && i < points.length; i++) {
      final current = (entries[i] as Map?)?['current'] as Map?;
      final temperature = (current?['temperature_2m'] as num?)?.toDouble();
      final pressure = (current?['surface_pressure'] as num?)?.toDouble();
      if (current == null || temperature == null || pressure == null) continue;
      samples.add(AirSample(
        points[i],
        AirConditions.fromWeather(
          temperatureC: temperature,
          relativeHumidity: (current['relative_humidity_2m'] as num?)?.toDouble() ?? 50,
          pressureHpa: pressure,
          windKmh: (current['wind_speed_10m'] as num?)?.toDouble() ?? 0,
          windFromDegrees: (current['wind_direction_10m'] as num?)?.toDouble() ?? 0,
        ),
      ));
    }
    return samples;
  }
}
