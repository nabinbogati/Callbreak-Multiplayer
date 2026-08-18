import 'dart:math';

import 'card.dart';
import 'rules.dart';

/// Authoritative Call Break game state machine.
///
/// Pure logic — no timers, no widgets. A host drives it, paces bot moves, and
/// hands each seat a redacted [GameView]. That split is what lets the same
/// engine back the solo-vs-bots game and a networked table.
enum GamePhase { lobby, bidding, playing, handOver, gameOver }

enum PlayerKind { human, bot }

enum BotDifficulty { easy, normal, hard }

class PlayerInfo {
  const PlayerInfo({
    required this.seat,
    required this.name,
    required this.kind,
    this.difficulty = BotDifficulty.normal,
    this.connected = true,
    this.autoplay = false,
  });

  final int seat;
  final String name;
  final PlayerKind kind;
  final BotDifficulty difficulty;
  final bool connected;

  /// True while the server is playing this seat because its human stopped
  /// responding. The player is still here and still owns the seat — they take
  /// it back the moment they touch the table.
  final bool autoplay;

  bool get isBot => kind == PlayerKind.bot;

  String get initial => name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

  PlayerInfo copyWith({
    String? name,
    PlayerKind? kind,
    bool? connected,
    bool? autoplay,
  }) => PlayerInfo(
    seat: seat,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    difficulty: difficulty,
    connected: connected ?? this.connected,
    autoplay: autoplay ?? this.autoplay,
  );

  Map<String, dynamic> toJson() => {
    'seat': seat,
    'name': name,
    'kind': kind.name,
    'difficulty': difficulty.name,
    'connected': connected,
    'autoplay': autoplay,
  };

  factory PlayerInfo.fromJson(Map<String, dynamic> json) => PlayerInfo(
    seat: json['seat'] as int,
    name: json['name'] as String,
    kind: PlayerKind.values.byName(json['kind'] as String),
    difficulty: BotDifficulty.values.byName(json['difficulty'] as String),
    connected: json['connected'] as bool? ?? true,
    autoplay: json['autoplay'] as bool? ?? false,
  );
}

class CompletedTrick {
  const CompletedTrick(this.plays, this.winner);

  final List<TrickPlay> plays;
  final int winner;

  Map<String, dynamic> toJson() => {
    'plays': plays.map((p) => p.toJson()).toList(),
    'winner': winner,
  };

  factory CompletedTrick.fromJson(Map<String, dynamic> json) => CompletedTrick(
    (json['plays'] as List)
        .map((p) => TrickPlay.fromJson(Map<String, dynamic>.from(p as Map)))
        .toList(),
    json['winner'] as int,
  );
}

class SeatRanking {
  const SeatRanking(this.seat, this.place, this.total);

  final int seat;
  final int place;
  final double total;

  Map<String, dynamic> toJson() => {'seat': seat, 'place': place, 'total': total};

  factory SeatRanking.fromJson(Map<String, dynamic> json) => SeatRanking(
    json['seat'] as int,
    json['place'] as int,
    (json['total'] as num).toDouble(),
  );
}

/// What one seat is allowed to see. Serializable so it can cross a socket.
class GameView {
  const GameView({
    required this.phase,
    required this.handIndex,
    required this.handsPerGame,
    required this.dealer,
    required this.turn,
    required this.players,
    required this.you,
    required this.hand,
    required this.legalMoveIds,
    required this.handCounts,
    required this.bids,
    required this.tricksWon,
    required this.trick,
    required this.trickNumber,
    required this.awaitingTrickClear,
    required this.lastTrick,
    required this.roundScores,
    required this.totals,
    required this.rankings,
    this.turnDeadlineMs = 0,
    this.handAdvanceMs = 0,
    this.serverTimeMs = 0,
    this.hostSeat,
  });

  final GamePhase phase;
  final int handIndex;
  final int handsPerGame;
  final int dealer;

  /// Seat to act, or null when nobody is on the clock.
  final int? turn;
  final List<PlayerInfo> players;

  /// The seat this view belongs to, or null for a spectator.
  final int? you;
  final List<PlayingCard> hand;
  final Set<String> legalMoveIds;
  final List<int> handCounts;
  final List<int?> bids;
  final List<int> tricksWon;
  final List<TrickPlay> trick;
  final int trickNumber;
  final bool awaitingTrickClear;
  final CompletedTrick? lastTrick;
  final List<List<double>> roundScores;
  final List<double> totals;
  final List<SeatRanking> rankings;

  /// Wall-clock instant (unix millis, server clock) at which the seat on the
  /// clock is played for automatically. Zero on a locally hosted table, and on
  /// a networked one whenever a bot is thinking — a countdown only makes sense
  /// for a turn a person can actually take.
  final int turnDeadlineMs;

