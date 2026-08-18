import 'dart:math';

import '../engine/card.dart';
import '../engine/game.dart';
import '../engine/rules.dart';

/// Heuristic Call Break opponent.
///
/// Two jobs: guess how many tricks a hand is worth at bidding time, and pick a
/// card during play. Both run off the same idea — count the tricks you actually
/// control (top cards, long trumps, ruffing chances) and then play to hit that
/// number, since undershooting your bid costs you the whole thing while an
/// overtrick is only worth 0.1.
class BotBrain {
  BotBrain({this.difficulty = BotDifficulty.normal, Random? random})
    : _random = random ?? Random();

  final BotDifficulty difficulty;
  final Random _random;

  double get _noise => switch (difficulty) {
    BotDifficulty.easy => 1.4,
    BotDifficulty.normal => 0.5,
    BotDifficulty.hard => 0.0,
  };

  double get _blunderRate => switch (difficulty) {
    BotDifficulty.easy => 0.25,
    BotDifficulty.normal => 0.06,
    BotDifficulty.hard => 0.0,
  };

  // ---------------------------------------------------------------- bidding

  int chooseBid(List<PlayingCard> hand) {
    final estimate = estimateTricks(hand);
    final jitter = _noise == 0 ? 0.0 : (_random.nextDouble() * 2 - 1) * _noise;
    return clampBid((estimate + jitter).round());
  }

  // ------------------------------------------------------------------- play

  /// Picks a card to play. [played] is every face-up card this hand, including
  /// the ones already in [trick].
  PlayingCard chooseCard({
    required List<PlayingCard> hand,
    required List<TrickPlay> trick,
    required List<PlayingCard> played,
    required int bid,
    required int tricksWon,
  }) {
    final legal = legalMoves(hand, trick);
    if (legal.length == 1) return legal.first;
    if (_blunderRate > 0 && _random.nextDouble() < _blunderRate) {
      return legal[_random.nextInt(legal.length)];
    }

    final unseen = _unseenCards(hand: hand, played: played);
    final need = bid - tricksWon;
    final tricksLeft = hand.length;

    return trick.isEmpty
        ? _chooseLead(legal, hand, unseen, need, tricksLeft)
        : _chooseFollow(legal, trick, unseen, need, tricksLeft);
  }

  PlayingCard _chooseLead(
    List<PlayingCard> legal,
    List<PlayingCard> hand,
    List<PlayingCard> unseen,
    int need,
    int tricksLeft,
  ) {
    // A side-suit master is a trick nobody can take from you — always worth it,
    // since even a bid you have already made earns 0.1 for the overtrick.
    final sideMasters = legal.where((c) => !c.isTrump && _isMaster(c, unseen)).toList();
    if (sideMasters.isNotEmpty) return _bestMasterToLead(sideMasters, hand);

    final trumps = legal.where((c) => c.isTrump).toList();

    if (need > 0) {
      // Needing every remaining trick means there is nothing left to protect.
      if (need >= tricksLeft && trumps.isNotEmpty) return trumps.highest;

      final trumpMasters = trumps.where((c) => _isMaster(c, unseen)).toList();
      if (trumpMasters.isNotEmpty) return trumpMasters.lowest;

      // Long trumps: draw the opponents' out so the small ones become good.
      if (trumps.length >= 5) return trumps.highest;
    }

    return _safeDiscard(legal, hand);
  }

  PlayingCard _chooseFollow(
    List<PlayingCard> legal,
    List<TrickPlay> trick,
    List<PlayingCard> unseen,
    int need,
    int tricksLeft,
  ) {
    final winners = legal.where((c) => wouldWin(trick, c)).toList();
    if (winners.isEmpty) return _safeDiscard(legal, legal);

    final cheapestWinner = _cheapest(winners);
    final losers = legal.where((c) => !wouldWin(trick, c)).toList();
    final isLast = trick.length == 3;

    if (need > 0) return cheapestWinner;

    // Bid already covered: take the trick only when it costs nothing. Playing
    // last is certain, and a master wins without spending a trump.
    if (losers.isEmpty) return cheapestWinner;
    if (isLast && !cheapestWinner.isTrump) return cheapestWinner;
    if (!cheapestWinner.isTrump && _isMaster(cheapestWinner, unseen)) {
      return cheapestWinner;
    }
    return _safeDiscard(losers, losers);
  }

  // ------------------------------------------------------------------ theory

  /// Cards that are neither in [hand] nor already face up — i.e. what the other
  /// three seats might still be holding.
  List<PlayingCard> _unseenCards({
    required List<PlayingCard> hand,
    required List<PlayingCard> played,
  }) {
    final known = {...hand, ...played};
    return fullDeck().where((c) => !known.contains(c)).toList();
  }

  /// No opponent can still hold a higher card of this suit.
  bool _isMaster(PlayingCard card, List<PlayingCard> unseen) =>
      !unseen.any((c) => c.suit == card.suit && c.rank > card.rank);

  /// Among masters, cash the one from the longest suit first — the extra cards
  /// behind it are the ones that might grow into tricks later.
  PlayingCard _bestMasterToLead(List<PlayingCard> masters, List<PlayingCard> hand) {
    masters.sort((a, b) {
      final byLength = hand.ofSuit(b.suit).length.compareTo(hand.ofSuit(a.suit).length);
      return byLength != 0 ? byLength : b.rank.compareTo(a.rank);
    });
    return masters.first;
  }

  /// Cheapest way to win: spend a side card before a trump, and a low one
  /// before a high one.
  PlayingCard _cheapest(List<PlayingCard> cards) {
    final sorted = [...cards]..sort((a, b) => _cost(a).compareTo(_cost(b)));
    return sorted.first;
  }

  int _cost(PlayingCard card) => (card.isTrump ? 100 : 0) + card.rank;

  /// Throw the least useful card: never a trump if there is a choice, lowest
  /// rank first, and from a shorter suit when it is a coin toss — going void
  /// there is what buys a ruff later.
  PlayingCard _safeDiscard(List<PlayingCard> options, List<PlayingCard> hand) {
    final sorted = [...options]
      ..sort((a, b) {
        final byCost = _cost(a).compareTo(_cost(b));
        if (byCost != 0) return byCost;
        return hand.ofSuit(a.suit).length.compareTo(hand.ofSuit(b.suit).length);
      });
    return sorted.first;
  }
}
