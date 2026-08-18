import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/engine/card.dart';
import 'package:callbreak/engine/game.dart';
import 'package:callbreak/net/lan_host_session.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/ui/screens/table_screen.dart';
import 'package:callbreak/ui/widgets/playing_card_view.dart';

/// Drives the LAN host (the real LAN UI class, no sockets — startGame without
/// guests fills bots) through an entire game and a restart, watching for the
/// dealing flourish on every deal.
void main() {
  testWidgets('LAN host: dealing flourish replays on every hand and the second game', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final settings = AppSettings()..animationSpeed = AnimationSpeed.fast;
    final session = LanHostSession(
      playerName: 'You',
      roomCode: 'TEST',
      handsPerGame: 3,
      animationSpeed: AnimationSpeed.fast,
    )..startGame();

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
      await tester.pump(const Duration(seconds: 6));
    }

    Future<void> playOutHand() async {
      var guard = 0;
      while (guard++ < 400) {
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
          } else if (view.phase == GamePhase.playing &&
              view.legalMoveIds.isNotEmpty) {
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
        reason: 'LAN game 1 hand 1 should be dealing');
    await waitDeal();
    // The deal's own cards are gone, leaving only the three opponents' face-
    // down hand fans (13 cards each).
    expect(find.byType(CardBackView), findsNWidgets(39),
        reason: 'LAN game 1 hand 1 deal should have finished');

    for (var hand = 0; hand < 3; hand++) {
      await playOutHand();
      if (hand < 2) {
        session.continueToNextHand();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.byType(CardBackView), findsWidgets,
            reason: 'LAN game 1 hand ${hand + 2} should be dealing');
        await waitDeal();
      }
    }

    expect(session.view!.phase, GamePhase.gameOver);

    // ---- game 2 (same session, restart) ----------------------------------
    session.restart();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));

    expect(find.byType(CardBackView), findsWidgets,
        reason: 'LAN game 2 hand 1 should be dealing');
    await waitDeal();
  });
}