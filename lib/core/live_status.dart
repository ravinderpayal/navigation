import 'charger.dart';
import 'geo.dart';

/// What the charger network reports for a station as a whole.
enum LiveStatus {
  /// Not in the live feed, or the feed is unavailable. Says nothing either way.
  unknown,
  available,
  unavailable,
}

/// What a charging-capable connector at a station is doing right now.
enum StationState {
  /// At least one CCS2 DC connector is free.
  free,

  /// All in use, so one may free up by the time the car arrives.
  busy,

  /// Out of service, not built yet, or the operator has lost contact with it.
  dead,
}

class StationCheck {
  const StationCheck(this.state, {this.note, this.freeGuns, this.totalGuns, this.kw, this.healthNote});
  final StationState state;
  final String? note;

  /// CCS2 DC guns only.
  final int? freeGuns;
  final int? totalGuns;

  /// Per gun, when the source reports it.
  final double? kw;

  /// Reassurance for the driver, like when the charger was last used.
  final String? healthNote;
}

/// Live status lookups. The sync call is for filtering many chargers, and the
/// async one for confirming the few that may actually be suggested.
abstract class LiveStatusSource {
  LiveStatus statusOf(Charger charger);

  /// Whether [check] could say anything about this charger.
  bool canCheck(Charger charger) => statusOf(charger) != LiveStatus.unknown;

  /// Null when the charger isn't in the feed or the check fails.
  Future<StationCheck?> check(Charger charger);
}

class LiveStation {
  const LiveStation({
    required this.id,
    required this.name,
    required this.position,
    required this.available,
    this.address = '',
  });
  final String id;
  final String name;
  final String address;
  final GeoPoint position;
  final bool available;
}

/// Finds the live-feed station for a charger from our list.
///
/// Location alone isn't safe, because different sites can be 60 m apart. Name
/// alone isn't either, because the feed and our list often word names differently.
///
/// A station is matched at most once. Two chargers with their own ids in one source
/// are two real chargers, even at one address, so they mustn't share one record.
class StationMatcher {
  StationMatcher(List<LiveStation> stations) {
    for (final station in stations) {
      _cells.putIfAbsent(_cell(station.position.lat, station.position.lng), () => []).add(station);
    }
  }

  /// Practically the same coordinates: the same site, whatever it's called.
  static const _sameSpotKm = 0.003;

  /// Close by with a similar name. Listed coordinates are often a little off.
  static const _nearbyKm = 0.3;
  static const _minNearbySimilarity = 0.5;

  static const _cellDegrees = 0.01;
  static const _ignoredWords = {
    'by', 'the', 'and', 'ev', 'charging', 'station', 'charger', 'chargers', 'hub', 'adhoc',
    'coco', 'cs', 'pvt', 'ltd', 'filling', 'petrol', 'pump', 'service', 'fuel', 'fuels',
    'point', 'of', 'at', 'in',
  };

  final Map<int, List<LiveStation>> _cells = {};
  final Map<String, LiveStation?> _matched = {};
  final Set<String> _claimed = {};

  int _cell(double lat, double lng) =>
      (lat / _cellDegrees).floor() * 100000 + (lng / _cellDegrees).floor();

  LiveStation? match(Charger charger) =>
      _matched.putIfAbsent(charger.id, () => _find(charger));

  LiveStation? _find(Charger charger) {
    final row = (charger.position.lat / _cellDegrees).floor();
    final col = (charger.position.lng / _cellDegrees).floor();
    final nearby = <(double, LiveStation)>[];
    for (var r = row - 1; r <= row + 1; r++) {
      for (var c = col - 1; c <= col + 1; c++) {
        for (final station in _cells[r * 100000 + c] ?? const <LiveStation>[]) {
          final km = distanceKm(charger.position, station.position);
          if (km <= _nearbyKm) nearby.add((km, station));
        }
      }
    }
    nearby.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (km, station) in nearby) {
      if (_claimed.contains(station.id)) continue;
      if (km <= _sameSpotKm || nameSimilarity(charger.name, station.name) >= _minNearbySimilarity) {
        _claimed.add(station.id);
        return station;
      }
    }
    return null;
  }

  /// Share of meaningful words two names have in common, from 0 to 1.
  static double nameSimilarity(String a, String b) {
    final wordsA = _words(a), wordsB = _words(b);
    if (wordsA.isEmpty || wordsB.isEmpty) return 0;
    return 2 * wordsA.intersection(wordsB).length / (wordsA.length + wordsB.length);
  }

  static Set<String> _words(String name) => name
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 1 && !_ignoredWords.contains(w))
      .toSet();
}
