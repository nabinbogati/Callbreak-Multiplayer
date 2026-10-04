import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/engine/card.dart';
import 'package:callbreak/engine/game.dart';
import 'package:callbreak/net/lan_host_session.dart';
import 'package:callbreak/net/local_session.dart';

/// A LAN table with the host in seat 0 and bots in the rest, started without
/// binding a socket — none of what these tests are about goes over the wire.
LanHostSession _table() =>
    LanHostSession(playerName: 'You', roomCode: 'TEST')..startGame();

/// Winds the table on until the host's seat is on autoplay. How long that
/// takes is not fixed — the bid clock runs out first (which only settles the
/// bid), and only then does the host's play clock have to elapse to hand the
/// seat over — so this steps rather than guessing a total.
void _untilAutoplay(FakeAsync async, LanHostSession session) {
  for (var i = 0; i < 600; i++) {
    if (session.view!.players[LanHostSession.hostSeat].autoplay) return;
    async.elapse(const Duration(milliseconds: 500));
  }
  fail('the seat never went to autoplay');
}

/// Winds the table on until the scoreboard is up. How long a hand takes is not
/// fixed — the bots' think delays are deliberately a little random — so this
/// steps rather than guessing a total.
void _untilHandOver(FakeAsync async, LanHostSession session) {
  for (var i = 0; i < 600; i++) {
    if (session.view!.phase == GamePhase.handOver) return;
    async.elapse(const Duration(milliseconds: 500));
  }
  fail('the hand never finished');
}

/// Plays a whole hand for the host — bidding and playing each turn as it comes
/// — so the host never falls to autoplay. Needed to reach the hand where the
/// host is the *first* bidder, because an autopiloted seat is server-driven and
/// gets no deadline to observe.
void _hostPlaysHand(FakeAsync async, LanHostSession session) {
  for (var i = 0; i < 600; i++) {
    final view = session.view!;
    if (view.phase == GamePhase.handOver) return;
    if (view.isMyTurn) {
      if (view.phase == GamePhase.bidding) {
        session.placeBid(3);
      } else if (view.phase == GamePhase.playing &&
          view.legalMoveIds.isNotEmpty) {
        session.play(PlayingCard.fromId(view.legalMoveIds.first));
      }
    }
    async.elapse(const Duration(milliseconds: 250));
  }
  fail('the hand never finished with the host playing');
}

/// Long enough for the three bots to bid ahead of the host: bidding opens
/// once the deal animation is over, then each bot takes at most its full
/// think time.
final _botsBidFirst =
    TablePacing.dealGrace +
    (TablePacing.botThinkMin + TablePacing.botThinkExtra) * 3;

