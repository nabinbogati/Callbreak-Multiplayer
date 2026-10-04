import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:clock/clock.dart';

import '../bots/bot.dart';
import '../engine/card.dart';
import '../engine/game.dart';
import '../engine/rules.dart' as rules;
import '../state/app_settings.dart';
import 'game_uploader.dart';
import 'lan_discovery.dart';
import 'local_session.dart';
import 'session.dart';

/// A table hosted on this device, reachable by other phones on the same
/// Wi‑Fi network over a plain `dart:io` [WebSocket] server — no external
/// infrastructure, no internet required.
///
/// The host itself occupies seat 0, exactly like [LocalSession.humanSeat].
/// Unlike [LocalSession], the game does not start immediately: there is a
/// lobby phase (seats open, guests trickle in over the LAN) until the host
/// calls [startGame], which fills any still-open seats with bots and begins
/// play. From that point on this mirrors [LocalSession]'s publish/schedule
/// loop, just fanned out over every connected socket instead of one local
/// field.
///
/// Unlike a local game it also runs the table's clocks, because a table with
/// other people at it cannot wait indefinitely on any one of them: a seat that
/// does not bid or play in time is handed to a bot (see [_timeOutSeat]), and
/// the between-hands scoreboard deals the next hand on its own once the wait
/// runs out. Both deadlines ride out on the view so every device can count
/// them down.
class LanHostSession extends GameSession {
  LanHostSession({
    required this.playerName,
    required this.roomCode,
    this.botNames = const ['Bot 1', 'Bot 2', 'Bot 3'],
    this.difficulty = BotDifficulty.normal,
    this.animationSpeed = AnimationSpeed.normal,
    this.mode = GameMode.lan,
    int handsPerGame = rules.handsPerGame,
  }) : _handsPerGame = handsPerGame;

  static const int hostSeat = 0;

  final String playerName;
  final String roomCode;
  final List<String> botNames;
  final BotDifficulty difficulty;
  final AnimationSpeed animationSpeed;

  int _handsPerGame;

  /// How many hands the match runs: 3 for a quickplay, 5 for a full game.
  /// Changeable right up until [startGame] deals; setting it notifies
  /// listeners so the lobby picker stays in sync.
  int get handsPerGame => _handsPerGame;

  set handsPerGame(int value) {
    if (_handsPerGame == value) return;
    _handsPerGame = value;
    notifyListeners();
    // Guests' lobbies carry the length, so a change must reach them too.
    _fanOutLobbies();
  }

  @override
  final GameMode mode;

  final Random _random = Random();

  late CallBreakGame _game;
  List<BotBrain?> _brains = List.filled(4, null);
  final List<PlayerInfo?> _seats = List.filled(4, null);
  final Map<int, WebSocket> _sockets = {};

  HttpServer? _server;
  LanBroadcaster? _broadcaster;
  Timer? _timer;
  bool _started = false;
  bool _disposed = false;

  /// Collects the upload payload as the game is played. The host is the only
  /// device that sees every seat, so it is the only one that can record a LAN
  /// game — the guests upload nothing.
  GameRecorder? _recorder;

  /// The table's two clocks, on this device's own time. They are also what the
  /// views carry out to the guests, converted there against [GameView.serverTimeMs].
  DateTime? _turnDeadline;
  DateTime? _handAdvanceDeadline;

  final _events = StreamController<GameEvent>.broadcast();
  GameView? _view;

  @override
  GameView? get view => _view;

  @override
  DateTime? get turnDeadline =>
      _started && _game.turn == hostSeat ? _turnDeadline : null;

  @override
  DateTime? get handAdvanceDeadline => _handAdvanceDeadline;

  @override
  SessionStatus get status => _disposed ? SessionStatus.closed : SessionStatus.ready;

  @override
  String? get errorMessage => null;

  @override
  Stream<GameEvent> get events => _events.stream;

  /// True once [startGame] has been called and the deal has begun.
  bool get started => _started;

  /// Current players, host plus any connected guests, even before the game
  /// has started — for the lobby UI.
  List<PlayerInfo> get lobbyPlayers => [for (final p in _seats) ?p];

  /// Whether the host may press Start: the deal must be waiting, and at least
  /// one guest must be connected. A host playing three bots is what the
  /// offline mode is for — a LAN table needs somebody who actually joined it.
  bool get canStart => !_started && lobbyPlayers.where((p) => p.connected).length >= 2;

