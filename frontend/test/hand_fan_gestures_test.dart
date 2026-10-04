import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/engine/card.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/ui/widgets/hand_fan.dart';
import 'package:callbreak/ui/widgets/playing_card_view.dart';

const _hand = [
  PlayingCard(14, Suit.spades),
  PlayingCard(9, Suit.hearts),
  PlayingCard(5, Suit.hearts),
  PlayingCard(12, Suit.clubs),
  PlayingCard(3, Suit.clubs),
];

class _Log {
  final played = <PlayingCard>[];
  final refused = <PlayingCard>[];
  var waited = 0;
}

Future<_Log> _pumpFan(
  WidgetTester tester, {
  Set<String>? legal,
  bool interactive = true,
  Set<String> hidden = const {},
  AppSettings? settings,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  final log = _Log();
  await tester.pumpWidget(
    SettingsScope(
      settings: settings ?? AppSettings(),
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: HandFan(
              cards: _hand,
              legalIds: legal ?? {for (final c in _hand) c.id},
              interactive: interactive,
              hiddenIds: hidden,
              cardWidth: 60,
              onPlay: (card, _) => log.played.add(card),
              onIllegal: log.refused.add,
              onNotYourTurn: () => log.waited++,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return log;
}

/// A point on [card]'s visible strip (its left edge, which the next card in
/// the fan does not cover).
Offset _strip(WidgetTester tester, PlayingCard card) {
  final rect = tester.getRect(
    find.byWidgetPredicate((w) => w is PlayingCardView && w.card == card),
  );
  return Offset(rect.left + 8, rect.center.dy);
}

void main() {
  testWidgets('a tap plays a legal card', (tester) async {
    final log = await _pumpFan(tester);
    await tester.tapAt(_strip(tester, _hand[1]));
    await tester.pump(const Duration(milliseconds: 300));
    expect(log.played, [_hand[1]]);
  });

  testWidgets('an illegal card is refused, not played', (tester) async {
    final log = await _pumpFan(tester, legal: {_hand[1].id, _hand[2].id});
    await tester.tapAt(_strip(tester, _hand[3]));
    await tester.pump(const Duration(milliseconds: 500));
    expect(log.played, isEmpty);
    expect(log.refused, [_hand[3]]);
  });

  testWidgets('sliding across the fan previews but never plays', (tester) async {
    final log = await _pumpFan(tester);
    final gesture = await tester.startGesture(_strip(tester, _hand[0]));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(14, 0));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(log.played, isEmpty);
  });

  testWidgets('dragging a card up past the threshold throws it', (tester) async {
    final log = await _pumpFan(tester);
    final gesture = await tester.startGesture(_strip(tester, _hand[2]));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(log.played, [_hand[2]], reason: 'thrown as soon as it crosses the line');
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(log.played, [_hand[2]], reason: 'lifting the finger does not throw twice');
  });

  testWidgets('a short, slow drag springs back without playing', (tester) async {
    final log = await _pumpFan(tester);
    final gesture = await tester.startGesture(_strip(tester, _hand[2]));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveBy(const Offset(0, -12));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.moveBy(const Offset(0, -6));
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(log.played, isEmpty);
  });

  testWidgets('off turn, cards preview but a throw only says to wait', (tester) async {
    final log = await _pumpFan(tester, interactive: false);
    await tester.tapAt(_strip(tester, _hand[1]));
    await tester.pump(const Duration(milliseconds: 300));
    expect(log.played, isEmpty);

    final gesture = await tester.startGesture(_strip(tester, _hand[1]));
    await tester.pump(const Duration(milliseconds: 50));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, -14));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(log.played, isEmpty);
    expect(log.waited, 1);
  });

  testWidgets('tap twice to play raises first, then plays', (tester) async {
    final log = await _pumpFan(tester, settings: AppSettings()..tapTwiceToPlay = true);
    await tester.tapAt(_strip(tester, _hand[1]));
    await tester.pump(const Duration(milliseconds: 300));
    expect(log.played, isEmpty, reason: 'the first tap only raises the card');

    await tester.tapAt(_strip(tester, _hand[1]));
    await tester.pump(const Duration(milliseconds: 300));
    expect(log.played, [_hand[1]]);
  });

  testWidgets('a thrown card awaiting confirmation leaves the fan', (tester) async {
    await _pumpFan(tester, hidden: {_hand[3].id});
    expect(
      find.byWidgetPredicate((w) => w is PlayingCardView && w.card == _hand[3]),
      findsNothing,
    );
    expect(find.byType(PlayingCardView), findsNWidgets(_hand.length - 1));
  });
}
