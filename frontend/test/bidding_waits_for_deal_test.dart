import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/design/motion.dart';
import 'package:callbreak/engine/game.dart';
import 'package:callbreak/net/lan_host_session.dart';
import 'package:callbreak/net/local_session.dart';

/// Bidding must not start while the cards are still being dealt on screen.
/// In both tables below the dealer is seat 0, so seat 1 — a bot — bids first;
/// left to its normal think time it would bid well inside the deal animation.
void main() {
  bool anyBid(GameView view) => view.bids.any((b) => b != null);

  test('the deal animation fits inside the window before bidding opens', () {
    expect(
      TablePacing.dealGrace,
      greaterThanOrEqualTo(const Duration(milliseconds: Motion.dealTotalMs)),
    );
  });

  test('a solo table holds the bots\' bids until the deal is down', () {
    fakeAsync((async) {
      final session = LocalSession(playerName: 'You', seed: 7, handsPerGame: 3);
      addTearDown(session.dispose);
      expect(session.view!.phase, GamePhase.bidding);
      expect(session.view!.turn, 1, reason: 'a bot is first to bid');

      async.elapse(TablePacing.dealGrace - const Duration(milliseconds: 100));
      expect(anyBid(session.view!), isFalse, reason: 'nobody bids mid-deal');

      // Bidding opens, and the first bot bids after its usual think time.
      async.elapse(const Duration(milliseconds: 100) + TablePacing.botThinkMin + TablePacing.botThinkExtra);
      expect(session.view!.bids[1], isNotNull);
    });
  });

  test('a restarted solo game waits for its own deal too', () {
    fakeAsync((async) {
      final session = LocalSession(playerName: 'You', seed: 7, handsPerGame: 3);
      addTearDown(session.dispose);
      async.elapse(TablePacing.dealGrace + const Duration(seconds: 2));
      expect(anyBid(session.view!), isTrue);

      session.restart();
      async.elapse(TablePacing.dealGrace - const Duration(milliseconds: 100));
      expect(anyBid(session.view!), isFalse, reason: 'a fresh deal, a fresh wait');
    });
  });

  test('a LAN host holds the bots\' bids until the deal is down', () {
    fakeAsync((async) {
      final session = LanHostSession(playerName: 'You', roomCode: 'TEST')..startGame();
      addTearDown(session.dispose);
      expect(session.view!.phase, GamePhase.bidding);
      expect(session.view!.turn, 1, reason: 'a bot is first to bid');

      async.elapse(TablePacing.dealGrace - const Duration(milliseconds: 100));
      expect(anyBid(session.view!), isFalse, reason: 'nobody bids mid-deal');

      async.elapse(const Duration(milliseconds: 100) + TablePacing.botThinkMin + TablePacing.botThinkExtra);
      expect(session.view!.bids[1], isNotNull);
    });
  });
}