  /// The port the embedded WebSocket server is bound to, once [startHosting]
  /// has completed. Null before the server is up.
  int? get wsPort => _server?.port;

  // -------------------------------------------------------------- lifecycle

  /// Binds the embedded WebSocket server and starts advertising this table
  /// over LAN broadcast. Seat 0 is claimed by the host immediately; other
  /// seats stay open for guests until [startGame] is called.
  Future<void> startHosting() async {
    _claimHostSeat();

    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen((HttpRequest request) async {
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final socket = await WebSocketTransformer.upgrade(request);
        _handleClient(socket);
      } else {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
      }
    });

    final broadcaster = LanBroadcaster(
      roomCode: roomCode,
      hostName: playerName,
      wsPort: server.port,
    );
    _broadcaster = broadcaster;
    await broadcaster.start();

    notifyListeners();
  }

  void _claimHostSeat() {
    _seats[hostSeat] ??= PlayerInfo(
      seat: hostSeat,
      name: playerName,
      kind: PlayerKind.human,
    );
  }

  /// Called from the lobby UI when the host is ready: fills any still-open
  /// seats with bots and starts the actual game.
  void startGame() {
    if (_started) return;
    _started = true;
    // Normally already claimed by startHosting; claimed here too so the host
    // can never end up sitting in a seat the bot filler took.
    _claimHostSeat();

    var botIndex = 0;
    for (var seat = 0; seat < 4; seat++) {
      _seats[seat] ??= PlayerInfo(
        seat: seat,
        name: botNames[botIndex % botNames.length],
        kind: PlayerKind.bot,
        difficulty: difficulty,
      );
      botIndex++;
    }

    _newGame();
    _broadcaster?.stop();
    _publish();
  }

  /// Builds a fresh [CallBreakGame] (and matching bot brains) from the
  /// current seat assignments and starts it. Used both by the initial
  /// [startGame] and by [restart], which keeps the same seats but deals a
  /// brand-new game — the same "new engine instance" approach [LocalSession]
  /// uses, since [CallBreakGame] has no in-place reset.
  void _newGame() {
    final players = [for (final p in _seats) p!];
    _game = CallBreakGame(players: players, totalHands: handsPerGame);
    _brains = [
      for (final p in players)
        p.isBot ? BotBrain(difficulty: p.difficulty, random: _random) : null,
    ];
    // Minted here rather than at game over: the id has to exist before the
    // first upload attempt for a retry to resolve to the same game.
    _recorder = GameRecorder(mode: mode, youSeat: hostSeat);
    _game.start();
  }

  // ------------------------------------------------------------- networking

  void _handleClient(WebSocket socket) {
    int? seat;

    socket.listen(
      (dynamic raw) {
        Map<String, dynamic> message;
        try {
          message = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
        } catch (_) {
          return;
        }

        switch (message['type']) {
          case 'join':
            if (seat != null) return; // Already joined on this socket.
            if (_started) {
              _sendTo(socket, {
                'type': 'error',
                'message': 'The game has already started.',
              });
              socket.close();
              return;
            }
            final openSeat = _nextOpenSeat();
            if (openSeat == null) {
              _sendTo(socket, {'type': 'error', 'message': 'Room is full'});
              socket.close();
              return;
            }
            final name = (message['name'] as String?)?.trim();
            seat = openSeat;
            _seats[openSeat] = PlayerInfo(
              seat: openSeat,
              name: (name == null || name.isEmpty) ? 'Guest' : name,
              kind: PlayerKind.human,
            );
            _sockets[openSeat] = socket;
            _sendTo(socket, {'type': 'joined', 'seat': openSeat, 'room': roomCode});
            // The joining client's session needs a lobby to render — without it
            // it sits on "connecting" even though the seat is taken.
            _sendLobby(socket, openSeat);
            _broadcaster?.updatePlayerCount(lobbyPlayers.length);
            notifyListeners();
            _fanOutLobbies();
            _fanOutViews();
          case 'bid':
            final s = seat;
            if (s == null || !_started) return;
            final bid = message['bid'] as int?;
            if (bid == null) return;
            // Acting is proof enough of presence, so it also takes the seat
            // back off autoplay — even if the bid itself is rejected.
            final woke = _clearAutoplay(s);
            if (_game.placeBid(s, bid) || woke) _publish();
          case 'play':
            final s = seat;
            if (s == null || !_started) return;
            final cardId = message['card'] as String?;
            if (cardId == null) return;
            final woke = _clearAutoplay(s);
            if (_game.playCard(s, PlayingCard.fromId(cardId)) || woke) _publish();
          case 'awake':
            // A tap anywhere on the table. Cheap and safe to repeat.
            final s = seat;
            if (s == null || !_started) return;
            if (_clearAutoplay(s)) _publish();
          case 'next':
            final s = seat;
            if (s == null || !_started) return;
            final woke = _clearAutoplay(s);
            if (_game.phase != GamePhase.handOver) {
              if (woke) _publish();
              return;
            }
            _game.nextHand();
            _publish();
          case 'restart':
            if (!_started) return;
            _timer?.cancel();
            _newGame();
            _publish();
        }
      },
      onDone: () {
        final s = seat;
        if (s == null) return;
        final current = _seats[s];
        if (current != null) {
          final disconnected = current.copyWith(connected: false);
          _seats[s] = disconnected;
          if (_started) {
            _game.setPlayer(s, disconnected);
            _fanOutEvent(
              PresenceChanged(
                seat: s,
                name: disconnected.name,
                online: false,
                isBot: disconnected.isBot,
              ),
            );
          }
        }
        _sockets.remove(s);
        _broadcaster?.updatePlayerCount(lobbyPlayers.length);
        notifyListeners();
        if (_started) {
          _publish();
        } else {
          _fanOutLobbies();
        }
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  int? _nextOpenSeat() {
    for (var seat = 1; seat < 4; seat++) {
      if (_seats[seat] == null) return seat;
    }
    return null;
  }

  void _sendTo(WebSocket socket, Map<String, dynamic> message) {
    if (socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(message));
  }

  /// Sends the pre-game lobby to one socket, shaped the way
  /// [LobbyState.fromJson] on the client parses it, so a joining player's
  /// table renders the waiting lobby instead of a stuck connecting screen.
  void _sendLobby(WebSocket socket, int seat) {
    _sendTo(socket, {
      'type': 'lobby',
      'room': roomCode,
      'mode': 'lan',
      'hostSeat': hostSeat,
      'isHost': seat == hostSeat,
      'canStart': false,
      'started': _started,
      'seats': [
        for (var i = 0; i < _seats.length; i++)
          if (_seats[i] != null)
            {
              'seat': i,
              'name': _seats[i]!.name,
              'kind': _seats[i]!.isBot ? 'bot' : 'human',
              'connected': _seats[i]!.connected,
              'isYou': i == seat,
              'isHost': i == hostSeat,
            },
      ],
      'humansSeated': lobbyPlayers.where((p) => p.connected).length,
      'minPlayers': 2,
      'handsPerGame': handsPerGame,
    });
  }

  /// Keeps every connected guest's lobby current when the seat list changes
  /// (a player joins or leaves) while the table is still waiting.
  void _fanOutLobbies() {
    if (_started) return;
    for (final entry in _sockets.entries) {
      _sendLobby(entry.value, entry.key);
    }
  }

  void _fanOutViews() {
    if (!_started) return;
    _view = _timedViewFor(hostSeat);
    for (final entry in _sockets.entries) {
      _sendTo(entry.value, {'type': 'view', ..._timedViewFor(entry.key).toJson()});
    }
  }

  /// A seat's view with the table's clocks stamped on it, so every device
  /// counts down against this one's — the host is the only authority on time
  /// here, exactly as the game server is online.
  GameView _timedViewFor(int seat) => _game.viewFor(seat, hostSeat: hostSeat).withClock(
    serverTimeMs: DateTime.now().millisecondsSinceEpoch,
    // Only the seat actually on the clock gets a countdown, and only when it
    // is a person's: a bot's think delay is flavour, not a deadline.
    turnDeadlineMs: _game.turn == seat
        ? (_turnDeadline?.millisecondsSinceEpoch ?? 0)
        : 0,
    // The scoreboard's clock belongs to the table, so everybody sees it.
    handAdvanceMs: _handAdvanceDeadline?.millisecondsSinceEpoch ?? 0,
  );

  void _fanOutEvent(GameEvent event) {
    if (!_events.isClosed) _events.add(event);
    final frame = _encodeEvent(event);
    if (frame == null) return;
    for (final socket in _sockets.values) {
      _sendTo(socket, frame);
    }
  }

  Map<String, dynamic>? _encodeEvent(GameEvent event) => switch (event) {
    HandStarted() => {
      'type': 'event',
      'event': 'handStart',
      'handIndex': event.handIndex,
    },
    BidPlaced() => {
      'type': 'event',
      'event': 'bid',
      'seat': event.seat,
      'bid': event.bid,
    },
    BiddingComplete() => const {'type': 'event', 'event': 'biddingComplete'},
    CardPlayed() => {
      'type': 'event',
      'event': 'play',
      'seat': event.seat,
      'card': event.card.id,
    },
    TrickWon() => {'type': 'event', 'event': 'trickWon', 'seat': event.seat},
    HandOver() => {
      'type': 'event',
      'event': 'handOver',
      'handIndex': event.handIndex,
      'deltas': event.deltas,
    },
    GameOver() => {
      'type': 'event',
      'event': 'gameOver',
      'rankings': event.rankings.map((r) => r.toJson()).toList(),
    },
    PresenceChanged() => {
      'type': 'event',
      'event': 'seatChanged',
      'seat': event.seat,
      'name': event.name,
      'connected': event.online,
      'kind': event.isBot ? 'bot' : 'human',
    },
    AutoplayChanged() => {
      'type': 'event',
      'event': 'autoplay',
      'seat': event.seat,
      'name': event.name,
      'autoplay': event.autoplay,
    },
  };

  // ------------------------------------------------------------- UI intents

  @override
  void wakeUp() {
    if (!_started) return;
    if (_clearAutoplay(hostSeat)) _publish();
  }

  @override
  void placeBid(int bid) {
    if (!_started) return;
    final woke = _clearAutoplay(hostSeat);
    if (_game.placeBid(hostSeat, bid) || woke) _publish();
  }

  @override
  void play(PlayingCard card) {
    if (!_started) return;
    final woke = _clearAutoplay(hostSeat);
    if (_game.playCard(hostSeat, card) || woke) _publish();
  }

  @override
  void continueToNextHand() {
    if (!_started) return;
    final woke = _clearAutoplay(hostSeat);
    if (_game.phase != GamePhase.handOver) {
      if (woke) _publish();
      return;
    }
    _game.nextHand();
    _publish();
  }

  @override
  void restart() {
    if (!_started) return;
    _timer?.cancel();
    _newGame();
    _publish();
  }

  // ------------------------------------------------------------ host clock

  /// Queues whatever the table should do on its own next, pushes the current
  /// view to every connected seat, then drains the engine's events.
  ///
  /// Scheduling comes first so the views can carry the deadline they are about
  /// to be counted down against; the timer itself cannot fire before this
  /// method returns, so nothing races.
  void _publish() {
    if (_disposed) return;
    _scheduleNextAutoAction();
    _fanOutViews();
    for (final event in _game.takeEvents()) {
      _record(event);
      _fanOutEvent(event);
    }
    notifyListeners();
  }

  /// Feeds the recorder, and hands the finished game to the upload queue.
  ///
  /// Fire-and-forget, and on the host's own account only: every other seat is
  /// uploaded with `isYou: false` and stored against no user at all, so a LAN
  /// host cannot write history onto the phones around the table.
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

  /// Sets the table's single clock to whatever is due next.
  void _scheduleNextAutoAction() {
    _timer?.cancel();
    _turnDeadline = null;
    if (_disposed || !_started) return;

    // Everyone reads the scoreboard at their own pace, but the table cannot
    // wait forever on somebody who put their phone down. The deadline is kept
    // across republishes so a guest joining the wait — or leaving it — cannot
    // keep pushing the deal back.
    if (_game.phase == GamePhase.handOver) {
      final due = _handAdvanceDeadline ??= DateTime.now().add(
        TablePacing.handAdvanceWait,
      );
      _timer = Timer(_untilNotBefore(due), () {
        if (_game.phase != GamePhase.handOver) return;
        _game.nextHand();
        _publish();
      });
      return;
    }
    _handAdvanceDeadline = null;

    if (_game.awaitingTrickClear) {
      _timer = Timer(_scaled(TablePacing.trickLinger), () {
        _game.clearTrick();
        _publish();
      });
      return;
    }

    final seat = _game.turn;
    if (seat == null) return;

    // Bidding opens only once the dealing animation is over on every screen:
    // until then no bot bids and no person's bid clock runs.
    final opensIn = _untilBiddingOpens();

    if (_isServerDriven(seat)) {
      _timer = Timer(opensIn + _thinkTime(), () => _takeServerTurn(seat));
      return;
    }

    // A person is on the clock. Give them a real turn, then play it for them.
    // Mid-trick, less thinking time is fair: whoever leads decides the suit
    // from scratch, and each seat after sees more of the trick already down.
    final timeout = opensIn +
        (_game.phase == GamePhase.bidding
            ? TablePacing.bidTimeout
            : TablePacing.playTimeouts[_game.trick.length]);
    _turnDeadline = DateTime.now().add(timeout);
    _timer = Timer(timeout, () => _timeOutSeat(seat));
  }

  /// The game and hand the deal time below belongs to, so a new hand — or a
  /// restarted game, which starts again at hand 0 — is stamped afresh.
  (CallBreakGame, int)? _dealtFor;
  DateTime _dealtAt = DateTime(0);

  /// How long until bidding opens: [TablePacing.dealGrace] after the deal,
  /// measured from the deal itself so a republish (a guest joining, a tap)
  /// cannot push it back. Unscaled, like the server's: the guests' animation
  /// speed is theirs to choose. Zero outside bidding and once it has passed.
  Duration _untilBiddingOpens() {
    if (_game.phase != GamePhase.bidding) return Duration.zero;
    final hand = (_game, _game.handIndex);
    if (_dealtFor != hand) {
      _dealtFor = hand;
      _dealtAt = clock.now();
    }
    final left = _dealtAt.add(TablePacing.dealGrace).difference(clock.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Time left until [due], never negative — a `Timer` given a negative
  /// duration fires immediately, which is right, but only by accident.
  Duration _untilNotBefore(DateTime due) {
    final left = due.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Whether the host plays this seat: a bot, a player who dropped, or one
  /// already handed over after running out of time.
  bool _isServerDriven(int seat) {
    final player = _seats[seat];
    return player == null || player.isBot || player.autoplay || !player.connected;
  }

  /// A seat ran out of time. A play-phase timeout hands it to a bot for every
  /// turn from here, not just this one: making the rest of the table sit
  /// through the full clock again on each of a walked-away player's turns
  /// would cost them over a minute a hand. [_clearAutoplay] gives the seat
  /// straight back on any sign of life. Bidding is independent — missing the
  /// bid settles it and keeps the seat, since the player still needs to act
  /// once the cards are in play.
  void _timeOutSeat(int seat) {
    if (_disposed || !_started) return;
    // The turn may have moved on between scheduling and firing — the player
    // acted just in time. Acting now would inject a move nobody made.
    if (_game.turn != seat) return;
    if (_game.phase != GamePhase.bidding) {
      _setAutoplay(seat, true);
    }
    _takeServerTurn(seat);
  }

  void _setAutoplay(int seat, bool on) {
    final player = _seats[seat];
    if (player == null || player.isBot || player.autoplay == on) return;
    final updated = player.copyWith(autoplay: on);
    _seats[seat] = updated;
    _game.setPlayer(seat, updated);
    _fanOutEvent(
      AutoplayChanged(seat: seat, name: updated.name, autoplay: on),
    );
  }

  /// Gives a seat back to its player. Returns whether anything changed, so
  /// callers only republish when it matters.
  bool _clearAutoplay(int seat) {
    if (_seats[seat]?.autoplay != true) return false;
    _setAutoplay(seat, false);
    return true;
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

  /// Plays one turn on behalf of a seat, using the same brain the bots use, so
  /// a timed-out player gets a sensible move rather than a random one.
  void _takeServerTurn(int seat) {
    if (_disposed || !_started) return;
    final brain = _brains[seat] ??= BotBrain(
      difficulty: difficulty,
      random: _random,
    );
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
    _broadcaster?.stop();
    for (final socket in _sockets.values) {
      socket.close();
    }
    _server?.close(force: true);
    _events.close();
    super.dispose();
  }
}
