import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vinfast_copilot/core/charger_options.dart';
import 'package:vinfast_copilot/ui/charger_options_sheet.dart';

void main() {
  testWidgets('the food switch reloads the list without restaurants and is remembered', (tester) async {
    final loads = <bool>[];
    final remembered = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChargerOptionsSheet(
          wantFood: true,
          load: (wantFood) {
            loads.add(wantFood);
            return Stream.value(const ChargerOptions([], done: true));
          },
          onWantFoodChanged: remembered.add,
          onSelected: (_) {},
        ),
      ),
    ));
    await tester.pump();
    expect(loads, [true]);
    expect(find.text('Chargers near a highly rated restaurant rank higher'), findsOneWidget);

    await tester.tap(find.byKey(const Key('wantFoodSwitch')));
    await tester.pump();
    expect(loads, [true, false]);
    expect(remembered, [false]);
    expect(find.text('Restaurants are ignored'), findsOneWidget);
  });
}
