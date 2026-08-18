import 'dart:math';

import 'card.dart';

/// Call Break rules: which cards may be played, who takes the trick, and what a
/// hand is worth.
const int handsPerGame = 5;
const int tricksPerHand = 13;
const int minBid = 1;
const int maxBid = 13;

/// Expected trick count for [hand], in fractional tricks.
///
/// Honours are discounted when they lack the length to protect them (a bare
/// king falls to the ace), and shortness only pays off as ruffing value while
/// there are trumps left to ruff with. Deterministic — no randomness — so it is
/// the shared heuristic behind both the bots' bids and the human bid
/// suggestion ([suggestBid]).
double estimateTricks(List<PlayingCard> hand) {
  final bySuit = {for (final suit in Suit.values) suit: hand.ofSuit(suit)};
  final trumps = bySuit[trumpSuit]!;
  final trumpCount = trumps.length;
  bool hasTrump(int rank) => trumps.any((c) => c.rank == rank);

  var tricks = 0.0;

  // Top trumps are near-certain; each needs a spare trump behind it to survive.
  if (hasTrump(14)) tricks += 1.0;
  if (hasTrump(13)) tricks += trumpCount >= 2 ? 0.9 : 0.5;
  if (hasTrump(12)) tricks += trumpCount >= 3 ? 0.7 : 0.3;
  if (hasTrump(11)) tricks += trumpCount >= 4 ? 0.45 : 0.15;

  // Spare length in trumps eventually wins tricks by exhaustion.
  tricks += max(0, trumpCount - 4) * 0.5;

  var ruffValue = 0.0;
  for (final suit in Suit.values) {
    if (suit == trumpSuit) continue;
    final cards = bySuit[suit]!;
    final n = cards.length;
    bool has(int rank) => cards.any((c) => c.rank == rank);

    if (has(14)) tricks += 0.9;
    if (has(13)) tricks += n >= 2 ? 0.65 : 0.25;
    if (has(12)) tricks += n >= 3 ? 0.4 : 0.1;
    if (has(11)) tricks += n >= 4 ? 0.2 : 0.0;

    if (n == 0) {
      ruffValue += min(trumpCount, 3) * 0.5;
    } else if (n == 1 && trumpCount >= 2) {
      ruffValue += min(trumpCount - 1, 2) * 0.35;
    } else if (n == 2 && trumpCount >= 3) {
      ruffValue += 0.15;
    }
  }

  // You can only ruff as often as you hold spare trumps.
  tricks += min(ruffValue, max(0, trumpCount - 1).toDouble());

  return tricks;
}

/// Starting bid [hand] deserves: the rounded, clamped expected trick count.
int suggestBid(List<PlayingCard> hand) => clampBid(estimateTricks(hand).round());

/// The cards [hand] may legally play into [trick] (plays in table order).
///
/// 1. Leading is free.
/// 2. Holding the led suit you must follow it, and you must beat the best card
///    of that suit already played if you can — the "heading" rule.
/// 3. Void in the led suit you must trump, and if the trick is already trumped
///    you must overtrump when able. Unable to overtrump, you may discard
///    anything, spades included.
List<PlayingCard> legalMoves(List<PlayingCard> hand, List<TrickPlay> trick) {
  if (trick.isEmpty) return [...hand];

  final led = trick.first.card.suit;
  final inSuit = hand.ofSuit(led);

  if (inSuit.isNotEmpty) {
    final bestLed = trick
        .where((p) => p.card.suit == led)
        .map((p) => p.card.rank)
        .reduce((a, b) => a > b ? a : b);
    final higher = inSuit.where((c) => c.rank > bestLed).toList();
    return higher.isNotEmpty ? higher : inSuit;
  }

  // Void in the led suit. If the led suit *is* trump, holding no trump leaves
  // every card legal, which the empty check below already covers.
  final trumps = hand.ofSuit(trumpSuit);
  if (trumps.isEmpty) return [...hand];

  final trumpsPlayed = trick.where((p) => p.card.isTrump).toList();
  if (trumpsPlayed.isEmpty) return trumps;

  final bestTrump = trumpsPlayed.map((p) => p.card.rank).reduce((a, b) => a > b ? a : b);
  final higher = trumps.where((c) => c.rank > bestTrump).toList();
  return higher.isNotEmpty ? higher : [...hand];
}

bool isLegalPlay(List<PlayingCard> hand, List<TrickPlay> trick, PlayingCard card) =>
    legalMoves(hand, trick).contains(card);

/// The seat that takes [trick]: highest trump, else highest card of the led suit.
int trickWinner(List<TrickPlay> trick) {
  final led = trick.first.card.suit;
  final trumps = trick.where((p) => p.card.isTrump).toList();
  final contenders = trumps.isNotEmpty
      ? trumps
      : trick.where((p) => p.card.suit == led).toList();
  return contenders.reduce((a, b) => b.card.rank > a.card.rank ? b : a).seat;
}

/// Whether [card] would be winning [trick] if it were played into it right now.
bool wouldWin(List<TrickPlay> trick, PlayingCard card) {
  if (trick.isEmpty) return true;
  return trickWinner([...trick, TrickPlay(-1, card)]) == -1;
}

/// Make your bid and you score it, plus 0.1 per overtrick. Fall short and you
/// lose the bid outright.
double scoreHand(int bid, int tricksWon) {
  final raw = tricksWon >= bid ? bid + (tricksWon - bid) * 0.1 : -bid.toDouble();
  return (raw * 10).round() / 10;
}

int clampBid(int bid) => bid.clamp(minBid, maxBid);
