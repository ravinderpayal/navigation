import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/charger.dart';

class ChargerRepository {
  static List<Charger>? _cache;

  static Future<List<Charger>> load() async {
    final cached = _cache;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString('assets/free_chargers.json');
    final parsed = await compute(_parse, raw);
    _cache = parsed;
    return parsed;
  }

  static List<Charger> _parse(String raw) => (jsonDecode(raw) as List)
      .map((e) => Charger.fromJson(e as Map<String, dynamic>))
      .toList();
}