void main() {
  test('the host cannot start a LAN table with no guests', () {
    final session = LanHostSession(playerName: 'You', roomCode: 'TEST');
    addTearDown(session.dispose);

    expect(
      session.canStart,
      isFalse,
      reason: 'starting with nobody else there is what the offline mode is for',
    );
  });

  test('every view names the LAN host', () {
    final session = _table();
    addTearDown(session.dispose);

    expect(session.view!.hostSeat, LanHostSession.hostSeat);
  });

  test('a host who never bids does not hold the table up', () {
    fakeAsync((async) {
      final session = _table();
      addTearDown(session.dispose);

      // The engine deals to seat 1, so the three bots bid first and the host
      // is left as the only seat the hand is waiting on.
      async.elapse(_botsBidFirst);
      expect(session.view!.phase, GamePhase.bidding);
      expect(session.view!.turn, LanHostSession.hostSeat);
      expect(
        session.turnDeadline,
        isNotNull,
        reason: 'the seat on the clock is counted down, not left open-ended',
      );

      // Let the bid clock run out. The table settles the bid and deals on —
      // but bidding and play run independent clocks, so missing the bid does
      // not hand the seat to a bot.
      async.elapse(TablePacing.bidTimeout + const Duration(seconds: 1));

      expect(
        session.view!.phase,
        GamePhase.playing,
        reason: 'the table bid for the seat that went quiet and dealt on',
      );
      expect(session.view!.bids[LanHostSession.hostSeat], isNotNull);
      expect(
        session.view!.players[LanHostSession.hostSeat].autoplay,
        isFalse,
        reason: 'a missed bid settles the bid; it does not hand the seat over',
      );
    });
  });

  test('bidding in time keeps the seat', () {
    fakeAsync((async) {
      final session = _table();
      addTearDown(session.dispose);

      async.elapse(_botsBidFirst);
      expect(session.view!.turn, LanHostSession.hostSeat);
      session.placeBid(3);

      // Long enough that the timeout would have fired had the bid not landed,
      // but short of the play clock that starts once the hand is under way.
      async.elapse(const Duration(seconds: 5));

      expect(session.view!.phase, GamePhase.playing);
      expect(session.view!.bids[LanHostSession.hostSeat], 3);
      expect(session.view!.players[LanHostSession.hostSeat].autoplay, isFalse);
    });
  });

  test('a tap takes the seat back off autoplay', () {
    fakeAsync((async) {
      final session = _table();
      addTearDown(session.dispose);

      // The bid clock only settles the bid; autoplay comes from the play
      // clock, so wind past both before expecting the handover.
      _untilAutoplay(async, session);
      expect(session.view!.players[LanHostSession.hostSeat].autoplay, isTrue);

      session.wakeUp();
      expect(session.view!.players[LanHostSession.hostSeat].autoplay, isFalse);
    });
  });

  test('the scoreboard deals the next hand when nobody dismisses it', () {
    fakeAsync((async) {
      final session = _table();
      addTearDown(session.dispose);

      // The host never acts: the bid clock settles their bid, then the play
      // clock hands the seat to autoplay, so the whole hand plays itself out.
      _untilHandOver(async, session);
      expect(
        session.handAdvanceDeadline,
        isNotNull,
        reason: 'the wait is capped, and says so',
      );

      // Nobody taps "next hand".
      async.elapse(TablePacing.handAdvanceWait + const Duration(seconds: 1));
      expect(session.view!.handIndex, 1);
      expect(session.view!.phase, GamePhase.bidding);
      expect(session.handAdvanceDeadline, isNull);
    });
  });

  test('the scoreboard clock is not pushed back by a republish', () {
    fakeAsync((async) {
      final session = _table();
      addTearDown(session.dispose);

      _untilHandOver(async, session);
      final due = session.handAdvanceDeadline!;

      // A guest tapping the felt republishes the table. That is a sign of life,
      // not a reason to make everybody else wait longer.
      async.elapse(const Duration(seconds: 2));
      session.wakeUp();
      expect(session.handAdvanceDeadline, due);
    });
  });

  test('the first bidder of a hand gets the deal grace on top of the bid clock', () {
    fakeAsync((async) {
      final session = _table();
      addTearDown(session.dispose);

      // Keep the host awake through the first three hands so autoplay is never
      // switched on. In the fourth hand the dealer is seat 3, which makes the
      // host the very first bidder — the seat whose clock would otherwise be
      // counting down while the dealing animation still runs.
      for (var hand = 0; hand < 3; hand++) {
        _hostPlaysHand(async, session);
        expect(session.view!.phase, GamePhase.handOver);
        session.continueToNextHand();
        async.elapse(const Duration(milliseconds: 50));
      }

      expect(session.view!.handIndex, 3);
      expect(session.view!.phase, GamePhase.bidding);
      expect(session.view!.turn, LanHostSession.hostSeat);

      final remaining = session.turnDeadline!.difference(
        async.getClock(DateTime(2000)).now(),
      );
      expect(
        remaining,
        greaterThan(
          TablePacing.bidTimeout + const Duration(seconds: 1),
        ),
        reason: 'the deal grace sits on top of the plain bid clock',
      );

      // A plain bid clock would have forced the bid by now; the graced one
      // has not run out yet.
      async.elapse(TablePacing.bidTimeout);
      expect(session.view!.bids[LanHostSession.hostSeat], isNull);
    });
  });
}
