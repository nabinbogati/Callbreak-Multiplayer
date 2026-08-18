import 'dart:math';

/// Card primitives for Call Break. Spades are the permanent trump suit.
enum Suit { spades, hearts, diamonds, clubs }

extension SuitInfo on Suit {
  String get code => switch (this) {
    Suit.spades => 'S',
    Suit.hearts => 'H',
    Suit.diamonds => 'D',
    Suit.clubs => 'C',
  };

  String get symbol => switch (this) {
    Suit.spades => '♠',
    Suit.hearts => '♥',
    Suit.diamonds => '♦',
    Suit.clubs => '♣',
  };

  String get label => switch (this) {
    Suit.spades => 'Spades',
    Suit.hearts => 'Hearts',
    Suit.diamonds => 'Diamonds',
    Suit.clubs => 'Clubs',
  };

  bool get isRed => this == Suit.hearts || this == Suit.diamonds;

  bool get isTrump => this == trumpSuit;
}

const Suit trumpSuit = Suit.spades;

Suit suitFromCode(String code) =>
    Suit.values.firstWhere((s) => s.code == code.toUpperCase());

/// Rank values run 2..14, so the ace is high.
const int minRank = 2;
const int maxRank = 14;

String rankLabel(int value) => switch (value) {
  14 => 'A',
  13 => 'K',
  12 => 'Q',
  11 => 'J',
  _ => '$value',
};

int rankFromLabel(String label) => switch (label.toUpperCase()) {
  'A' => 14,
  'K' => 13,
  'Q' => 12,
  'J' => 11,
  _ => int.parse(label),
};

class PlayingCard {
  const PlayingCard(this.rank, this.suit);

  final int rank;
  final Suit suit;

  bool get isTrump => suit == trumpSuit;

  String get label => rankLabel(rank);

  /// Stable wire id, e.g. `AS`, `10H`. Used by the network protocol.
  String get id => '$label${suit.code}';

  factory PlayingCard.fromId(String id) {
    final suit = suitFromCode(id.substring(id.length - 1));
    return PlayingCard(rankFromLabel(id.substring(0, id.length - 1)), suit);
  }

  @override
  bool operator ==(Object other) =>
      other is PlayingCard && other.rank == rank && other.suit == suit;

  @override
  int get hashCode => Object.hash(rank, suit);

  @override
  String toString() => id;
}

/// A full 52-card deck in a canonical order.
List<PlayingCard> fullDeck() => [
  for (final suit in Suit.values)
    for (var rank = minRank; rank <= maxRank; rank++) PlayingCard(rank, suit),
];

/// Deals 13 cards to each of the four seats.
List<List<PlayingCard>> dealHands(Random random) {
  final deck = fullDeck()..shuffle(random);
  return [
    for (var seat = 0; seat < 4; seat++)
      sortForDisplay(deck.sublist(seat * 13, seat * 13 + 13)),
  ];
}

/// Display order: trumps first, then the other suits, each ranked high to low.
List<PlayingCard> sortForDisplay(List<PlayingCard> hand) {
  final sorted = [...hand];
  sorted.sort((a, b) {
    if (a.suit != b.suit) return a.suit.index.compareTo(b.suit.index);
    return b.rank.compareTo(a.rank);
  });
  return sorted;
}

extension CardListOps on List<PlayingCard> {
  List<PlayingCard> ofSuit(Suit suit) => where((c) => c.suit == suit).toList();

  PlayingCard get lowest => reduce((a, b) => b.rank < a.rank ? b : a);

  PlayingCard get highest => reduce((a, b) => b.rank > a.rank ? b : a);
}

/// One card laid on the table by one seat.
class TrickPlay {
  const TrickPlay(this.seat, this.card);

  final int seat;
  final PlayingCard card;

  Map<String, dynamic> toJson() => {'seat': seat, 'card': card.id};

  factory TrickPlay.fromJson(Map<String, dynamic> json) =>
      TrickPlay(json['seat'] as int, PlayingCard.fromId(json['card'] as String));
}
