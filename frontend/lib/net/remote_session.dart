import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import '../engine/card.dart';
import '../engine/game.dart';
import 'session.dart';

/// Protocol revision this client speaks. See backend/PROTOCOL.md.
const int kProtocolVersion = 2;

/// The room code that asks the server for matchmaking instead of a specific
/// table. The join sheet uppercases whatever is typed, so this is the form the
/// server sees.
const String kQuickplayRoom = 'QUICKPLAY';

/// A seat at a table hosted by the game server.
///
/// The server holds the same [CallBreakGame] engine this app does and is the
/// only authority on it, so the wire format stays thin: the client sends
/// intents and renders the redacted [GameView] it gets back. Every `view` is
/// already redacted for the receiving seat, so a client never receives another
/// player's cards.
///
/// Beyond gameplay this also carries the states an offline game has no need
/// for — a lobby, a matchmaking queue, a countdown, and reconnecting to a seat
/// after the network drops — which is why it is a [NetworkSession].
class RemoteSession extends NetworkSession {
  RemoteSession({
    required this.serverUrl,
    required this.roomCode,
    required this.playerName,
    required this.mode,
    this.difficulty = BotDifficulty.normal,
    this.guestToken,
    this.handsPerGame,
    this.creating = false,
    this.deviceId,
    String? resumeToken,
    this.connectTimeout = const Duration(seconds: 8),
  }) : _resumeToken = resumeToken {
    _connect();
  }

  final String serverUrl;
  final String roomCode;
  final String playerName;
  final BotDifficulty difficulty;
  final Duration connectTimeout;

  /// The number of hands this table plays: `3` for a quickplay, `5` for a full
  /// game. Sent on join for Online and Private, where the server deals on the
  /// host's word; omitted (null) for LAN guests, who inherit the length the
  /// host chose through the views they receive.
  final int? handsPerGame;

  /// The device id that anchors the player's account. Sent on join so the
  /// server can attribute this seat's games to the same account the profile
  /// uses — without it, online and private games are recorded with no account
  /// and never appear in history or stats (backend `internal/ws/identity.go`).
  ///
  /// Optional, exactly like the server treats it: an old or test client that
  /// omits it still plays, it just records nothing.
  final String? deviceId;

  /// True when this join is meant to open a brand-new room rather than find an
  /// existing one. Only the Private sheet's "Create" flow sets it; joins and
  /// reconnects leave it false, so a mistyped room code is reported instead of
  /// silently spawning a new empty room.
  final bool creating;

  @override
  final GameMode mode;

  /// Identity from a previous session, if the app still has one. Passing it
  /// keeps the same player id across tables; omitting it just mints a new one.
  String? guestToken;

  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  final _events = StreamController<GameEvent>.broadcast();
  Timer? _countdownTimer;

  GameView? _view;
  SessionStatus _status = SessionStatus.connecting;
  String? _error;
  int? _seat;
  LobbyState? _lobby;
  int? _countdown;
  DateTime? _turnDeadline;
  DateTime? _handAdvanceDeadline;

  /// The server-clock instants the two above were converted from. A view that
  /// merely restates a deadline it already sent must not re-anchor it: doing
  /// that would nudge the countdown by that frame's latency, and restart any
  /// bar being drained against it.
  int _turnDeadlineMs = 0;
  int _handAdvanceMs = 0;

  /// Set once the player has deliberately left, so the socket closing is not
  /// mistaken for a dropped connection worth reconnecting to.
  bool _left = false;

  /// Reissued by the server on every join; presenting it after a drop reclaims
  /// this exact seat instead of being told the game has already started.
  String? _resumeToken;

  /// True while re-establishing a connection that dropped mid-game, so the UI
  /// can say "Reconnecting" rather than "Connecting".
  bool _resuming = false;

  /// When the server will give this seat away if we have not come back. Set
  /// from the `joined` frame, so the client retries for exactly as long as
  /// there is a seat to retry for, and can say how long that is.
  Duration _reconnectGrace = const Duration(minutes: 2);
  DateTime? _seatHeldUntil;
  Timer? _retryTimer;
  int _attempts = 0;

  /// Set by [simulateOffline]. While true, [_connect] fails every attempt
  /// without touching the network — the debug "airplane mode" toggle.
  bool _simulatedOffline = false;

  int? get seat => _seat;

  /// Reissued by the server on every join. Callers that want to offer
  /// rejoining this seat after the process itself has restarted — when there
  /// is no session object left to ask — need this to persist it somewhere
  /// that outlives this object, e.g. `IdentityStore.saveActiveGame`.
  String? get resumeToken => _resumeToken;

