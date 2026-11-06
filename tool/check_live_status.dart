// ignore_for_file: avoid_print
// Checks the real status feed against the app's matching and parsing, and reports
// coverage. Run this if live status starts looking wrong:
//   dart run tool/check_live_status.dart
import 'dart:convert';
import 'dart:io';

import 'package:vinfast_copilot/core/charger.dart';
import 'package:vinfast_copilot/core/live_status.dart';
import 'package:vinfast_copilot/data/charger_status_service.dart';

Future<void> main() async {
  final raw = jsonDecode(File('assets/free_chargers.json').readAsStringSync()) as List;
  final chargers = raw.map((e) => Charger.fromJson(e as Map<String, dynamic>)).toList();
  final service = ChargerStatusService();
  await service.refresh();

  final counts = <LiveStatus, int>{};
  final inFeed = <Charger>[];
  for (final charger in chargers) {
    final status = service.statusOf(charger);
    counts[status] = (counts[status] ?? 0) + 1;
    if (status != LiveStatus.unknown && charger.dcKw >= 20) inFeed.add(charger);
  }
  print('${chargers.length} chargers: $counts');

  // A small sample only: this is someone else's server.
  for (final charger in inFeed.take(5)) {
    final check = await service.check(charger);
    print('${charger.name}: ${service.statusOf(charger).name} -> ${check?.state.name} (${check?.note})');
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  exit(0);
}