  /// Wall-clock instant (unix millis, server clock) at which the between-hands
  /// scoreboard stops waiting for stragglers and the next hand is dealt anyway.
  /// Zero outside [GamePhase.handOver], and on a table nothing is timing.
  final int handAdvanceMs;

  /// The server's clock when this view was sent. Compare against
  /// [turnDeadlineMs] rather than the device clock, which may disagree.
  final int serverTimeMs;

  /// The seat that may start or restart this table, so every device — including
  /// a late joiner who never saw a lobby — can tell who is running it. Null on
  /// a hostless table (quickplay, or a solo game against bots).
  final int? hostSeat;

  /// Seconds left on the current turn, or null when nothing is on the clock.
  int? get secondsLeft {
    if (turnDeadlineMs <= 0 || serverTimeMs <= 0) return null;
    final remaining = turnDeadlineMs - serverTimeMs;
    return remaining > 0 ? (remaining / 1000).ceil() : 0;
  }

  bool get isMyTurn => you != null && turn == you;

  bool get iHaveBid => you != null && bids[you!] != null;

  int get handNumber => handIndex + 1;

  bool canPlay(PlayingCard card) =>
      phase == GamePhase.playing && isMyTurn && legalMoveIds.contains(card.id);

  /// The same view with the table's clocks stamped on it.
  ///
  /// The engine keeps no wall clock of its own — deadlines belong to whoever is
  /// hosting the table (the game server, or a LAN host device), so they are
  /// added on the way out rather than tracked in here.
  GameView withClock({
    required int serverTimeMs,
    int turnDeadlineMs = 0,
    int handAdvanceMs = 0,
  }) => GameView(
    phase: phase,
    handIndex: handIndex,
    handsPerGame: handsPerGame,
    dealer: dealer,
    turn: turn,
    players: players,
    you: you,
    hand: hand,
    legalMoveIds: legalMoveIds,
    handCounts: handCounts,
    bids: bids,
    tricksWon: tricksWon,
    trick: trick,
    trickNumber: trickNumber,
    awaitingTrickClear: awaitingTrickClear,
    lastTrick: lastTrick,
    roundScores: roundScores,
    totals: totals,
    rankings: rankings,
    turnDeadlineMs: turnDeadlineMs,
    handAdvanceMs: handAdvanceMs,
    serverTimeMs: serverTimeMs,
    hostSeat: hostSeat,
  );

  Map<String, dynamic> toJson() => {
    'phase': phase.name,
    'handIndex': handIndex,
    'handsPerGame': handsPerGame,
    'dealer': dealer,
    'turn': turn,
    'players': players.map((p) => p.toJson()).toList(),
    'you': you,
    'hand': hand.map((c) => c.id).toList(),
    'legalMoveIds': legalMoveIds.toList(),
    'handCounts': handCounts,
    'bids': bids,
    'tricksWon': tricksWon,
    'trick': trick.map((p) => p.toJson()).toList(),
    'trickNumber': trickNumber,
    'awaitingTrickClear': awaitingTrickClear,
    'lastTrick': lastTrick?.toJson(),
    'roundScores': roundScores,
    'totals': totals,
    'rankings': rankings.map((r) => r.toJson()).toList(),
    if (turnDeadlineMs > 0) 'turnDeadlineMs': turnDeadlineMs,
    if (handAdvanceMs > 0) 'handAdvanceMs': handAdvanceMs,
    if (serverTimeMs > 0) 'serverTimeMs': serverTimeMs,
    if (hostSeat != null) 'hostSeat': hostSeat,
  };

