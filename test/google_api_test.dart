import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vinfast_copilot/core/energy.dart';
import 'package:vinfast_copilot/core/geo.dart';
import 'package:vinfast_copilot/data/google_api.dart';

http.Response _json(Object body, [int status = 200]) => http.Response.bytes(
    utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

void main() {
  const near = GeoPoint(28.6, 77.2);

  test('autocomplete sends the required headers and parses suggestions', () async {
    late http.Request sent;
    final api = GoogleApi(apiKey: 'K', client: MockClient((r) async {
      sent = r;
      return _json({
        'suggestions': [
          {'placePrediction': {'placeId': 'A', 'text': {'text': 'Jaipur, Rajasthan'},
            'structuredFormat': {'mainText': {'text': 'Jaipur'}, 'secondaryText': {'text': 'Rajasthan'}}}},
          {'queryPrediction': {'text': {'text': 'ignored'}}},
        ],
      });
    }));
    final s = await api.autocomplete('jai', sessionToken: 'tok', near: near);
    expect(sent.url.toString(), 'https://places.googleapis.com/v1/places:autocomplete');
    expect(sent.headers['X-Goog-Api-Key'], 'K');
    final body = jsonDecode(sent.body);
    expect(body['includedRegionCodes'], ['in']);
    expect(body['sessionToken'], 'tok');
    expect(s.single.title, 'Jaipur');
    expect(s.single.subtitle, 'Rajasthan');
  });

  test('errors carry the message from Google', () async {
    final api = GoogleApi(apiKey: 'bad', client: MockClient((_) async => _json({
      'error': {'code': 403, 'message': 'API key not valid.', 'status': 'PERMISSION_DENIED'},
    }, 403)));
    expect(() => api.autocomplete('x', sessionToken: 't'),
        throwsA(isA<GoogleApiException>().having((e) => e.message, 'message', contains('API key not valid'))));
  });

  test('computeRoute parses distance, token and slow stretches', () async {
    final api = GoogleApi(apiKey: 'K', client: MockClient((r) async {
      expect(r.url.path, '/directions/v2:computeRoutes');
      expect(jsonDecode(r.body)['routingPreference'], 'TRAFFIC_AWARE');
      return _json({
        'routes': [
          {
            'duration': '3600s',
            'routeToken': 'tok',
            // Three points, each about 157 km apart.
            'polyline': {'encodedPolyline': '_p~iF~ps|U_ulLnnqC_mqNvxq`@'},
            'legs': [
              {'steps': [
                {'distanceMeters': 10000, 'staticDuration': '1800s'}, // 20 km/h: city
                {'distanceMeters': 100000, 'staticDuration': '3600s'}, // 100 km/h: open road
              ]},
            ],
            'travelAdvisory': {'speedReadingIntervals': [
              {'startPolylinePointIndex': 0, 'endPolylinePointIndex': 1, 'speed': 'NORMAL'},
              {'startPolylinePointIndex': 1, 'endPolylinePointIndex': 2, 'speed': 'TRAFFIC_JAM'},
            ]},
          },
        ],
      });
    }));
    final route = await api.computeRoute(origin: near, destination: near);
    expect(route.durationSeconds, 3600);
    expect(route.routeToken, 'tok');
    // Steps are scaled to the polyline: city for the first 9%, then open road.
    expect(route.isSlowAt(route.totalKm * 0.05), isTrue);
    expect(route.isSlowAt(route.totalKm * 0.2), isFalse);
    expect(route.roadKindAt(route.totalKm * 0.05), RoadKind.city);
    expect(route.roadKindAt(route.totalKm * 0.2), RoadKind.expressway);
    expect(route.isSlowAt(route.totalKm - 1), isTrue, reason: 'traffic jam at the end');
  });

  test('no routes is a clear error', () async {
    final api = GoogleApi(apiKey: 'K', client: MockClient((_) async => _json({})));
    expect(() => api.computeRoute(origin: near, destination: near),
        throwsA(isA<GoogleApiException>()));
  });

  test('chargersNear drops closed, busy and far stations', () async {
    Map<String, dynamic> place(String id, double lat, {String status = 'OPERATIONAL', int? available}) => {
          'id': id,
          'displayName': {'text': id},
          'location': {'latitude': lat, 'longitude': 77.2},
          'businessStatus': status,
          'evChargeOptions': {'connectorAggregation': [
            {'type': 'EV_CONNECTOR_TYPE_CCS_COMBO_2', 'maxChargeRateKw': 60, 'count': 4, 'availableCount': ?available},
            {'type': 'EV_CONNECTOR_TYPE_TYPE_2', 'maxChargeRateKw': 7, 'count': 2},
          ]},
        };
    final api = GoogleApi(apiKey: 'K', client: MockClient((_) async => _json({
      'places': [
        place('ok', 28.6, available: 2),
        place('unknown', 28.601),
        place('closed', 28.6, status: 'CLOSED_PERMANENTLY'),
        place('busy', 28.6, available: 0),
        place('far', 29.5),
      ],
    })));
    final found = await api.chargersNear(near, 10);
    expect(found.map((c) => c.name), ['ok', 'unknown']);
    expect(found.first.dcKw, 60);
    expect(found.first.isFree, isFalse);
    expect(found.first.availabilityNote, '2 of 4 free');
    expect(found.last.availabilityNote, isNull);
  });

  test('chargers along a route: asks for the minimum power and follows pages', () async {
    final bodies = <Map<String, dynamic>>[];
    final api = GoogleApi(apiKey: 'K', client: MockClient((r) async {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      bodies.add(body);
      expect(r.headers['X-Goog-FieldMask'], contains('nextPageToken'));
      Map<String, dynamic> place(String id, double kw) => {
            'id': id,
            'displayName': {'text': id},
            'location': {'latitude': 28.5, 'longitude': 77.1},
            'evChargeOptions': {
              'connectorAggregation': [
                {'type': 'EV_CONNECTOR_TYPE_CCS_COMBO_2', 'maxChargeRateKw': kw, 'count': 2},
              ],
            },
          };
      return body['pageToken'] == null
          ? _json({'places': [place('A', 180), place('slow', 60)], 'nextPageToken': 'p2'})
          : _json({'places': [place('B', 240)]});
    }));
    final route = GoogleApi.parseRoute({
      'polyline': {'encodedPolyline': '_p~iF~ps|U_ulLnnqC_mqNvxq`@'},
    });
    final found = await api.chargersAlongRoute(route, minKw: 180, pages: 3);
    expect(bodies.length, 2);
    expect(bodies.first['evOptions']['minimumChargingRateKw'], 180);
    expect(bodies.last['pageToken'], 'p2');
    expect(found.map((c) => c.name), ['A', 'B'], reason: 'listings under 180 kW are dropped');
  });

  test('a failed detour check returns null rather than throwing', () async {
    final api = GoogleApi(apiKey: 'K', client: MockClient((_) async => _json({}, 500)));
    final route = await GoogleApi(apiKey: 'K', client: MockClient((_) async => _json({
      'routes': [{'polyline': {'encodedPolyline': '_p~iF~ps|U_ulLnnqC_mqNvxq`@'}}],
    }))).computeRoute(origin: near, destination: near);
    expect(await api.realDetourKm(route, 50, near), isNull);
  });
}
