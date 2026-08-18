import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/bots/bot.dart';
import 'package:callbreak/engine/card.dart';
import 'package:callbreak/engine/game.dart';
import 'package:callbreak/engine/rules.dart';

/// Drives [game] end to end with four bots, synchronously (no timers), and
/// returns the trick-by-trick log so callers can assert on it.
List<CompletedTrick> _playFullGame(CallBreakGame game, List<BotBrain> brains) {
  game.start();
  final tricks = <CompletedTrick>[];

  while (game.phase != GamePhase.gameOver) {
    switch (game.phase) {
      case GamePhase.bidding:
        final seat = game.turn!;
        final bid = brains[seat].chooseBid(game.handOf(seat));
        final accepted = game.placeBid(seat, bid);
        expect(accepted, isTrue, reason: 'bot bid should always be accepted');

      case GamePhase.playing:
        final seat = game.turn!;
        final hand = game.handOf(seat);
        final legal = game.legalMovesFor(seat);
        expect(legal, isNotEmpty, reason: 'a seat on the clock must have a legal move');

        final card = brains[seat].chooseCard(
          hand: hand,
          trick: game.trick,
          played: game.playedThisHand,
          bid: game.bids[seat]!,
          tricksWon: game.tricksWon[seat],
        );
        expect(legal, contains(card), reason: 'bot must only offer a legal card');

        final accepted = game.playCard(seat, card);
        expect(accepted, isTrue);

        if (game.awaitingTrickClear) {
          tricks.add(game.lastTrick!);
          game.clearTrick();
        }

      case GamePhase.handOver:
        game.nextHand();

      case GamePhase.lobby:
      case GamePhase.gameOver:
        break;
    }
  }

  return tricks;
}

List<PlayerInfo> _botTable() => [
  for (var seat = 0; seat < 4; seat++)
    PlayerInfo(seat: seat, name: 'Bot $seat', kind: PlayerKind.bot),
];

