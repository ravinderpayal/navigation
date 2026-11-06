import 'dart:math' as math;

class GeoPoint {
  const GeoPoint(this.lat, this.lng);
  final double lat;
  final double lng;

  Map<String, dynamic> toLatLngJson() => {'latitude': lat, 'longitude': lng};
}

double distanceKm(GeoPoint a, GeoPoint b) {
  const earthRadiusKm = 6371.0;
  double rad(double deg) => deg * math.pi / 180;
  final dLat = rad(b.lat - a.lat);
  final dLng = rad(b.lng - a.lng);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(a.lat)) * math.cos(rad(b.lat)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * earthRadiusKm * math.asin(math.min(1.0, math.sqrt(h)));
}

/// Direction of travel from [a] to [b], clockwise from north, in degrees.
double bearingDegrees(GeoPoint a, GeoPoint b) {
  double rad(double deg) => deg * math.pi / 180;
  final dLng = rad(b.lng - a.lng);
  final y = math.sin(dLng) * math.cos(rad(b.lat));
  final x = math.cos(rad(a.lat)) * math.sin(rad(b.lat)) -
      math.sin(rad(a.lat)) * math.cos(rad(b.lat)) * math.cos(dLng);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Decodes a Google encoded polyline.
List<GeoPoint> decodePolyline(String encoded) {
  final points = <GeoPoint>[];
  var index = 0, lat = 0, lng = 0;
  int next() {
    var shift = 0, result = 0, b = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    return (result & 1) != 0 ? ~(result >> 1) : result >> 1;
  }

  while (index < encoded.length) {
    lat += next();
    lng += next();
    points.add(GeoPoint(lat / 1e5, lng / 1e5));
  }
  return points;
}
