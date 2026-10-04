import 'dart:async';
import 'dart:math';

import 'package:clock/clock.dart';

import '../bots/bot.dart';
import '../engine/card.dart';
import '../engine/game.dart';
import '../engine/rules.dart' as rules;
import '../state/app_settings.dart';
import 'game_uploader.dart';
import 'session.dart';

/// Pacing for the automatic parts of a local table. Slow enough to read, fast
/// enough that a hand does not drag.
class TablePacing {
  static const botThinkMin = Duration(milliseconds: 550);
  static const botThinkExtra = Duration(milliseconds: 450);
  static const trickLinger = Duration(milliseconds: 1100);
  static const dealSettle = Duration(milliseconds: 350);

  /// How long a human seat has to bid before the table plays for them. Only
  /// runs where somebody else is waiting — a solo game against bots is never
  /// hurried.
  static const bidTimeout = Duration(seconds: 5);

  /// How long after a deal bidding opens. The deal view goes out the moment
  /// the cards are dealt, while the dealing animation (`Motion.dealTotalMs`)
  /// is still playing; until it is over no bot bids and no bid clock runs, so
  /// nobody's bid appears — or is hurried — mid-deal. Matches the server's
  /// `Pacing.DealGrace`.
  static const dealGrace = Duration(milliseconds: 3500);

  /// How long a human seat has to play a card, indexed by how many cards are
  /// already down this trick: the leader thinks longest, and each seat after
  /// has less to decide with more of the trick already on the table.
  static const playTimeouts = [
    Duration(seconds: 10),
    Duration(seconds: 8),
    Duration(seconds: 6),
    Duration(seconds: 5),
  ];

  /// How long the between-hands scoreboard waits before dealing anyway.
  static const handAdvanceWait = Duration(seconds: 5);
}

/// A table hosted entirely on this device: the engine, the bots and the clock
/// all live here. Seat 0 is the player.
class LocalSession extends GameSession {
  LocalSession({
    required this.playerName,
    this.botNames = const ['Bot 1', 'Bot 2', 'Bot 3'],
    this.difficulty = BotDifficulty.normal,
    this.mode = GameMode.bots,
    this.animationSpeed = AnimationSpeed.normal,
    this.handsPerGame = rules.handsPerGame,
    int? seed,
  }) : _random = Random(seed ?? DateTime.now().microsecondsSinceEpoch) {
    _startGame(seed);
  }

  static const int humanSeat = 0;

  final String playerName;
  final List<String> botNames;
  final BotDifficulty difficulty;

  /// How many hands the match runs: 3 for a quickplay, 5 for a full game.
  final int handsPerGame;

  /// Scales [TablePacing]'s durations to match the user's animation speed
  /// preference. Defaults to normal so existing call sites are unaffected.
  final AnimationSpeed animationSpeed;
  final Random _random;

  @override
  final GameMode mode;

  late CallBreakGame _game;
  late List<BotBrain?> _brains;
  Timer? _timer;
  bool _disposed = false;

  /// Collects the upload payload as the game is played. Replaced on every
  /// [restart], which is what gives each game its own idempotency key.
  GameRecorder? _recorder;

  final _events = StreamController<GameEvent>.broadcast();
  GameView? _view;

  @override
  GameView? get view => _view;

  @override
  SessionStatus get status => _disposed ? SessionStatus.closed : SessionStatus.ready;

  @override
  String? get errorMessage => null;

  @override
  Stream<GameEvent> get events => _events.stream;

  void _startGame(int? seed) {
    final players = <PlayerInfo>[
      PlayerInfo(seat: 0, name: playerName, kind: PlayerKind.human),
      for (var i = 0; i < 3; i++)
        PlayerInfo(
          seat: i + 1,
          name: botNames[i % botNames.length],
          kind: PlayerKind.bot,
          difficulty: difficulty,
        ),
    ];

    _game = CallBreakGame(players: players, seed: seed, totalHands: handsPerGame);
    _brains = [
      for (final p in players)
        p.isBot ? BotBrain(difficulty: p.difficulty, random: _random) : null,
    ];
    // Minted here rather than at game over: the id has to exist before the
    // first upload attempt for a retry to resolve to the same game.
    _recorder = GameRecorder(mode: mode, youSeat: humanSeat);
    _game.start();
    _publish();
  }

  // ------------------------------------------------------------- UI intents

  @override
  void placeBid(int bid) {
    if (_game.placeBid(humanSeat, bid)) _publish();
  }