  factory GameView.fromJson(Map<String, dynamic> json) => GameView(
    phase: GamePhase.values.byName(json['phase'] as String),
    handIndex: json['handIndex'] as int,
    handsPerGame: json['handsPerGame'] as int,
    dealer: json['dealer'] as int,
    turn: json['turn'] as int?,
    players: (json['players'] as List)
        .map((p) => PlayerInfo.fromJson(Map<String, dynamic>.from(p as Map)))
        .toList(),
    you: json['you'] as int?,
    hand: (json['hand'] as List).map((c) => PlayingCard.fromId(c as String)).toList(),
    legalMoveIds: (json['legalMoveIds'] as List).cast<String>().toSet(),
    handCounts: (json['handCounts'] as List).cast<int>(),
    bids: (json['bids'] as List).cast<int?>(),
    tricksWon: (json['tricksWon'] as List).cast<int>(),
    trick: (json['trick'] as List)
        .map((p) => TrickPlay.fromJson(Map<String, dynamic>.from(p as Map)))
        .toList(),
    trickNumber: json['trickNumber'] as int,
    awaitingTrickClear: json['awaitingTrickClear'] as bool,
    lastTrick: json['lastTrick'] == null
        ? null
        : CompletedTrick.fromJson(Map<String, dynamic>.from(json['lastTrick'] as Map)),
    roundScores: (json['roundScores'] as List)
        .map((r) => (r as List).map((v) => (v as num).toDouble()).toList())
        .toList(),
    totals: (json['totals'] as List).map((v) => (v as num).toDouble()).toList(),
    rankings: (json['rankings'] as List)
        .map((r) => SeatRanking.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList(),
    turnDeadlineMs: json['turnDeadlineMs'] as int? ?? 0,
    handAdvanceMs: json['handAdvanceMs'] as int? ?? 0,
    serverTimeMs: json['serverTimeMs'] as int? ?? 0,
    hostSeat: json['hostSeat'] as int?,
  );
}

/// Discrete things that happened, for the UI to animate and announce.
sealed class GameEvent {
  const GameEvent();
}

class HandStarted extends GameEvent {
  const HandStarted(this.handIndex);
  final int handIndex;
}

class BidPlaced extends GameEvent {
  const BidPlaced(this.seat, this.bid);
  final int seat;
  final int bid;
}

class BiddingComplete extends GameEvent {
  const BiddingComplete();
}

class CardPlayed extends GameEvent {
  const CardPlayed(this.seat, this.card);
  final int seat;
  final PlayingCard card;
}

class TrickWon extends GameEvent {
  const TrickWon(this.seat);
  final int seat;
}

class HandOver extends GameEvent {
  const HandOver(this.handIndex, this.deltas);
  final int handIndex;
  final List<double> deltas;
}

class GameOver extends GameEvent {
  const GameOver(this.rankings);
  final List<SeatRanking> rankings;
}

/// A seat's occupant came or went.
///
/// Unlike the rest of these, this is not part of the game's rules — it is a
/// fact about the network. It exists as an event rather than only as the
/// `connected` flag on [PlayerInfo] because a player dropping out is something
/// the others should be *told*, once, not merely something they might notice on
/// an avatar if they happen to be looking at it.
class PresenceChanged extends GameEvent {
  const PresenceChanged({
    required this.seat,
    required this.name,
    required this.online,
    required this.isBot,
  });

  final int seat;
  final String name;

  /// Whether the seat's occupant is reachable right now.
  final bool online;

  /// True once the seat has been handed to a bot for good — the player's grace
  /// period ran out, or they left deliberately. A seat that is merely offline
  /// is still theirs to come back to.
  final bool isBot;

  /// True while the player is gone but their seat is still being held.
  bool get isTemporarilyAway => !online && !isBot;
}

/// The server started, or stopped, playing a seat for its occupant.
///
/// This is not a disconnect: the player is still connected and still owns the
/// seat. They ran out the clock, so the table stopped waiting. Announcing it
/// matters most to the player themselves — the whole point of the mode is that
/// they can end it by touching the screen, which they will not do unless they
/// are told.
class AutoplayChanged extends GameEvent {
  const AutoplayChanged({required this.seat, required this.name, required this.autoplay});

  final int seat;
  final String name;
  final bool autoplay;
}

class CallBreakGame {
  CallBreakGame({
    required List<PlayerInfo> players,
    int? seed,
    this.totalHands = handsPerGame,
  }) : seed = seed ?? Random().nextInt(1 << 31),
       _players = [...players] {
    _random = Random(this.seed);
  }

  final int seed;
  final int totalHands;
  late final Random _random;
  final List<PlayerInfo> _players;

  final List<GameEvent> _pendingEvents = [];

  GamePhase phase = GamePhase.lobby;
  int handIndex = 0;

  /// Starts at 3 so the first hand is dealt by seat 0 and led by seat 1.
  int dealer = 3;
  int? turn;

  List<List<PlayingCard>> _hands = List.generate(4, (_) => []);
  List<int?> bids = List.filled(4, null);
  List<int> tricksWon = List.filled(4, 0);
  List<TrickPlay> trick = [];
  int trickNumber = 0;
  bool awaitingTrickClear = false;
  CompletedTrick? lastTrick;
  List<List<double>> roundScores = List.generate(4, (_) => []);
  List<double> totals = List.filled(4, 0);
  List<SeatRanking> rankings = [];

  /// Every card face-up so far this hand — what an honest card-counter knows.
  final List<PlayingCard> playedThisHand = [];

  List<PlayerInfo> get players => List.unmodifiable(_players);

  List<PlayingCard> handOf(int seat) => List.unmodifiable(_hands[seat]);

  /// Drains the events accumulated since the last call.
  List<GameEvent> takeEvents() {
    final events = [..._pendingEvents];
    _pendingEvents.clear();
    return events;
  }

  void setPlayer(int seat, PlayerInfo info) => _players[seat] = info;

  // ------------------------------------------------------------- lifecycle

  void start() {
    if (phase != GamePhase.lobby) return;
    _startHand(0);
  }

