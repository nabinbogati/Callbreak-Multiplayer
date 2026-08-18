import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/main.dart';

void main() {
  testWidgets('home screen shows the wordmark and all four play modes', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const CallBreakApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('CALL BREAK'), findsOneWidget);
    expect(find.text('Private'), findsOneWidget);
    expect(find.text('vs Bots'), findsOneWidget);
    expect(find.text('vs Humans'), findsOneWidget);
    expect(find.text('LAN'), findsOneWidget);
  });

  testWidgets('starting a bots table deals a hand and eventually asks for a bid', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const CallBreakApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('vs Bots'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The bots sheet asks for a match length; the default quickplay deals.
    await tester.tap(find.text('Start game'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Round 1 / 3'), findsOneWidget);

    // Let the bots ahead of the human in bidding order take their turns.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }

    expect(find.text('Confirm bid'), findsOneWidget);
  });
}