  @override
  GameView? get view => _view;

  @override
  SessionStatus get status => _status;

  @override
  String? get errorMessage => _error;

  @override
  Stream<GameEvent> get events => _events.stream;

  @override
  LobbyState? get lobby => _lobby;

  @override
  int? get countdown => _countdown;

  /// Whether this session is waiting for players rather than connecting.
  bool get isWaiting => _lobby != null;

  @override
  bool get isResuming => _resuming;

  @override
  DateTime? get turnDeadline => _turnDeadline;

  @override
  DateTime? get handAdvanceDeadline => _handAdvanceDeadline;

  /// Converts a server-clock deadline carried by [view] into an instant on this
  /// device's clock.
  ///
  /// Only the *difference* between the two server timestamps is used, so a
  /// device whose clock is wrong — or in another timezone — still counts down
  /// correctly. The remaining latency error is the one-way trip of the frame
  /// that carried it, which is well under the second this is rendered in.
  DateTime? _localDeadline(GameView v, int deadlineMs) {
    if (deadlineMs <= 0 || v.serverTimeMs <= 0) return null;
    return clock.now().add(Duration(milliseconds: deadlineMs - v.serverTimeMs));
  }

  /// Re-reads the view's clocks, converting only the ones that actually moved.
  void _syncDeadlines(GameView v) {
    if (v.turnDeadlineMs != _turnDeadlineMs) {
      _turnDeadlineMs = v.turnDeadlineMs;
      _turnDeadline = _localDeadline(v, v.turnDeadlineMs);
    }
    if (v.handAdvanceMs != _handAdvanceMs) {
      _handAdvanceMs = v.handAdvanceMs;
      _handAdvanceDeadline = _localDeadline(v, v.handAdvanceMs);
    }
  }

  // ------------------------------------------------------------- connection

  /// True while a socket is being established, so a retry that lands on top of a
  /// schedule attempt still in flight — the "Try again" button, or a backoff
  /// timer overlapping a hung connect — cannot spin up a second socket and leave
  /// the session with two live connections fighting over its state.
  bool _connecting = false;

  Future<void> _connect() async {
    if (_connecting) return;
    _connecting = true;
    try {
      if (_simulatedOffline) {
        _connectFailed(
          "You're offline — the debug \"Go offline\" toggle is on. "
          'Turn it back on to connect.',
        );
        return;
      }

      // The room travels in the query string as well as the join frame so a
      // load balancer can hash on it and land everyone at a table on the same
      // node. The server does not depend on it.
      final uri = Uri.parse(serverUrl).replace(
        queryParameters: {
          ...Uri.parse(serverUrl).queryParameters,
          'room': roomCode,
        },
      );

      // "It won't connect" is unanswerable without knowing which address was
      // tried, so say so out loud in debug builds. Tree-shaken out of release.
      if (kDebugMode) {
        debugPrint(
          '[callbreak] connecting to $uri (room $roomCode, ${mode.name})',
        );
      }

      try {
        final socket = await WebSocket.connect(
          uri.toString(),
        ).timeout(connectTimeout);
        // The screen may have been disposed while the connect was out on the
        // network; nothing here should resurrect a dead session.
        if (_status == SessionStatus.closed || _left) {
          socket.close();
          return;
        }
        // A network switch (Wi-Fi ↔ cellular, a changed IP) does not always
        // close the underlying TCP connection — it can just go silent, with no
        // FIN or RST ever arriving. Without this, neither onError nor onDone
        // fires and the session sits in SessionStatus.ready forever, showing a
        // frozen table. Enabling protocol-level pings makes the socket itself
        // notice: if a pong does not come back in time, it closes the
        // connection and onDone runs, which is what actually drives the
        // reconnect logic below.
        socket.pingInterval = const Duration(seconds: 10);
        _socket = socket;
        _subscription = socket.listen(
          _onMessage,
          onError: (Object e) => _fail(_friendlyConnectionFailure(e.toString())),
          onDone: _onDisconnected,
        );
        _send({
          'type': 'join',
          'v': kProtocolVersion,
          'room': roomCode,
          'mode': mode == GameMode.online ? 'online' : 'private',
          'name': playerName,
          'difficulty': difficulty.name,
          if (guestToken != null) 'guestToken': guestToken,
          if (deviceId != null && deviceId!.isNotEmpty) 'deviceId': deviceId,
          if (_resumeToken != null) 'resumeToken': _resumeToken,
          if (handsPerGame != null) 'handsPerGame': handsPerGame,
          if (creating) 'create': true,
        });
      } on TimeoutException {
        _logConnectFailure('$uri took too long to answer.');
        _connectFailed(_friendlyConnectTimeout);
      } catch (e) {
        _logConnectFailure('$uri — $e');
        _connectFailed(_friendlyUnreachable);
      }
    } finally {
      _connecting = false;
    }
  }