  @override
  void play(PlayingCard card) {
    if (_game.playCard(humanSeat, card)) _publish();
  }

  @override
  void continueToNextHand() {
    if (_game.phase != GamePhase.handOver) return;
    _game.nextHand();
    _publish();
  }

  @override
  void restart() {
    _timer?.cancel();
    _startGame(null);
  }

  // ------------------------------------------------------------ host clock

  /// Pushes the current view to the UI, drains engine events, then queues
  /// whatever the table should do on its own next.
  void _publish() {
    if (_disposed) return;
    _view = _game.viewFor(humanSeat);
    for (final event in _game.takeEvents()) {
      _record(event);
      if (!_events.isClosed) _events.add(event);
    }
    notifyListeners();
    _scheduleNextAutoAction();
  }

  /// Feeds the recorder, and hands the finished game to the upload queue.
  ///
  /// Entirely fire-and-forget: [GameUploader.enqueue] swallows its own errors
  /// and nothing here awaits it, so a phone with no signal finishes the game
  /// exactly as fast as one with a connection and the player is never told
  /// anything went wrong.
  void _record(GameEvent event) {
    final recorder = _recorder;
    if (recorder == null) return;

    switch (event) {
      case HandOver():
        // The engine still holds this hand's bids and tricks; the next deal
        // clears them, so they have to be taken now.
        recorder.recordHand(
          handIndex: event.handIndex,
          bids: _game.bids,
          tricksWon: _game.tricksWon,
          deltas: event.deltas,
        );
      case GameOver():
        _recorder = null;
        final payload = recorder.build(
          players: _game.players,
          totals: _game.totals,
          rankings: event.rankings,
          handsTotal: _game.totalHands,
        );
        final uploader = GameUploader.instance;
        if (payload != null && uploader != null) unawaited(uploader.enqueue(payload));
      default:
        break;
    }
  }

  void _scheduleNextAutoAction() {
    _timer?.cancel();
    if (_disposed) return;

    if (_game.awaitingTrickClear) {
      _timer = Timer(_scaled(TablePacing.trickLinger), () {
        _game.clearTrick();
        _publish();
      });
      return;
    }

    final seat = _game.turn;
    if (seat == null || seat == humanSeat) return;

    final brain = _brains[seat];
    if (brain == null) return;

    _timer = Timer(
      _untilBiddingOpens() + _thinkTime(),
      () => _takeBotTurn(seat, brain),
    );
  }

  /// The game and hand the deal time below belongs to, so a new hand — or a
  /// restarted game, which starts again at hand 0 — is stamped afresh.
  (CallBreakGame, int)? _dealtFor;
  DateTime _dealtAt = DateTime(0);

  /// How long until bidding opens: [TablePacing.dealGrace] after the deal,
  /// scaled like the dealing animation itself. Zero outside bidding and once
  /// it has passed.
  Duration _untilBiddingOpens() {
    if (_game.phase != GamePhase.bidding) return Duration.zero;
    final hand = (_game, _game.handIndex);
    if (_dealtFor != hand) {
      _dealtFor = hand;
      _dealtAt = clock.now();
    }
    final left = _dealtAt.add(_scaled(TablePacing.dealGrace)).difference(clock.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Scales a [TablePacing] duration by the user's animation speed setting.
  Duration _scaled(Duration base) => Duration(
    milliseconds: (base.inMilliseconds * animationSpeed.durationScale).round(),
  );

  Duration _thinkTime() {
    final extra = _scaled(TablePacing.botThinkExtra).inMilliseconds;
    return _scaled(TablePacing.botThinkMin) +
        Duration(milliseconds: _random.nextInt(extra < 1 ? 1 : extra));
  }

  void _takeBotTurn(int seat, BotBrain brain) {
    if (_disposed) return;
    final hand = _game.handOf(seat);

    switch (_game.phase) {
      case GamePhase.bidding:
        _game.placeBid(seat, brain.chooseBid(hand));
      case GamePhase.playing:
        final card = brain.chooseCard(
          hand: hand,
          trick: _game.trick,
          played: _game.playedThisHand,
          bid: _game.bids[seat] ?? 1,
          tricksWon: _game.tricksWon[seat],
        );
        _game.playCard(seat, card);
      case GamePhase.lobby:
      case GamePhase.handOver:
      case GamePhase.gameOver:
        return;
    }
    _publish();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _events.close();
    super.dispose();
  }
}