  void _startHand(int index) {
    handIndex = index;
    dealer = (dealer + 1) % 4;
    _hands = dealHands(_random);
    bids = List.filled(4, null);
    tricksWon = List.filled(4, 0);
    trick = [];
    trickNumber = 0;
    awaitingTrickClear = false;
    lastTrick = null;
    playedThisHand.clear();
    phase = GamePhase.bidding;
    turn = (dealer + 1) % 4;
    _pendingEvents.add(HandStarted(index));
  }

  /// Leaves the between-hands summary for the next deal, or ends the game.
  void nextHand() {
    if (phase != GamePhase.handOver) return;
    if (handIndex + 1 >= totalHands) {
      _finish();
    } else {
      _startHand(handIndex + 1);
    }
  }

  void _finish() {
    phase = GamePhase.gameOver;
    turn = null;
    final seats = [0, 1, 2, 3]..sort((a, b) => totals[b].compareTo(totals[a]));
    rankings = [
      for (var i = 0; i < seats.length; i++)
        SeatRanking(seats[i], i + 1, totals[seats[i]]),
    ];
    _pendingEvents.add(GameOver(rankings));
  }

  // ---------------------------------------------------------------- bidding

  bool placeBid(int seat, int bid) {
    if (phase != GamePhase.bidding || turn != seat || bids[seat] != null) {
      return false;
    }
    final value = clampBid(bid);
    bids[seat] = value;
    _pendingEvents.add(BidPlaced(seat, value));

    if (bids.every((b) => b != null)) {
      phase = GamePhase.playing;
      turn = (dealer + 1) % 4;
      _pendingEvents.add(const BiddingComplete());
    } else {
      turn = (seat + 1) % 4;
    }
    return true;
  }

  // ------------------------------------------------------------------- play

  List<PlayingCard> legalMovesFor(int seat) {
    if (phase != GamePhase.playing || turn != seat || awaitingTrickClear) {
      return const [];
    }
    return legalMoves(_hands[seat], trick);
  }

  bool playCard(int seat, PlayingCard card) {
    if (phase != GamePhase.playing || turn != seat || awaitingTrickClear) {
      return false;
    }
    if (!_hands[seat].contains(card)) return false;
    if (!isLegalPlay(_hands[seat], trick, card)) return false;

    _hands[seat].remove(card);
    playedThisHand.add(card);
    trick.add(TrickPlay(seat, card));
    _pendingEvents.add(CardPlayed(seat, card));

    if (trick.length == 4) {
      final winner = trickWinner(trick);
      awaitingTrickClear = true;
      turn = null;
      lastTrick = CompletedTrick([...trick], winner);
      _pendingEvents.add(TrickWon(winner));
    } else {
      turn = (seat + 1) % 4;
    }
    return true;
  }

  /// Called by the host once the finished trick has been on screen long enough.
  void clearTrick() {
    if (!awaitingTrickClear) return;

    final winner = lastTrick!.winner;
    tricksWon[winner] += 1;
    trick = [];
    trickNumber += 1;
    awaitingTrickClear = false;

    if (trickNumber >= tricksPerHand) {
      _endHand();
    } else {
      turn = winner;
    }
  }

  void _endHand() {
    final deltas = [
      for (var seat = 0; seat < 4; seat++) scoreHand(bids[seat]!, tricksWon[seat]),
    ];
    for (var seat = 0; seat < 4; seat++) {
      roundScores[seat].add(deltas[seat]);
      totals[seat] = ((totals[seat] + deltas[seat]) * 10).round() / 10;
    }
    _pendingEvents.add(HandOver(handIndex, deltas));
    if (handIndex + 1 >= totalHands) {
      _finish();
    } else {
      phase = GamePhase.handOver;
      turn = null;
    }
  }

  // ------------------------------------------------------------------ views

  /// State as [seat] may see it: own cards in full, everyone else's reduced to
  /// a count. Pass null for a spectator view. [hostSeat] names the player who
  /// runs this table (null on a hostless one) so the seats can show it.
  GameView viewFor(int? seat, {int? hostSeat}) => GameView(
    phase: phase,
    handIndex: handIndex,
    handsPerGame: totalHands,
    dealer: dealer,
    turn: turn,
    players: [..._players],
    you: seat,
    hand: seat == null ? const [] : sortForDisplay(_hands[seat]),
    legalMoveIds: seat == null ? const {} : legalMovesFor(seat).map((c) => c.id).toSet(),
    handCounts: [for (final h in _hands) h.length],
    bids: [...bids],
    tricksWon: [...tricksWon],
    trick: [...trick],
    trickNumber: trickNumber,
    awaitingTrickClear: awaitingTrickClear,
    lastTrick: lastTrick,
    roundScores: [
      for (final r in roundScores) [...r],
    ],
    totals: [...totals],
    rankings: [...rankings],
    hostSeat: hostSeat,
  );
}