void main() {
  group('rules invariants over many simulated games', () {
    for (var seed = 0; seed < 40; seed++) {
      test('seed $seed plays a legal, complete game', () {
        final random = Random(seed);
        final players = _botTable();
        final brains = [
          for (var i = 0; i < players.length; i++)
            BotBrain(difficulty: BotDifficulty.values[seed % 3], random: random),
        ];
        final game = CallBreakGame(players: players, seed: seed);
        final tricks = _playFullGame(game, brains);

        expect(
          tricks.length,
          handsPerGame * tricksPerHand,
          reason: '5 hands of 13 tricks each',
        );

        for (final trick in tricks) {
          expect(trick.plays.length, 4, reason: 'every trick has exactly 4 plays');
          final seats = trick.plays.map((p) => p.seat).toSet();
          expect(seats.length, 4, reason: 'each seat plays exactly once per trick');
          expect(trick.winner, trickWinner(trick.plays));
        }

        // Every trick's 4 cards are distinct, and across a whole hand (13
        // tricks) all 52 cards appear exactly once.
        for (var hand = 0; hand < handsPerGame; hand++) {
          final handTricks = tricks.sublist(
            hand * tricksPerHand,
            (hand + 1) * tricksPerHand,
          );
          final cardsThisHand = handTricks
              .expand((t) => t.plays.map((p) => p.card))
              .toList();
          expect(
            cardsThisHand.toSet().length,
            52,
            reason: 'no card repeats within a hand',
          );
          expect(cardsThisHand.length, 52);
        }

        // Bids stay in range, and each seat's tricks-won across a hand sum to 13.
        for (var hand = 0; hand < handsPerGame; hand++) {
          final handTricks = tricks.sublist(
            hand * tricksPerHand,
            (hand + 1) * tricksPerHand,
          );
          final wonBySeat = List.filled(4, 0);
          for (final trick in handTricks) {
            wonBySeat[trick.winner]++;
          }
          expect(wonBySeat.reduce((a, b) => a + b), tricksPerHand);
        }

        expect(game.phase, GamePhase.gameOver);
        expect(game.roundScores.every((r) => r.length == handsPerGame), isTrue);
        for (var seat = 0; seat < 4; seat++) {
          final expectedTotal = game.roundScores[seat].fold(0.0, (a, b) => a + b);
          expect(game.totals[seat], closeTo(expectedTotal, 0.15));
        }
        expect(game.rankings.map((r) => r.seat).toSet(), {0, 1, 2, 3});
      });
    }
  });

  group('scoring', () {
    test('making the bid exactly scores the bid', () {
      expect(scoreHand(5, 5), 5.0);
    });

    test('overtricks add 0.1 each', () {
      expect(scoreHand(3, 6), closeTo(3.3, 1e-9));
    });

    test('falling short loses the bid outright, ignoring tricks actually won', () {
      expect(scoreHand(7, 3), -7.0);
      expect(scoreHand(7, 0), -7.0);
    });

    test('clampBid keeps bids in [1, 13]', () {
      expect(clampBid(0), 1);
      expect(clampBid(14), 13);
      expect(clampBid(7), 7);
    });
  });

  group('bid suggestion', () {
    test('a hand of small plain cards suggests the minimum bid', () {
      final hand = [
        for (var r = 2; r <= 6; r++) PlayingCard(r, Suit.hearts),
        for (var r = 2; r <= 7; r++) PlayingCard(r, Suit.clubs),
        const PlayingCard(2, Suit.diamonds),
        const PlayingCard(3, Suit.diamonds),
      ];
      expect(hand.length, 13);
      expect(estimateTricks(hand), 0);
      expect(suggestBid(hand), minBid);
    });

    test('a monster trump-heavy hand deserves a high bid', () {
      const hand = [
        PlayingCard(14, Suit.spades),
        PlayingCard(13, Suit.spades),
        PlayingCard(12, Suit.spades),
        PlayingCard(11, Suit.spades),
        PlayingCard(10, Suit.spades),
        PlayingCard(9, Suit.spades),
        PlayingCard(14, Suit.hearts),
        PlayingCard(13, Suit.hearts),
        PlayingCard(12, Suit.hearts),
        PlayingCard(14, Suit.clubs),
        PlayingCard(13, Suit.clubs),
        PlayingCard(12, Suit.clubs),
        PlayingCard(14, Suit.diamonds),
      ];
      expect(suggestBid(hand), greaterThanOrEqualTo(8));
      expect(suggestBid(hand), lessThanOrEqualTo(maxBid));
    });

    test('a lone king is only worth half a trick', () {
      final hand = [
        const PlayingCard(13, Suit.hearts), // Unprotected lone rock king.
        for (var r = 2; r <= 8; r++) PlayingCard(r, Suit.clubs),
        for (var r = 2; r <= 6; r++) PlayingCard(r, Suit.diamonds),
      ];
      expect(hand.length, 13);
      expect(estimateTricks(hand), lessThan(1.0));
    });

    test('hard bots bid exactly what suggestBid offers', () {
      final random = Random(7);
      final brain = BotBrain(difficulty: BotDifficulty.hard);
      for (var i = 0; i < 10; i++) {
        final hand = dealHands(random)[0];
        expect(
          brain.chooseBid(hand),
          suggestBid(hand),
          reason: 'hard bots add no noise, so their bid is the suggestion',
        );
      }
    });
  });

  group('legalMoves', () {
    test('leading is unrestricted', () {
      final hand = [
        const PlayingCard(14, Suit.hearts),
        const PlayingCard(2, Suit.clubs),
        const PlayingCard(10, Suit.spades),
      ];
      expect(legalMoves(hand, const []), hand);
    });

    test('must follow suit and head the trick when able', () {
      final hand = [
        const PlayingCard(5, Suit.hearts),
        const PlayingCard(11, Suit.hearts),
        const PlayingCard(2, Suit.clubs),
      ];
      final trick = [const TrickPlay(3, PlayingCard(9, Suit.hearts))];
      expect(legalMoves(hand, trick), [const PlayingCard(11, Suit.hearts)]);
    });

    test('unable to head, may follow suit low', () {
      final hand = [
        const PlayingCard(3, Suit.hearts),
        const PlayingCard(5, Suit.hearts),
        const PlayingCard(2, Suit.clubs),
      ];
      final trick = [const TrickPlay(3, PlayingCard(9, Suit.hearts))];
      final legal = legalMoves(hand, trick);
      expect(legal, unorderedEquals(hand.ofSuit(Suit.hearts)));
    });

    test('void in the led suit must trump if holding trumps', () {
      final hand = [
        const PlayingCard(3, Suit.spades),
        const PlayingCard(9, Suit.spades),
        const PlayingCard(2, Suit.clubs),
      ];
      final trick = [const TrickPlay(3, PlayingCard(9, Suit.hearts))];
      expect(legalMoves(hand, trick), unorderedEquals(hand.ofSuit(Suit.spades)));
    });

    test('must overtrump when the trick is already trumped, if able', () {
      final hand = [
        const PlayingCard(3, Suit.spades),
        const PlayingCard(9, Suit.spades),
        const PlayingCard(2, Suit.clubs),
      ];
      final trick = [
        const TrickPlay(2, PlayingCard(9, Suit.hearts)),
        const TrickPlay(3, PlayingCard(5, Suit.spades)),
      ];
      expect(legalMoves(hand, trick), [const PlayingCard(9, Suit.spades)]);
    });

    test('unable to overtrump or follow, any card is legal', () {
      final hand = [const PlayingCard(3, Suit.spades), const PlayingCard(2, Suit.clubs)];
      final trick = [
        const TrickPlay(2, PlayingCard(9, Suit.hearts)),
        const TrickPlay(3, PlayingCard(12, Suit.spades)),
      ];
      expect(legalMoves(hand, trick), unorderedEquals(hand));
    });
  });

  group('GameView redaction', () {
    test('a seat sees only its own cards; others are counts', () {
      final players = _botTable();
      final game = CallBreakGame(players: players, seed: 1)..start();

      final view = game.viewFor(0);
      expect(view.hand, game.handOf(0));
      expect(view.handCounts, [13, 13, 13, 13]);

      final spectator = game.viewFor(null);
      expect(spectator.hand, isEmpty);
      expect(spectator.legalMoveIds, isEmpty);
    });

    test('the host seat survives the round trip to another device', () {
      final players = _botTable();
      final game = CallBreakGame(players: players, seed: 1)..start();

      // The LAN host stamps hostSeat (0) on every view it sends.
      final wire = game.viewFor(0, hostSeat: 0).toJson();
      final decoded = GameView.fromJson(wire);

      expect(decoded.hostSeat, 0);

      // A hostless table — quickplay, or the offline mode — sends none.
      final hostless = GameView.fromJson(game.viewFor(0).toJson());
      expect(hostless.hostSeat, isNull);
    });
  });
}
