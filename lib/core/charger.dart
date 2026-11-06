import 'dart:math' as math;

import 'geo.dart';

enum ChargerSource {
  /// From the VinFast free-charging list.
  free,

  /// Found through Google Places; assume it costs money.
  other,

  /// On Statiq's map but not the free list; assume it costs money.
  statiq,
}

class Charger {
  const Charger({
    required this.id,
    required this.name,
    required this.position,
    required this.dcKw,
    this.dcCount = 1,
    this.freeGuns,
    this.source = ChargerSource.free,
    this.address = '',
    this.availabilityNote,
  });

  factory Charger.fromJson(Map<String, dynamic> json) => Charger(
        id: json['id'] as String,
        name: json['name'] as String,
        position: GeoPoint((json['lat'] as num).toDouble(), (json['lng'] as num).toDouble()),
        dcKw: (json['dcKw'] as num).toDouble(),
        dcCount: math.max(1, (json['dcCount'] as num? ?? 1).toInt()),
        address: json['address'] as String? ?? '',
      );

  final String id;
  final String name;
  final GeoPoint position;
  final double dcKw;

  /// How many fast-charging guns the source lists.
  final int dcCount;

  /// How many are free, when the source itself reports that.
  final int? freeGuns;
  final ChargerSource source;
  final String address;

  /// Live status text when a data source gives one, e.g. "2 of 4 free".
  final String? availabilityNote;

  bool get isFree => source == ChargerSource.free;

  Charger withAvailabilityNote(String? note, {double? dcKw}) => Charger(
        id: id,
        name: name,
        position: position,
        dcKw: dcKw ?? this.dcKw,
        dcCount: dcCount,
        freeGuns: freeGuns,
        source: source,
        address: address,
        availabilityNote: note,
      );
}
