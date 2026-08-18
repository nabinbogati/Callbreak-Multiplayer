import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/engine/card.dart';
import 'package:callbreak/engine/game.dart';
import 'package:callbreak/net/local_session.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/ui/screens/table_screen.dart';
import 'package:callbreak/ui/widgets/playing_card_view.dart';

/// Drives a real [LocalSession] through an entire game — bidding, playing
/// every hand, clearing tricks — then restarts and plays the next game, so the
/// table's dealing-flourish lifecycle can be observed across games.
///
/// Beyond the flourish firing at all, it asserts that the player's own deal
/// is visible: flight cards must land near the bottom of the screen (the
/// player's hand area), exactly like the three opponents' flights land at
/// their seats. Previously the bottom seat was skipped, so the player never
/// saw their own cards being dealt.
void main() {
  testWidgets('dealing flourish replays on the second game and is visible '
      'to the local player', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final settings = AppSettings()..animationSpeed = AnimationSpeed.fast;
    final session = LocalSession(
      playerName: 'You',
      handsPerGame: 3,
      seed: 7,
      animationSpeed: AnimationSpeed.fast,
    );

    await tester.pumpWidget(
      SettingsScope(
        settings: settings,
        child: MaterialApp(home: TableScreen(session: session)),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    Future<void> waitDeal() async {
      // Let the flourish's 52-card stagger + tail fade complete.
      await tester.pump(const Duration(seconds: 6));
    }

    // At least one face-down deal card must be in the bottom band of the
    // screen — the local player's hand area — where the self flight lands.
    // Opponents' flights land at the top/left/right seats, so before the fix
    // (which skipped the bottom seat entirely) this found nothing.
    void expectSelfDealFlight() {
      final w = tester.view.physicalSize.width;
      final h = tester.view.physicalSize.height;
      final nearBottom = <Offset>[];
      for (final element in find.byType(CardBackView).evaluate()) {
        final center = tester.getCenter(find.byWidget(element.widget));
        if (center.dy > h * 0.58 &&
            center.dx > w * 0.25 &&
            center.dx < w * 0.75) {
          nearBottom.add(center);
        }
      }
      expect(nearBottom, isNotEmpty,
          reason: 'the player\'s own deal flight should be visible near the '
              'bottom of the screen (found ${nearBottom.length} cards)');
    }

    Future<void> playOutHand() async {
      var guard = 0;
      while (guard++ < 200) {
        final view = session.view!;
        if (view.phase == GamePhase.handOver || view.phase == GamePhase.gameOver) {
          return;
        }
        if (view.awaitingTrickClear) {
          await tester.pump(const Duration(seconds: 2));
          continue;
        }
        if (view.isMyTurn) {
          if (view.phase == GamePhase.bidding) {
            session.placeBid(3);
          } else if (view.phase == GamePhase.playing && view.legalMoveIds.isNotEmpty) {
            session.play(PlayingCard.fromId(view.legalMoveIds.first));
          }
        }
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
      }
      fail('hand never played out');
    }

    // ---- game 1 -----------------------------------------------------------
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byType(CardBackView), findsWidgets,
        reason: 'game 1 hand 1 should be dealing');
    expectSelfDealFlight();
    await waitDeal();
    // The deal's own cards are gone, leaving only the three opponents' face-
    // down hand fans (13 cards each).
    expect(find.byType(CardBackView), findsNWidgets(39),
        reason: 'game 1 hand 1 deal should have finished');

    for (var hand = 0; hand < 3; hand++) {
      await playOutHand();
      if (hand < 2) {
        session.continueToNextHand();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.byType(CardBackView), findsWidgets,
            reason: 'game 1 hand ${hand + 2} should be dealing');
    expectSelfDealFlight();
    await waitDeal();
      }
    }

    // Game over screen.
    expect(session.view!.phase, GamePhase.gameOver);

    // ---- game 2 (same session, restart) ----------------------------------
    session.restart();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.byType(CardBackView), findsWidgets,
        reason: 'game 2 hand 1 should be dealing');
    expectSelfDealFlight();
    await waitDeal();
  });

  testWidgets('player deal flights spread across the hand fan, not the seat centre', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final session = LocalSession(
      playerName: 'You',
      handsPerGame: 3,
      seed: 7,
      animationSpeed: AnimationSpeed.fast,
    );

    await tester.pumpWidget(
      SettingsScope(
        settings: AppSettings()..animationSpeed = AnimationSpeed.fast,
        child: MaterialApp(home: TableScreen(session: session)),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final w = tester.view.physicalSize.width;
    final h = tester.view.physicalSize.height;
    final landedX = <double>[];

    // Watch the whole deal, sampling every 250 ms.  Landing fan slots run
    // left to right across the width, so each new cluster of near-bottom
    // cards lands farther right than the last.
    for (var step = 0; step < 10; step++) {
      await tester.pump(const Duration(milliseconds: 250));
      for (final e in find.byType(CardBackView).evaluate()) {
        final c = tester.getCenter(find.byWidget(e.widget));
        if (c.dy > h * 0.58 && c.dx > w * 0.1 && c.dx < w * 0.9) {
          landedX.add(c.dx);
        }
      }
    }

    final span = landedX.isNotEmpty
        ? landedX.reduce((a, b) => a > b ? a : b) -
            landedX.reduce((a, b) => a < b ? a : b)
        : 0.0;
    expect(
      span,
      greaterThan(w * 0.4),
      reason: 'the player\'s deal flights should spread across the hand fan '
          '(observed span ${span.toStringAsFixed(0)} px vs ${(w * 0.4).toStringAsFixed(0)} min)',
    );
  });
}