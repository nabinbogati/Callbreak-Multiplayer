import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/main.dart';
import 'package:callbreak/ui/widgets/felt_table.dart';
import 'package:callbreak/ui/widgets/seat_view.dart';

void main() {
  Future<void> startBots(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const CallBreakApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('vs Bots'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Start game'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  Rect rr(WidgetTester tester, Finder f) {
    final box = tester.renderObject<RenderBox>(f.first);
    return box.localToGlobal(Offset.zero) & box.size;
  }

  testWidgets('landscape game geometry', (tester) async {
    await startBots(tester, const Size(844, 390));

    final felt = rr(tester, find.byType(FeltSurface));
    debugPrint('felt rect=$felt screen=844x390');

    final seats = find.byType(SeatView);
    final n = seats.evaluate().length;
    for (var i = 0; i < n; i++) {
      final r = rr(tester, seats.at(i));
      debugPrint('seat $i rect=$r');
    }
  });
}