  /// The player-facing copy for a connect that never answered. Written for a
  /// person sitting at a table with their phone in their hand — no hostnames,
  /// no exception classes — while the exact address and error are what the
  /// debug log is for ([_logConnectFailure]).
  static const _friendlyReachabilityHint =
      'Check your internet connection and try again.';

  /// The server exists but did not answer within [connectTimeout].
  static String get _friendlyConnectTimeout =>
      'The game server is taking too long to respond. '
      '$_friendlyReachabilityHint';

  /// The address was unreachable — offline, wrong host, or a server that is
  /// down.
  static String get _friendlyUnreachable =>
      "We couldn't reach the game server. $_friendlyReachabilityHint";

  /// A socket already connected reports a stream error (usually a hostile
  /// close mid-lobby). Same friendly copy as an unreachable first connect —
  /// the player's remedies are identical.
  String _friendlyConnectionFailure(String technical) {
    _logConnectFailure(technical);
    return _friendlyUnreachable;
  }

  /// Logs the technical reason for a failed connect out loud in debug builds,
  /// where the address and the exception actually help — and stays silent in a
  /// release that would only repeat whatever the player just saw.
  void _logConnectFailure(String detail) {
    if (kDebugMode) {
      debugPrint('[callbreak] connect failed: $detail');
    }
  }

  /// A connection attempt failed. While a seat is being held that is a setback,
  /// not the end: keep trying until the grace window actually runs out.
  void _connectFailed(String message) {
    if (canResume) {
      _scheduleReconnect();
      return;
    }
    _fail(message);
  }

  /// The socket closed without a fatal error frame, which means the network
  /// dropped rather than the server turning us away. If there is a seat worth
  /// returning to, start trying to get it back.
  void _onDisconnected() {
    if (_status == SessionStatus.error) return;
    _subscription = null;
    _socket = null;

    // Leaving on purpose is not something to recover from.
    if (_left) {
      _status = SessionStatus.closed;
      notifyListeners();
      return;
    }

    // Only a table that was actually dealt is worth reconnecting to. Rejoining
    // a lobby you already walked away from would take a seat back off whoever
    // is waiting.
    if (_resumeToken != null &&
        _view != null &&
        _view!.phase != GamePhase.gameOver) {
      // The server starts its grace clock the moment it notices the drop, so
      // ours starts here too.
      _seatHeldUntil ??= DateTime.now().add(_reconnectGrace);
      _scheduleReconnect();
      return;
    }

    _status = SessionStatus.closed;
    notifyListeners();
  }

  /// Whether there is still a seat being held that this session could reclaim.
  @override
  bool get canResume {
    final until = _seatHeldUntil;
    return _resumeToken != null &&
        !_left &&
        until != null &&
        DateTime.now().isBefore(until) &&
        _view != null &&
        _view!.phase != GamePhase.gameOver;
  }

  @override
  Duration? get seatHeldFor {
    final until = _seatHeldUntil;
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Queues the next attempt, backing off so a server that is down is not
  /// hammered, but never waiting so long that the grace window is wasted.
  void _scheduleReconnect() {
    _retryTimer?.cancel();

    if (!canResume) {
      // The seat is gone. Say so plainly instead of spinning forever.
      _resuming = false;
      _fail(
        "We couldn't get you back in time, so your seat was given to "
        'another player. Start a new table to play again.',
      );
      return;
    }

    _resuming = true;
    _status = SessionStatus.connecting;
    notifyListeners();

    // 1s, 2s, 4s, then every 8s — fast enough to catch a blip, slow enough not
    // to spam a server that is genuinely gone.
    final backoff = Duration(
      seconds: switch (_attempts) {
        0 => 1,
        1 => 2,
        2 => 4,
        _ => 8,
      },
    );
    _attempts++;
    _retryTimer = Timer(backoff, () {
      if (_status == SessionStatus.closed || _left) return;
      _connect();
    });
  }

  /// Try again right now, for the "Try again" button. Pointless to expose when
  /// [canResume] is false.
  @override
  void retryNow() {
    if (!canResume) return;
    _retryTimer?.cancel();
    _attempts = 0;
    _error = null;
    _resuming = true;
    _status = SessionStatus.connecting;
    notifyListeners();
    _connect();
  }

  /// Also powers the "Try again" button, but for the case [retryNow] cannot
  /// touch: a first connect that never got in, so there is no seat being held.
  /// The session just makes a fresh attempt, exactly as if the player had
  /// tapped Connect again.
  @override
  void retryConnect() {
    if (_status != SessionStatus.error || _connecting) return;
    _error = null;
    _status = SessionStatus.connecting;
    notifyListeners();
    _connect();
  }

  @override
  bool get isSimulatedOffline => _simulatedOffline;

  /// Flips the debug "airplane mode" toggle.
  ///
  /// Going offline severs the live socket exactly like a real drop —
  /// `_onDisconnected` runs, which starts the same seat-holding countdown and
  /// backoff schedule a genuine network blip would — and every retry it
  /// schedules fails locally via the [_simulatedOffline] check in [_connect]
  /// until this is flipped back. Coming back online reuses [retryNow] so the
  /// seat is reclaimed immediately rather than waiting out whatever backoff
  /// was mid-flight.
  @override
  void simulateOffline(bool offline) {
    if (_simulatedOffline == offline) return;
    _simulatedOffline = offline;

    if (offline && _socket != null) {
      _retryTimer?.cancel();
      _subscription?.cancel();
      _subscription = null;
      final socket = _socket;
      _socket = null;
      socket?.close();
      _onDisconnected(); // notifies
      return;
    }
    if (!offline && canResume) {
      retryNow(); // notifies
      return;
    }
    notifyListeners();
  }

  void _onMessage(dynamic raw) {
    late final Map<String, dynamic> message;
    try {
      message = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
    } catch (_) {
      return; // Ignore anything that is not a protocol frame.
    }

    switch (message['type']) {
      case 'joined':
        _seat = message['seat'] as int?;
        guestToken = message['guestToken'] as String? ?? guestToken;
        _resumeToken = message['resumeToken'] as String? ?? _resumeToken;
        final graceMs = message['reconnectGraceMs'] as int?;
        if (graceMs != null && graceMs > 0) {
          _reconnectGrace = Duration(milliseconds: graceMs);
        }
        _resuming = false;
        _attempts = 0;
        _seatHeldUntil = null;
        _retryTimer?.cancel();
        _status = SessionStatus.ready;
        notifyListeners();

      case 'lobby':
        _lobby = LobbyState.fromJson(message);
        // The table has been dealt, so the lobby is history.
        if (message['started'] == true) {
          _lobby = null;
        } else {
          // A live lobby means play has not begun — or a reconnect could not
          // reclaim the seat and landed in a fresh match. A view and countdown
          // left over from the previous table would render a stale, frozen
          // table, so they have to go: the frames that follow are the only
          // truth.
          _view = null;
          _countdownTimer?.cancel();
          _countdown = null;
        }
        _status = SessionStatus.ready;
        notifyListeners();

      case 'view':
        _view = GameView.fromJson(message);
        _syncDeadlines(_view!);
        _lobby = null;
        _countdown = null;
        _countdownTimer?.cancel();
        _status = SessionStatus.ready;
        notifyListeners();

      case 'event':
        _handleEvent(message);

      case 'error':
        _handleError(message);

      case 'pong':
        break;
    }
  }

  void _handleEvent(Map<String, dynamic> message) {
    switch (message['event']) {
      case 'countdown':
        // A retraction: somebody left and took the table back below the
        // minimum, so the deal that was coming is off again.
        if (message['cancelled'] == true) {
          _countdownTimer?.cancel();
          _countdown = null;
          notifyListeners();
          return;
        }
        _startCountdown(message['seconds'] as int? ?? 0);
        return;
      case 'seatChanged':
        // The accompanying `view` already carries the new `connected` flag, but
        // the event is what lets the table announce the change rather than
        // leaving it to be noticed.
        final event = PresenceChanged(
          seat: message['seat'] as int? ?? 0,
          name: message['name'] as String? ?? 'A player',
          online: message['connected'] as bool? ?? true,
          isBot: message['kind'] == 'bot',
        );
        if (!_events.isClosed) _events.add(event);
        notifyListeners();
        return;
      case 'autoplay':
        // The view that follows carries the same flag, but only the event can
        // say *that it just changed* — which is what the player who stopped
        // paying attention needs to be told.
        final event = AutoplayChanged(
          seat: message['seat'] as int? ?? 0,
          name: message['name'] as String? ?? 'A player',
          autoplay: message['autoplay'] as bool? ?? false,
        );
        if (!_events.isClosed) _events.add(event);
        notifyListeners();
        return;
      case 'readyState':
        // No animation of its own; the view that follows carries the state.
        notifyListeners();
        return;
    }

    final event = _decodeEvent(message);
    if (event != null && !_events.isClosed) _events.add(event);
  }

  void _startCountdown(int seconds) {
    _countdownTimer?.cancel();
    _countdown = seconds;
    notifyListeners();
    if (seconds <= 0) return;

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = (_countdown ?? 0) - 1;
      _countdown = remaining > 0 ? remaining : null;
      if (_countdown == null) timer.cancel();
      notifyListeners();
    });
  }

  void _handleError(Map<String, dynamic> message) {
    final code = message['code'] as String?;
    final text =
        message['message'] as String? ?? 'The server rejected the request.';

    if (code == 'redirect') {
      // The table lives on another node. Nothing has gone wrong; the client is
      // simply pointed at the right address.
      _error = '$text Please reconnect.';
      _status = SessionStatus.error;
      notifyListeners();
      return;
    }

    // Non-fatal errors are corrections, not failures: an out-of-turn tap or an
    // illegal card. The server sends a fresh view straight after, so the table
    // resyncs on its own and there is nothing to show the player.
    if (message['fatal'] != true) return;

    _fail(text);
  }

  GameEvent? _decodeEvent(Map<String, dynamic> message) {
    final seat = message['seat'] as int?;
    return switch (message['event']) {
      'handStart' => HandStarted(message['handIndex'] as int? ?? 0),
      'bid' => BidPlaced(seat ?? 0, message['bid'] as int? ?? 0),
      'biddingComplete' => const BiddingComplete(),
      'play' => CardPlayed(
        seat ?? 0,
        PlayingCard.fromId(message['card'] as String),
      ),
      'trickWon' => TrickWon(seat ?? 0),
      'handOver' => HandOver(
        message['handIndex'] as int? ?? 0,
        (message['deltas'] as List? ?? const [])
            .map((v) => (v as num).toDouble())
            .toList(),
      ),
      'gameOver' => GameOver(
        (message['rankings'] as List? ?? const [])
            .map(
              (r) => SeatRanking.fromJson(Map<String, dynamic>.from(r as Map)),
            )
            .toList(),
      ),
      _ => null,
    };
  }

  void _fail(String message) {
    _error = message;
    _status = SessionStatus.error;
    _resuming = false;
    notifyListeners();
  }

  void _send(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return;
    socket.add(jsonEncode(message));
  }

  // ------------------------------------------------------------- UI intents

  @override
  void startGame() => _send({'type': 'start'});

  /// Asks the room to change its match length while still in the lobby, so the
  /// host and players can agree on Quickplay/Normal Play before the game deals.
  @override
  void setHandsPerGame(int hands) => _send({'type': 'hands', 'hands': hands});

  @override
  void leaveLobby() {
    if (_left) return;
    _left = true;
    _send({'type': 'leave'});
    _status = SessionStatus.closed;
    notifyListeners();
  }

  /// A sign of life. The server takes the seat back off autoplay; if it was
  /// never on autoplay this costs one tiny frame and changes nothing, which is
  /// what lets the UI send it from any tap without thinking about it.
  @override
  void wakeUp() => _send({'type': 'awake'});

  @override
  void placeBid(int bid) => _send({'type': 'bid', 'bid': bid});

  @override
  void play(PlayingCard card) => _send({'type': 'play', 'card': card.id});

  @override
  void continueToNextHand() => _send({'type': 'next'});

  @override
  void restart() => _send({'type': 'restart'});

  @override
  void dispose() {
    _status = SessionStatus.closed;
    _retryTimer?.cancel();
    _countdownTimer?.cancel();
    _subscription?.cancel();
    // Give up the seat deliberately rather than leaving a bot to play it out.
    if (!_left) _send({'type': 'leave'});
    _socket?.close();
    _events.close();
    // Let persistence listeners (the active-game record) see the terminal
    // state before ChangeNotifier.dispose strips them, so an explicit quit is
    // never offered as a rejoin later.
    notifyListeners();
    super.dispose();
  }
}
