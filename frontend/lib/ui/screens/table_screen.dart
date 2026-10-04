import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, listEquals, debugPrint, ValueListenable;
import 'package:flutter/material.dart';

import '../../audio/audio_controller.dart';
import '../../design/metrics.dart';
import '../../design/motion.dart';
import '../../design/tokens.dart';
import '../../engine/card.dart';
import '../../engine/game.dart';
import '../../net/lan_host_session.dart' show LanHostSession;
import '../../net/local_session.dart' show LocalSession;
import '../../net/remote_session.dart' show kQuickplayRoom, RemoteSession;
import '../../net/session.dart';
import '../../state/active_game_binding.dart' show wireActiveGamePersistence;
import '../../state/app_settings.dart';
import '../haptics.dart';
import '../widgets/backdrop.dart';
import '../widgets/bid_panel.dart';
import '../widgets/buttons.dart';
import '../widgets/felt_table.dart';
import '../widgets/hand_fan.dart';
import '../widgets/playing_card_view.dart';
import '../widgets/pulse_ripple.dart';
import '../widgets/quick_settings_panel.dart';
import '../widgets/round_history.dart';
import '../widgets/scoreboard.dart';
import '../widgets/suit_glyph.dart';
import 'settings_sheet.dart' show RoundsCard;
import '../widgets/seat_view.dart';
import '../widgets/winner_screen.dart';

/// The table: seats around a felt surface, your hand along the bottom, and
/// overlays for bidding and between-hands scores. Works identically for a
/// solo game against bots and a networked table — it only ever talks to
/// [GameSession].
class TableScreen extends StatefulWidget {
  const TableScreen({super.key, required this.session});

  final GameSession session;

  @override
  State<TableScreen> createState() => _TableScreenState();
}

/// The width of the player's own hand cards. Shared by the hand area and the
/// throw-flight layer, which starts each thrown card at the size it left at.
double _handCardWidth(Metrics m) => m.sc(58, 62);

/// How long a thrown card may wait, landed, for the table to confirm it
/// before it is treated as refused and handed back to the hand.
const _throwConfirmTimeout = Duration(milliseconds: 2500);

class _TableScreenState extends State<TableScreen> {
  bool _showRoundHistory = false;

  /// Game-event subscription for table sounds and haptics.
  StreamSubscription<GameEvent>? _eventsSub;

  // Persist for the whole screen's lifetime so the GlobalKeys stay attached
  // to the same seat/felt widgets across rebuilds — TrickCluster and the
  // flight layers measure real on-screen positions through these.
  final Map<SeatSlot, GlobalKey> _seatKeys = {
    for (final slot in SeatSlot.values) slot: GlobalKey(),
  };
  final GlobalKey _feltStackKey = GlobalKey();

  /// Key for the outer table Stack — the flight layers position themselves
  /// relative to this, since it is a common ancestor of the felt and the hand
  /// and paints on top of both.
  final GlobalKey _tableStackKey = GlobalKey();

  /// Where this client's own thrown cards started, keyed by card id, relative
  /// to the felt's centre. Pruned as tricks clear.
  final Map<String, Offset> _throwOrigins = {};

  /// This client's own thrown cards currently drawn by the top-level flight
  /// layer (above the hand), keyed by card id. A flight runs its path, then
  /// holds at rest until the table confirms the play — on a networked table
  /// that is a round trip away — so the handoff to [TrickCluster] is seamless
  /// however long the confirmation takes.
  final Map<String, _Flight> _flights = {};

  /// Card ids that arrived via a flight: [TrickCluster] mounts them already at
  /// rest instead of replaying the throw. Pruned alongside throw origins.
  final Set<String> _flownIds = {};

  /// Watches landed flights the table has not confirmed yet.
  Timer? _flightCheck;

  /// Viewer-seat plays already on the table when this table first observed a
  /// trick — a rejoin lands mid-hand and must not re-fly those cards.
  Set<String>? _seenViewerPlayIds;

  /// Cached from the most recent build's [MetricsScope] — gesture callbacks
  /// run outside build and need it for the flight geometry.
  Metrics? _metrics;

  /// The last hand we saw the session deal, so a brand-new hand plays the
  /// dealing flourish exactly once.
  int? _lastDealtHand;

  /// Whether this table was opened to reclaim a seat in a game already under
  /// way (the "Rejoin your game?" path). Consumed by the first deal attempt.
  late bool _rejoined;

  /// Changes every time a deal starts, so [_DealOverlay] re-runs for each new
  /// hand. Null while no deal is being animated.
  Key? _dealKey;

  /// How many cards each seat has been dealt so far during the current deal,
  /// by seat index; null once the deal is done. A notifier rather than state
  /// so the 52 ticks of a deal rebuild only the hand and the seat fans that
  /// listen to it — not the whole table each time a card lands.
  final ValueNotifier<List<int>?> _dealProgress = ValueNotifier(null);

  /// The hand fan's resting slots by card id, as last laid out. The deal lands
  /// each card on its slot; throw-less plays (autoplay) start from it.
  Map<String, FanSlot>? _handSlots;

  /// A short line of help above the hand — why a card was refused.
  _HandHint? _hint;
  Timer? _hintTimer;

  /// The "someone dropped / someone is back" banner currently showing.
  _PresenceNotice? _presenceNotice;
  Timer? _presenceTimer;

  void _onHandSlotsMeasured(Map<String, FanSlot> slots) => _handSlots = slots;

  void _toggleRoundHistory() =>
      setState(() => _showRoundHistory = !_showRoundHistory);

  /// Opens the compact gameplay/sound settings sheet over the table.
  void _openQuickSettings() {
    if (!mounted) return;
    unawaited(showQuickSettingsSheet(context));
  }

  /// The "Play again" button at game over. On a quickplay table this always
  /// means going back into matchmaking for fresh opponents; other modes just
  /// re-deal the same seats.
  void _handlePlayAgain() {
    if (widget.session.mode == GameMode.online) {
      _startQuickplayRematch();
      return;
    }
    widget.session.restart();
  }

  /// Leaves this (stale) quickplay table and immediately re-enters
  /// matchmaking against the same server and hand count.
  void _startQuickplayRematch() {
    final settings = SettingsScope.of(context);
    final previous = widget.session;
    final serverUrl = previous is RemoteSession
        ? previous.serverUrl
        : settings.effectiveServerUrl;
    final rematch = RemoteSession(
      serverUrl: serverUrl,
      roomCode: kQuickplayRoom,
      playerName: settings.playerName,
      mode: GameMode.online,
      difficulty: settings.difficulty,
      guestToken: settings.guestToken,
      deviceId: settings.identity.deviceId,
      handsPerGame: previous.view?.handsPerGame,
    );
    wireActiveGamePersistence(settings, rematch);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => TableScreen(session: rematch)),
    );
  }

  @override
  void initState() {
    super.initState();
    final session = widget.session;
    _rejoined = session is RemoteSession && session.resumeToken != null;
    session.addListener(_onSessionChanged);
    _eventsSub = session.events.listen(_onGameEvent);
    // A real session may already have dealt by the time this screen builds (a
    // LocalSession publishes from its own constructor), so start the flourish
    // now rather than letting the full hand flash on screen first. Test stubs
    // present an already-playable view on purpose and are left alone.
    if (_isRealSession) {
      _maybeStartDeal();
    }
  }

  /// True for the concrete table sessions as opposed to the plain
  /// [GameSession] stubs used in widget tests. Only real sessions deal.
  bool get _isRealSession =>
      widget.session is LocalSession ||
      widget.session is RemoteSession ||
      widget.session is LanHostSession;

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    _presenceTimer?.cancel();
    _hintTimer?.cancel();
    _flightCheck?.cancel();
    _eventsSub?.cancel();
    _dealProgress.dispose();
    // Leaving mid-deal must not leave the deal loop playing to nobody.
    AudioController.instance?.stopDeal();
    widget.session.removeListener(_onSessionChanged);
    widget.session.dispose();
    super.dispose();
  }

  /// Turns discrete happenings into table sounds and touch feedback.
  void _onGameEvent(GameEvent event) {
    if (event is PresenceChanged) {
      _announce(_PresenceNotice.from(event), skipSeat: event.seat);
      return;
    }
    if (event is AutoplayChanged) {
      // Your own seat gets the standing banner instead.
      _announce(_PresenceNotice.autoplay(event), skipSeat: event.seat);
      return;
    }

    if (event is TrickWon &&
        mounted &&
        event.seat == widget.session.view?.you) {
      Haptics.thud(context);
    }

    final audio = AudioController.instance;
    if (audio == null) return;
    switch (event) {
      case CardPlayed():
        audio.playShot();
        if (_isTrumpIntoSideSuit(event.card)) audio.playTrump();
      case TrickWon():
        audio.playCollect();
      default:
        break;
    }
  }

  /// Whether [card] is a trump landing into a trick that a non-trump suit led
  /// — the moment that earns the trump flourish.
  bool _isTrumpIntoSideSuit(PlayingCard card) {
    if (!card.isTrump) return false;
    final view = widget.session.view;
    if (view == null) return false;
    final plays = view.awaitingTrickClear
        ? view.lastTrick?.plays ?? const []
        : view.trick;
    if (plays.isEmpty) return false;
    return plays.first.card.suit != trumpSuit;
  }

  /// Shows a notice about somebody else's seat for a few seconds.
  void _announce(_PresenceNotice notice, {required int skipSeat}) {
    if (widget.session.view?.you == skipSeat) return;
    if (widget.session.view?.phase == GamePhase.gameOver) return;

    _presenceTimer?.cancel();
    setState(() => _presenceNotice = notice);
    _presenceTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _presenceNotice = null);
    });
  }

  /// Shows a line of help above the hand for a moment.
  void _showHint(_HandHint hint) {
    _hintTimer?.cancel();
    setState(() => _hint = hint);
    _hintTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _hint = null);
    });
  }

  void _handleIllegal(PlayingCard card) {
    final view = widget.session.view;
    if (view == null) return;
    _showHint(_HandHint.illegal(view, card));
  }

  void _handleNotYourTurn() => _showHint(const _HandHint.waiting());

  /// Any touch anywhere is proof the player is still at the table, so it takes
  /// their seat back from autoplay. A [Listener], so it never competes with
  /// the hand's own gestures.
  void _handleTouch(PointerDownEvent _) {
    final view = widget.session.view;
    final you = view?.you;
    if (view == null || you == null) return;
    if (!view.players[you].autoplay) return;

    // A floor between sends keeps a burst of frustrated taps well inside the
    // server's frame budget.
    final now = clock.now();
    final last = _lastWake;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 400)) {
      return;
    }
    _lastWake = now;
    widget.session.wakeUp();
  }

  DateTime? _lastWake;

  void _onSessionChanged() {
    _pruneThrowOrigins();
    _maybeAutoPlay();
    // Server/bot plays of the viewer's own seat (autoplay) get the same
    // above-the-hand flight a local throw gets.
    _maybeStartAutoplayFlight();
    // A confirmation may be what a landed flight was waiting for.
    _settleFlights();
    if (widget.session.view?.phase == GamePhase.gameOver) {
      _presenceTimer?.cancel();
      _presenceNotice = null;
    }
    _maybeStartDeal();
    setState(() {});
  }

  /// Spots a freshly dealt hand and kicks off the dealing flourish once.
  ///
  /// Sets fields directly rather than calling setState, because it also runs
  /// from [initState] before the first build. Callers that run after a build
  /// are responsible for their own setState.
  void _maybeStartDeal() {
    final view = widget.session.view;
    if (view == null) return;
    if (view.phase != GamePhase.bidding && view.phase != GamePhase.playing) {
      return;
    }
    if (_lastDealtHand == view.handIndex) return;
    debugPrint(
      '[DEAL] starting deal for hand ${view.handIndex} (was $_lastDealtHand), phase=${view.phase}',
    );
    _lastDealtHand = view.handIndex;
    // A rejoin picks up a hand that may already be under way — only skip the
    // flourish if there is actual progress, and consume the flag either way.
    if (_rejoined) {
      _rejoined = false;
      final handInProgress =
          view.phase == GamePhase.playing || view.bids.any((b) => b != null);
      if (handInProgress) return;
    }
    _dealProgress.value = const [0, 0, 0, 0];
    _dealKey = UniqueKey();
    AudioController.instance?.playDeal();
  }

  /// Clears the dealing flourish once its cards have all landed.
  void _clearDeal() {
    if (_dealKey == null) return;
    setState(() => _dealKey = null);
    _dealProgress.value = null;
    AudioController.instance?.stopDeal();
    // A convenience auto-throw deferred while the cards were hidden can now
    // be scheduled.
    _maybeAutoPlay();
  }

  void _onDealProgress(List<int> counts) {
    if (!mounted) return;
    if (!listEquals(counts, _dealProgress.value)) {
      _dealProgress.value = List.unmodifiable(counts);
    }
  }

  /// The card the table should throw for the player right now, or null:
  /// the very last card, or the only remaining card of the led suit — both
  /// forced, so no real choice is skipped.
  PlayingCard? _autoPlayCandidate(GameView view, AppSettings settings) {
    final hand = view.hand;
    final legal = view.legalMoveIds;
    if (settings.autoThrowLastCard &&
        hand.length == 1 &&
        legal.contains(hand.first.id)) {
      return hand.first;
    }
    if (settings.autoThrowLastSuitCard && view.trick.isNotEmpty) {
      final ofLed = hand.ofSuit(view.trick.first.card.suit);
      if (ofLed.length == 1 && legal.contains(ofLed.first.id)) {
        return ofLed.first;
      }
    }
    return null;
  }

  /// Pending auto-throw: which turn and card it belongs to, plus its timer.
  ({int turn, String cardId})? _autoPlayKey;
  Timer? _autoPlayTimer;

  void _maybeAutoPlay() {
    final view = widget.session.view;
    final you = view?.you;
    if (view == null || you == null) return;
    if (_dealKey != null) return;
    if (view.phase != GamePhase.playing ||
        !view.isMyTurn ||
        view.awaitingTrickClear) {
      return;
    }
    // The server is already playing this seat — don't stack another on top.
    if (view.players[you].autoplay) return;

    final key = _autoPlayKey;
    if (key != null) {
      if (view.turn == key.turn && view.hand.any((c) => c.id == key.cardId)) {
        return; // Still the same throw, already scheduled.
      }
      _autoPlayKey = null;
      _autoPlayTimer?.cancel();
    }

    final settings = SettingsScope.of(context);
    final card = _autoPlayCandidate(view, settings);
    if (card == null) return;

    final seat = view.turn!;
    _autoPlayKey = (turn: seat, cardId: card.id);
    final delay = Duration(
      milliseconds: (420 * settings.animationSpeed.durationScale).round(),
    );
    _autoPlayTimer = Timer(delay, () {
      if (!mounted) return;
      final current = widget.session.view;
      if (current == null || current.turn != seat) return;
      if (!current.hand.any((c) => c.id == card.id)) return;
      if (!current.legalMoveIds.contains(card.id)) return;
      if (_flights.containsKey(card.id)) return;
      _handleCardThrown(card, null);
    });
  }

  /// Drops bookkeeping for cards no longer in the trick in progress or the
  /// one lingering before it clears — card ids recur every hand.
  void _pruneThrowOrigins() {
    if (_throwOrigins.isEmpty &&
        _flownIds.isEmpty &&
        _seenViewerPlayIds?.isEmpty != false) {
      return;
    }
    final liveIds = _liveTrickIds();
    _throwOrigins.removeWhere((id, _) => !liveIds.contains(id));
    _flownIds.removeWhere(
      (id) => !liveIds.contains(id) && !_flights.containsKey(id),
    );
    _seenViewerPlayIds?.removeWhere((id) => !liveIds.contains(id));
  }

  Set<String> _liveTrickIds() {
    final view = widget.session.view;
    return {
      if (view != null) ...view.trick.map((p) => p.card.id),
      if (view?.lastTrick != null)
        ...view!.lastTrick!.plays.map((p) => p.card.id),
    };
  }

  /// A card left the hand (tap, drag, or an auto-throw): start its flight,
  /// then forward the play to the session.
  void _handleCardThrown(PlayingCard card, ThrowRelease? release) {
    _startFlight(card, release);
    widget.session.play(card);
  }

  /// Spots plays of the viewer's own seat that arrive with no gesture — the
  /// seat on autoplay while the server or a bot plays it — and flies them
  /// above the hand like a local throw.
  void _maybeStartAutoplayFlight() {
    final view = widget.session.view;
    final you = view?.you;
    if (view == null || you == null) return;
    final plays = view.awaitingTrickClear
        ? view.lastTrick?.plays ?? const <TrickPlay>[]
        : view.trick;
    // First observation of a live trick: a rejoin landing mid-hand. Cards
    // already on the table must not re-fly.
    _seenViewerPlayIds ??= {
      for (final p in plays)
        if (p.seat == you) p.card.id,
    };
    for (final play in plays) {
      if (play.seat != you) continue;
      if (_seenViewerPlayIds!.contains(play.card.id)) continue;
      if (_throwOrigins.containsKey(play.card.id)) continue;
      if (_flights.containsKey(play.card.id)) continue;
      if (_flownIds.contains(play.card.id)) continue;
      _startFlight(play.card, null);
    }
  }

  /// Starts the top-level flight that carries a card from the hand to its
  /// resting spot on the felt, above everything else on the table.
  void _startFlight(PlayingCard card, ThrowRelease? release) {
    final m = _metrics;
    final slot = _handSlots?[card.id];
    final startGlobal =
        release?.center ?? slot?.center ?? _ownSeatAnchorGlobal();
    final origin = _feltRelativeOffset(startGlobal, _feltStackKey);
    if (origin != null) _throwOrigins[card.id] = origin;
    final target = _flightTargetGlobal();
    if (m == null || startGlobal == null || target == null) return;

    final handWidth = _handCardWidth(m);
    final flight = _Flight(
      card: card,
      startGlobal: startGlobal,
      targetGlobal: target.center,
      cardWidth: target.cardWidth,
      startScale: (release?.scale ?? 1) * handWidth / target.cardWidth,
      startAngle: release?.angle ?? slot?.angle ?? 0,
      startedAt: clock.now(),
    );
    setState(() {
      _flights[card.id] = flight;
      _flownIds.add(card.id);
    });
  }

  /// A flight finished its path; it can hand off once the table agrees.
  void _onFlightLanded(String cardId) {
    final flight = _flights[cardId];
    if (flight == null) return;
    flight.landed = true;
    _settleFlights();
  }

  /// Removes landed flights whose card the table now shows in the trick (the
  /// settled copy in [TrickCluster] takes over in the same frame), and hands
  /// back any the table never confirmed — a refused or lost play — so the
  /// card returns to the hand instead of hanging over the felt.
  void _settleFlights() {
    if (_flights.isEmpty) return;
    final live = _liveTrickIds();
    final now = clock.now();
    final done = <String>[];
    var waiting = false;
    for (final flight in _flights.values) {
      if (!flight.landed) continue;
      final id = flight.card.id;
      if (live.contains(id)) {
        done.add(id);
      } else if (now.difference(flight.startedAt) >= _throwConfirmTimeout) {
        done.add(id);
        _flownIds.remove(id);
        _throwOrigins.remove(id);
      } else {
        waiting = true;
      }
    }
    if (done.isNotEmpty && mounted) {
      setState(() {
        for (final id in done) {
          _flights.remove(id);
        }
      });
    }
    _flightCheck?.cancel();
    if (waiting) {
      _flightCheck = Timer(const Duration(milliseconds: 250), _settleFlights);
    }
  }

  /// Where a thrown card's flight lands (screen-global) and the width it
  /// lands at — exactly where and how [TrickCluster] rests the bottom seat's
  /// card. Null before the felt has been laid out.
  ({Offset center, double cardWidth})? _flightTargetGlobal() {
    final m = _metrics;
    final feltBox = _feltStackKey.currentContext?.findRenderObject();
    if (m == null ||
        feltBox is! RenderBox ||
        !feltBox.attached ||
        !feltBox.hasSize) {
      return null;
    }
    final size = feltBox.size;
    final cardWidth = trickCardWidth(m, size);
    final feltCenterGlobal = feltBox.localToGlobal(size.center(Offset.zero));
    final rest = TrickCluster.restOffsetFor(
      SeatSlot.bottom,
      cardWidth,
      Offset(0, _feltCenterBias(size, m.isPortrait)),
    );
    return (center: feltCenterGlobal + rest, cardWidth: cardWidth);
  }

  /// The player's own plate centre in screen-global coordinates — the last
  /// fallback start for a flight with no gesture and no measured slot.
  Offset? _ownSeatAnchorGlobal() {
    final box = _seatKeys[SeatSlot.bottom]?.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  Future<void> _handleBackGesture(bool didPop, Object? result) async {
    if (didPop) return;
    final session = widget.session;
    if (session.view?.phase == GamePhase.gameOver) {
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    final confirmed = await _confirmQuit(context);
    if (confirmed && mounted) {
      // An explicit quit forfeits the seat, so the stored seat record that
      // would offer a rejoin next time must go with it.
      if (session case final RemoteSession remote) {
        final identity = SettingsScope.of(context).identity;
        final stored = identity.activeGame;
        if (stored != null &&
            stored.serverUrl == remote.serverUrl &&
            stored.roomCode == remote.roomCode) {
          unawaited(identity.clearActiveGame());
        }
      }
      Navigator.of(context).pop();
    }
  }

  /// True while the table is playing this player's own hand for them.
  bool get _iAmOnAutoplay {
    final view = widget.session.view;
    final you = view?.you;
    return view != null && you != null && view.players[you].autoplay;
  }

  @override
  Widget build(BuildContext context) {
    final palette = SettingsScope.of(context).palette;
    final session = widget.session;
    final gameOver = session.view?.phase == GamePhase.gameOver;
    final debugNetwork = switch (session) {
      NetworkSession n => n,
      _ => null,
    };
    // A mid-game reconnect keeps the last deal on screen while its connection
    // is being brought back, so the table is never swapped for a blank page.
    final resuming = debugNetwork?.isResuming ?? false;
    final showTable = session.isReady || (resuming && session.view != null);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _handleBackGesture,
      child: Scaffold(
        body: MetricsScope(
          builder: (context) {
            final m = Metrics.of(context);
            _metrics = m;
            return Backdrop(
              colors: palette.tableBackground,
              glow: palette.glow,
              horizontal: !m.isPortrait,
              glowAlignment: const Alignment(0, -0.2),
              glowScale: 1.5,
              child: SafeArea(
                // A little breathing room past a landscape cutout.
                minimum: EdgeInsets.symmetric(horizontal: m.sc(0, 8)),
                child: Listener(
                  // Any touch is a sign of life; translucent and a Listener so
                  // it sees touches on bare felt and never intercepts any.
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: _handleTouch,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: showTable
                            ? _TableBody(
                                session: session,
                                palette: palette,
                                showRoundHistory: _showRoundHistory,
                                onToggleRoundHistory: _toggleRoundHistory,
                                onOpenSettings: _openQuickSettings,
                                onPlayAgain: _handlePlayAgain,
                                seatKeys: _seatKeys,
                                feltStackKey: _feltStackKey,
                                tableStackKey: _tableStackKey,
                                throwOrigins: _throwOrigins,
                                flights: _flights,
                                flownIds: _flownIds,
                                onFlightLanded: _onFlightLanded,
                                onCardThrown: _handleCardThrown,
                                onIllegal: _handleIllegal,
                                onNotYourTurn: _handleNotYourTurn,
                                hint: _hint,
                                dealKey: _dealKey,
                                dealProgress: _dealProgress,
                                onDealComplete: _clearDeal,
                                onDealProgress: _onDealProgress,
                                onHandSlotsMeasured: _onHandSlotsMeasured,
                                handSlots: () => _handSlots,
                              )
                            : _ConnectionState(session: session),
                      ),

                      // While a mid-game connection is being reclaimed the
                      // table stays visible behind a small centred card.
                      if (resuming && !session.isReady)
                        Positioned.fill(
                          child: _ReconnectOverlay(network: debugNetwork!),
                        ),

                      // The debug "Go offline" button, armed from the settings
                      // Developer section, for live networked tables only.
                      if (debugNetwork != null &&
                          debugNetwork.isReady &&
                          !gameOver &&
                          kDebugMode &&
                          SettingsScope.of(context).debugMode)
                        Positioned(
                          top: m.s(8),
                          left: 0,
                          right: 0,
                          child: Center(
                            child: _GoOfflinePill(
                              offline: debugNetwork.isSimulatedOffline,
                              onTap: () => debugNetwork.simulateOffline(
                                !debugNetwork.isSimulatedOffline,
                              ),
                            ),
                          ),
                        ),

                      // Announcements ride above the table rather than inside
                      // it, so they never disturb the felt's measured geometry.
                      Positioned(
                        top: m.s(52),
                        left: 0,
                        right: 0,
                        child: IgnorePointer(
                          child: Column(
                            children: [
                              _AutoplayBanner(
                                showing: _iAmOnAutoplay && !gameOver,
                              ),
                              if (!gameOver)
                                _PresenceBanner(notice: _presenceNotice),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The standing "we are playing your hand for you" banner.
///
/// Unlike the presence notices this does not time out: it is up for exactly as
/// long as the seat is on autoplay, and it names the way out. It ignores
/// pointers — the whole screen is the button.
class _AutoplayBanner extends StatelessWidget {
  const _AutoplayBanner({required this.showing});

  final bool showing;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, -0.3),
            end: Offset.zero,
          ).animate(a),
          child: child,
        ),
      ),
      child: !showing
          ? const SizedBox.shrink()
          : Padding(
              padding: EdgeInsets.only(bottom: m.s(6)),
              child: Container(
                margin: EdgeInsets.symmetric(horizontal: m.s(16)),
                padding: EdgeInsets.symmetric(
                  horizontal: m.s(14),
                  vertical: m.s(10),
                ),
                decoration: BoxDecoration(
                  gradient: surfaceGradient,
                  border: Border.all(
                    color: AppColors.goldMid.withValues(alpha: 0.8),
                  ),
                  borderRadius: BorderRadius.circular(m.s(14)),
                  boxShadow: [
                    ...AppShadows.high,
                    ...AppShadows.glow(AppColors.goldDeep, strength: 0.6),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.smart_toy_outlined,
                      size: m.s(18),
                      color: AppColors.goldMid,
                    ),
                    SizedBox(width: m.s(10)),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Autoplay is on',
                            style: AppText.bold(m.s(13), AppColors.goldMid),
                          ),
                          Text(
                            'Tap anywhere to take your seat back.',
                            style: AppText.medium(m.s(11), AppColors.textMuted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// One local throw's flight, drawn by [_ThrowFlight] above the hand while
/// [TrickCluster]'s own copy of [card] stays hidden.
class _Flight {
  _Flight({
    required this.card,
    required this.startGlobal,
    required this.targetGlobal,
    required this.cardWidth,
    required this.startScale,
    required this.startAngle,
    required this.startedAt,
  });

  final PlayingCard card;
  final Offset startGlobal;
  final Offset targetGlobal;

  /// The width the card lands at (the felt's card size).
  final double cardWidth;

  /// Scale at take-off relative to [cardWidth] — a hand card is bigger than a
  /// felt card, and a previewed one bigger still.
  final double startScale;
  final double startAngle;
  final DateTime startedAt;

  /// Reached the felt; waiting for the table to confirm before handing off.
  bool landed = false;
}

/// Renders one [_Flight] along the same [ThrowPath] [TrickCluster] uses, in
/// the outer table Stack's coordinate space so it paints above the felt and
/// the hand alike. Once it lands it holds still at rest (reporting
/// [onLanded]) until the parent removes it — which it does in the same frame
/// [TrickCluster] reveals its settled copy, so there is no visible handoff.
class _ThrowFlight extends StatefulWidget {
  const _ThrowFlight({
    super.key,
    required this.flight,
    required this.tableStackKey,
    required this.onLanded,
  });

  final _Flight flight;
  final GlobalKey tableStackKey;
  final ValueChanged<String> onLanded;

  @override
  State<_ThrowFlight> createState() => _ThrowFlightState();
}

class _ThrowFlightState extends State<_ThrowFlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: Motion.throwMs),
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _controller.duration = Motion.scaled(
      Motion.throwMs,
      Motion.trickScale(SettingsScope.of(context).animationSpeed.durationScale),
    );
    _controller.forward().whenCompleteOrCancel(() {
      if (mounted && _controller.isCompleted) {
        widget.onLanded(widget.flight.card.id);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tableBox = widget.tableStackKey.currentContext?.findRenderObject();
    if (tableBox is! RenderBox || !tableBox.attached || !tableBox.hasSize) {
      return const SizedBox.shrink();
    }
    final flight = widget.flight;
    final path = ThrowPath(
      start: tableBox.globalToLocal(flight.startGlobal),
      end: tableBox.globalToLocal(flight.targetGlobal),
      startScale: flight.startScale,
      startAngle: flight.startAngle,
      endAngle: TrickCluster.restAngleFor(flight.card),
    );
    final w = flight.cardWidth;
    final h = w * PlayingCardView.aspect;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = ThrowPath.curve.transform(_controller.value);
        final center = path.positionAt(t);
        return Positioned(
          left: center.dx - w / 2,
          top: center.dy - h / 2,
          child: Transform.rotate(
            angle: path.angleAt(t),
            child: Transform.scale(scale: path.scaleAt(t), child: child),
          ),
        );
      },
      child: IgnorePointer(
        child: PlayingCardView(card: flight.card, width: w, elevation: 0.6),
      ),
    );
  }
}

// --------------------------------------------------------------- dealing

/// The global (screen) centre of a seat, for its dealt cards to land on.
/// Falls back to an approximate reach before the seat has been laid out.
Offset _dealTargetGlobal(SeatSlot slot, Map<SeatSlot, GlobalKey> seatKeys) {
  final box = seatKeys[slot]?.currentContext?.findRenderObject();
  if (box is RenderBox && box.attached && box.hasSize) {
    return box.localToGlobal(box.size.center(Offset.zero));
  }
  return switch (slot) {
    SeatSlot.bottom => Offset.zero,
    SeatSlot.left => const Offset(-200, 0),
    SeatSlot.top => const Offset(0, -200),
    SeatSlot.right => const Offset(200, 0),
  };
}

/// The dealing flourish, in three beats: the deck drops onto the felt, gets
/// two quick riffles, then deals out — one card at a time round the table,
/// each arcing to its seat with a spin and shrinking to the size of that
/// seat's face-down fan. The player's own cards fly to the exact slot they
/// will occupy and turn edge-on as they arrive; the hand finishes the flip as
/// the real face-up card appears (see the hand fan's flip-in).
///
/// Drawn by a single builder each frame, which emits only the deck and the
/// handful of cards actually in the air — never 52 animated widgets.
class _DealOverlay extends StatefulWidget {
  const _DealOverlay({
    super.key,
    required this.view,
    required this.seatKeys,
    required this.feltStackKey,
    required this.tableStackKey,
    required this.handSlots,
    required this.onDone,
    required this.onProgress,
  });

  final GameView view;
  final Map<SeatSlot, GlobalKey> seatKeys;
  final GlobalKey feltStackKey;
  final GlobalKey tableStackKey;

  /// The hand fan's latest resting slots by card id (read every frame, so the
  /// overlay never needs the table to rebuild it when the fan reports them).
  final Map<String, FanSlot>? Function() handSlots;

  /// Fired once the deal finishes, so the parent clears the overlay.
  final VoidCallback onDone;

  /// Fired as cards land, with how many each seat has been dealt so far.
  final ValueChanged<List<int>> onProgress;

  @override
  State<_DealOverlay> createState() => _DealOverlayState();
}

class _DealOverlayState extends State<_DealOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);

  double _scale = 1.0;
  bool _started = false;

  /// Seat receiving each of the 52 cards: starting just past the dealer, one
  /// card to each seat in turn, 13 rounds.
  late final List<int> _order = [
    for (var round = 0; round < 13; round++)
      for (var d = 1; d <= 4; d++) (widget.view.dealer + d) % 4,
  ];

  List<int>? _lastReported;

  double get _dealStart => (Motion.dealIntroMs + Motion.shuffleMs) * _scale;
  double _beginOf(int i) => _dealStart + i * Motion.dealGapMs * _scale;
  double get _flightMs => Motion.dealFlightMs * _scale;
  double get _elapsed =>
      _controller.value * _controller.duration!.inMilliseconds;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scale = SettingsScope.of(context).animationSpeed.durationScale;
    _controller.duration = Duration(
      milliseconds: (Motion.dealTotalMs * _scale).round(),
    );
    if (!_started) {
      _started = true;
      _controller.addListener(_onTick);
      _controller.forward().whenComplete(() {
        if (mounted) widget.onDone();
      });
    }
  }

  /// Reports each seat's landed-card count as it changes, so every hand —
  /// the player's and the opponents' fans — fills in card by card.
  void _onTick() {
    if (widget.view.you == null) return;
    final elapsed = _elapsed;
    final counts = [0, 0, 0, 0];
    for (var i = 0; i < _order.length; i++) {
      if (elapsed >= _beginOf(i) + _flightMs) counts[_order[i]]++;
    }
    if (!listEquals(counts, _lastReported)) {
      _lastReported = counts;
      widget.onProgress(counts);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  RenderBox? get _tableBox {
    final box = widget.tableStackKey.currentContext?.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  /// The felt's centre in this overlay's (table Stack) coordinates.
  Offset? _deckCenter() {
    final tableBox = _tableBox;
    if (tableBox == null) return null;
    final feltBox = widget.feltStackKey.currentContext?.findRenderObject();
    if (feltBox is! RenderBox || !feltBox.attached || !feltBox.hasSize) {
      return tableBox.size.center(Offset.zero);
    }
    return tableBox.globalToLocal(
      feltBox.localToGlobal(feltBox.size.center(Offset.zero)),
    );
  }

  Offset _local(Offset global) => _tableBox?.globalToLocal(global) ?? global;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final palette = SettingsScope.of(context).palette;
    final deckWidth = m.s(46);
    final handWidth = _handCardWidth(m);
    final fanWidth = m.sc(24, 20);
    final you = widget.view.you;

    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            // Measured every frame, not once: the overlay's first build can
            // come before the table has been laid out, and nothing else
            // rebuilds it while the deal runs.
            final start = _deckCenter();
            if (start == null) return const SizedBox.shrink();
            final elapsed = _elapsed;
            final slots = widget.handSlots();
            final hand = widget.view.hand;
            final children = <Widget>[
              ..._deck(elapsed, start, deckWidth, palette),
            ];
            var playerCards = 0;
            for (var i = 0; i < _order.length; i++) {
              final slot = slotFor(seat: _order[i], viewer: you);
              final isPlayer = slot == SeatSlot.bottom;
              final playerIndex = isPlayer ? playerCards++ : -1;
              final begin = _beginOf(i);
              if (elapsed < begin || elapsed >= begin + _flightMs) continue;
              final raw = (elapsed - begin) / _flightMs;

              Offset target;
              double endAngle;
              double endWidth;
              FanSlot? fanSlot;
              if (isPlayer && playerIndex < hand.length) {
                fanSlot = slots?[hand[playerIndex].id];
              }
              if (fanSlot != null) {
                target = _local(fanSlot.center);
                endAngle = fanSlot.angle;
                endWidth = handWidth;
              } else {
                target = _local(_dealTargetGlobal(slot, widget.seatKeys));
                endAngle = switch (slot) {
                  SeatSlot.top => 0.0,
                  SeatSlot.left => -math.pi / 2,
                  SeatSlot.right => math.pi / 2,
                  SeatSlot.bottom => 0.0,
                };
                endWidth = isPlayer ? handWidth : fanWidth;
              }
              children.add(
                _dealtCard(
                  raw: raw,
                  start: start,
                  target: target,
                  endAngle: endAngle,
                  startWidth: deckWidth,
                  endWidth: endWidth,
                  flipAtEnd: isPlayer,
                  spin: isPlayer ? 0.25 : (i.isEven ? math.pi : -math.pi),
                  palette: palette,
                ),
              );
            }
            return Stack(clipBehavior: Clip.none, children: children);
          },
        ),
      ),
    );
  }

  /// The deck at the centre: dropping in, riffling twice, then thinning as
  /// cards leave it.
  List<Widget> _deck(
    double elapsed,
    Offset center,
    double width,
    ThemePalette palette,
  ) {
    var remaining = 0;
    for (var i = 0; i < _order.length; i++) {
      if (elapsed < _beginOf(i)) remaining++;
    }
    if (remaining <= 0) return const [];
    final layers = ((remaining * 10) / 52).ceil().clamp(1, 10);
    final height = width * CardBackView.aspect;
    const step = 1.6;

    final introMs = Motion.dealIntroMs * _scale;
    final shuffleMs = Motion.shuffleMs * _scale;
    var drop = 0.0;
    var scale = 1.0;
    var split = 0.0;
    if (elapsed < introMs) {
      final t = Motion.enter.transform(elapsed / introMs);
      drop = -width * 0.9 * (1 - t);
      scale = 1.25 - 0.25 * t;
    } else if (elapsed < introMs + shuffleMs) {
      // Two riffles: split apart, swing back together, twice.
      final u = (elapsed - introMs) / shuffleMs;
      split = math.sin(((u * 2) % 1) * math.pi);
    }

    Widget layer(int i, double dx, double angle) => Positioned(
      left: center.dx - width / 2 + dx + i * step * 0.5,
      top: center.dy - height / 2 + drop - i * step,
      child: Transform.rotate(
        angle: angle,
        child: Transform.scale(
          scale: scale,
          child: CardBackView(width: width, palette: palette, shadow: i == 0),
        ),
      ),
    );

    if (split <= 0.001) {
      return [for (var i = 0; i < layers; i++) layer(i, 0, 0)];
    }
    // The halves interleave as they come back together.
    final apart = width * 0.62 * split;
    return [
      for (var i = 0; i < layers; i++)
        layer(i, i.isEven ? -apart : apart, (i.isEven ? -0.14 : 0.14) * split),
    ];
  }

  Widget _dealtCard({
    required double raw,
    required Offset start,
    required Offset target,
    required double endAngle,
    required double startWidth,
    required double endWidth,
    required bool flipAtEnd,
    required double spin,
    required ThemePalette palette,
  }) {
    final t = Curves.easeOutCubic.transform(raw);
    final path = ThrowPath(
      start: start,
      end: target,
      startAngle: endAngle - spin,
      endAngle: endAngle,
      bulge: 0.1,
    );
    final pos = path.positionAt(t);
    final width = startWidth + (endWidth - startWidth) * t;
    final height = width * CardBackView.aspect;
    final lift = 1 + 0.1 * math.sin(math.pi * t);

    Widget card = CardBackView(width: width, palette: palette);
    if (flipAtEnd && raw > 0.6) {
      card = Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.0015)
          ..rotateY((raw - 0.6) / 0.4 * math.pi / 2),
        child: card,
      );
    }
    return Positioned(
      left: pos.dx - width / 2,
      top: pos.dy - height / 2,
      child: Transform.rotate(
        angle: path.angleAt(t),
        child: Transform.scale(scale: lift, child: card),
      ),
    );
  }
}

// ------------------------------------------------------------ connecting

class _ConnectionState extends StatelessWidget {
  const _ConnectionState({required this.session});

  final GameSession session;

  @override
  Widget build(BuildContext context) {
    if (session.status == SessionStatus.error) {
      // "Try again" is worth offering only while a brand-new connect is what
      // failed — no view, nothing held, so the session can simply try once
      // more. A mid-game seat that was given up can't be retried into
      // existence; that failure already says to start a new table, so a retry
      // button would only loop on the same bad news.
      final network = session is NetworkSession
          ? session as NetworkSession
          : null;
      return _ConnectFailure(
        message: session.errorMessage,
        onRetry: network != null && session.view == null
            ? network.retryConnect
            : null,
        onBack: () => Navigator.of(context).pop(),
      );
    }

    // A networked table has a state an offline one does not: sitting in a lobby
    // while it fills. That is "not ready yet" as far as the table is concerned,
    // but a bare spinner would leave the player with no idea who else is here
    // or what is being waited for.
    if (session case final NetworkSession network) {
      if (network.lobby case final lobby?) {
        return LobbyPanel(
          lobby: lobby,
          countdown: network.countdown,
          onStart: network.startGame,
          onLeave: () {
            network.leaveLobby();
            Navigator.of(context).pop();
          },
          onHandsChange: network.setHandsPerGame,
        );
      }
    }

    // Bound to a local because `session` is a public field, which Dart does not
    // type-promote.
    final active = session;
    final network = active is NetworkSession ? active : null;
    final resuming = network?.isResuming ?? false;
    // Armed debug mode + a connection currently severed by the debug button.
    // The "Back online" pill is the only way to undo that, since the session
    // itself has been told to keep failing until it's flipped off.
    final showBackOnline =
        kDebugMode &&
        network != null &&
        network.isSimulatedOffline &&
        SettingsScope.of(context).debugMode;
    return Center(
      child: _ReconnectNotice(
        resuming: resuming,
        showBackOnline: showBackOnline,
        onBackOnline: network == null
            ? null
            : () => network.simulateOffline(false),
      ),
    );
  }
}

/// The connecting/reconnecting spinner, shared by the full page of a first
/// connect ([_ConnectionState]) and the small centered card of
/// [_ReconnectOverlay].
class _ReconnectNotice extends StatelessWidget {
  const _ReconnectNotice({
    required this.resuming,
    required this.showBackOnline,
    this.onBackOnline,
  });

  final bool resuming;

  /// Armed debug mode + a connection severed by the debug button. Renders the
  /// "Back online" pill, which is the only way to undo that.
  final bool showBackOnline;

  final VoidCallback? onBackOnline;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PulseRipple(
          size: m.s(68),
          ringCount: resuming ? 2 : 3,
          child: Container(
            width: m.s(38),
            height: m.s(38),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.gold.withValues(alpha: 0.14),
              border: Border.all(
                color: AppColors.goldBorder.withValues(alpha: 0.6),
                width: 1.5,
              ),
            ),
            child: Icon(
              resuming ? Icons.sync_rounded : Icons.wifi_tethering_rounded,
              size: m.s(19),
              color: AppColors.gold,
            ),
          ),
        ),
        SizedBox(height: m.s(14)),
        // Swaps between "Connecting…" and "Reconnecting…" with a soft fade
        // instead of a hard cut, so the transition from an eager first connect
        // to a seat being reclaimed reads as one continuous story.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: Text(
            resuming ? 'Reconnecting…' : 'Connecting…',
            key: ValueKey(resuming),
            textAlign: TextAlign.center,
            style: AppText.medium(m.s(13), AppColors.textMuted),
          ),
        ),
        if (resuming)
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            child: Padding(
              key: const ValueKey('held'),
              padding: EdgeInsets.only(top: m.s(6)),
              child: Text(
                'Your seat is being held. Stay close.',
                textAlign: TextAlign.center,
                style: AppText.medium(m.s(11), AppColors.textMuted),
              ),
            ),
          ),
        if (showBackOnline) ...[
          SizedBox(height: m.s(20)),
          _GoOfflinePill(offline: true, onTap: onBackOnline ?? () {}),
        ],
      ],
    );
  }
}

/// The full-page "can't connect" screen: friendly copy up top, and a choice
/// of what to do next — retry the connect or step back. Enters with a soft
/// rise-and-fade so it reads as a deliberate state rather than an error the
/// player had to catch.
class _ConnectFailure extends StatelessWidget {
  const _ConnectFailure({
    required this.message,
    required this.onRetry,
    required this.onBack,
  });

  /// Player-facing copy straight from the session — already free of
  /// hostnames, port numbers and exception names.
  final String? message;

  /// Fires a fresh connect attempt, when the session still has one to make.
  /// Null on sessions with nothing left to retry.
  final VoidCallback? onRetry;

  final VoidCallback onBack;

  static const _defaultMessage =
      "Something went wrong while connecting. Check your internet and "
      'try again.';

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Center(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, m.s(18) * (1 - t)),
            child: child,
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(m.s(24)),
          // Capped to the same width as the reconnect card and the rejoin
          // dialog, so the copy wraps like a card rather than one long line
          // and the two buttons stay finger-sized instead of stretching to
          // whatever the window happens to be.
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: m.s(300)),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _AttentionPulse(),
                SizedBox(height: m.s(14)),
                Text(
                  "Can't connect",
                  textAlign: TextAlign.center,
                  style: AppText.bold(m.s(18), AppColors.textPrimary),
                ),
                SizedBox(height: m.s(6)),
                Text(
                  message ?? _defaultMessage,
                  textAlign: TextAlign.center,
                  style: AppText.medium(m.s(13), AppColors.textMuted),
                ),
                SizedBox(height: m.s(22)),
                Row(
                  children: [
                    if (onRetry != null) ...[
                      Expanded(
                        child: GoldButton(
                          label: 'Try again',
                          icon: Icons.refresh_rounded,
                          dense: true,
                          onTap: onRetry!,
                        ),
                      ),
                      SizedBox(width: m.s(10)),
                    ],
                    Expanded(
                      child: GhostButton(
                        label: 'Back',
                        dense: true,
                        onTap: onBack,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "attention" mark under an error: a wifi-off glyph inside a faint
/// danger halo that slowly breathes. The motion pulls the eye without ever
/// implying the app is actively searching — that language belongs to the
/// connecting ripple, not to a moment that has already failed.
class _AttentionPulse extends StatefulWidget {
  const _AttentionPulse();

  @override
  State<_AttentionPulse> createState() => _AttentionPulseState();
}

class _AttentionPulseState extends State<_AttentionPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return SizedBox(
      width: m.s(72),
      height: m.s(72),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: m.s(54 + 10 * t),
                height: m.s(54 + 10 * t),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.danger.withValues(alpha: 0.08 + 0.05 * t),
                  border: Border.all(
                    color: AppColors.danger.withValues(alpha: 0.3 + 0.15 * t),
                    width: 1.5,
                  ),
                ),
              ),
              Container(
                width: m.s(52),
                height: m.s(52),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.danger.withValues(alpha: 0.14),
                ),
                child: Icon(
                  Icons.wifi_off_rounded,
                  size: m.s(26),
                  color: AppColors.danger,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A small centered card shown while a mid-game connection is being brought
/// back. Unlike the full-page [_ConnectionState], the table stays fully
/// visible around it; a transparent, hit-testable barrier underneath absorbs
/// taps so the player cannot poke at a table whose socket is gone, without
/// ever dimming the game underneath.
class _ReconnectOverlay extends StatelessWidget {
  const _ReconnectOverlay({required this.network});

  final NetworkSession network;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final showBackOnline =
        kDebugMode &&
        network.isSimulatedOffline &&
        SettingsScope.of(context).debugMode;

    return Stack(
      children: [
        // Transparent but hit-testable: blocks the table behind it from
        // receiving taps, while still showing it in full.
        Positioned.fill(child: Container(color: Colors.transparent)),
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: m.s(300)),
            child: GlassPanel(
              child: _ReconnectNotice(
                resuming: true,
                showBackOnline: showBackOnline,
                onBackOnline: () => network.simulateOffline(false),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A short-lived announcement that something changed about somebody's seat —
/// their connection, or whether they are still the one playing it.
class _PresenceNotice {
  const _PresenceNotice({
    required this.message,
    required this.online,
    this.icon,
  });

  final String message;

  /// Drives the accent colour: a return is good news, a drop is not.
  final bool online;

  /// Overrides the default wifi glyph, for notices that are not about the
  /// network at all.
  final IconData? icon;

  /// Someone stopped responding and the table moved on without them — or came
  /// back and took their seat again. Worth saying, because from the outside an
  /// idle player and a fast one look the same.
  factory _PresenceNotice.autoplay(AutoplayChanged event) => _PresenceNotice(
    message: event.autoplay
        ? '${event.name} is idle — playing automatically'
        : '${event.name} is playing again',
    online: !event.autoplay,
    icon: event.autoplay ? Icons.smart_toy_outlined : Icons.touch_app_outlined,
  );

  factory _PresenceNotice.from(PresenceChanged event) {
    if (event.isTemporarilyAway) {
      return _PresenceNotice(
        message: '${event.name} lost connection — a bot is playing their hand',
        online: false,
      );
    }
    if (!event.online) {
      return _PresenceNotice(
        message: '${event.name} went offline',
        online: false,
      );
    }
    if (event.isBot) {
      // Came back online as a bot: the seat was given up for good.
      return _PresenceNotice(
        message: '${event.name} left — a bot has taken the seat',
        online: false,
      );
    }
    return _PresenceNotice(message: '${event.name} is back', online: true);
  }
}

/// Fades a [_PresenceNotice] in and out over the table.
class _PresenceBanner extends StatelessWidget {
  const _PresenceBanner({required this.notice});

  final _PresenceNotice? notice;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final current = notice;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 240),
      child: current == null
          ? const SizedBox.shrink()
          : Center(
              key: ValueKey(current.message),
              child: Container(
                margin: EdgeInsets.symmetric(horizontal: m.s(16)),
                padding: EdgeInsets.symmetric(
                  horizontal: m.s(14),
                  vertical: m.s(9),
                ),
                decoration: BoxDecoration(
                  color: const Color(0xE60A1207),
                  border: Border.all(
                    color:
                        (current.online
                                ? AppColors.success
                                : AppColors.textMuted)
                            .withValues(alpha: 0.55),
                  ),
                  borderRadius: BorderRadius.circular(m.s(12)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x73000000),
                      blurRadius: 14,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      current.icon ??
                          (current.online
                              ? Icons.wifi_rounded
                              : Icons.wifi_off_rounded),
                      size: m.s(14),
                      color: current.online
                          ? AppColors.success
                          : AppColors.textMuted,
                    ),
                    SizedBox(width: m.s(8)),
                    Flexible(
                      child: Text(
                        current.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.semiBold(m.s(12), AppColors.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// The pre-game table: who is sitting at it, and what it is waiting for.
///
/// Both networked modes land here. A private table waits for its host to press
/// Start; a quickplay table deals itself once enough people have arrived, and
/// says so rather than leaving the player guessing at a spinner.
class LobbyPanel extends StatelessWidget {
  const LobbyPanel({
    super.key,
    required this.lobby,
    required this.countdown,
    required this.onStart,
    required this.onLeave,
    required this.onHandsChange,
  });

  final LobbyState lobby;
  final int? countdown;
  final VoidCallback onStart;
  final VoidCallback onLeave;
  final ValueChanged<int> onHandsChange;

  String get _subtitle {
    if (lobby.isOnline) {
      if (lobby.isWaitingForPlayers) {
        final need = lobby.stillNeeded;
        return 'Waiting for $need more ${need == 1 ? 'player' : 'players'}. '
            'A game needs at least ${lobby.minPlayers}.';
      }
      return lobby.seats.length >= 4
          ? 'The table is full.'
          : 'Starting soon. Any empty seats become bots.';
    }
    return lobby.seats.length >= 4
        ? 'The table is full.'
        : 'Share the code. Empty seats become bots.';
  }

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final palette = SettingsScope.of(context).palette;

    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(m.s(24)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (lobby.isOnline)
              Text(
                'Finding players',
                style: AppText.bold(m.s(22), AppColors.gold),
              )
            else
              // The room code shown as a prominent gold wordmark box, the way
              // the original hosting card displayed it.
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: m.s(28),
                  vertical: m.sc(18, 10),
                ),
                decoration: BoxDecoration(
                  color: AppColors.panelSoft,
                  border: Border.all(
                    color: AppColors.goldBorder.withValues(alpha: 0.4),
                  ),
                  borderRadius: BorderRadius.circular(m.sc(14, 11)),
                ),
                child: GoldGradientText(
                  lobby.roomCode,
                  style: AppText.wordmark(m.sc(34, 26)),
                ),
              ),
            SizedBox(height: m.s(4)),
            // The subtitle changes as the table fills; a cross-fade keeps the
            // "still making progress" story alive instead of cutting to a new
            // sentence.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              child: Text(
                _subtitle,
                key: ValueKey(_subtitle),
                textAlign: TextAlign.center,
                style: AppText.medium(m.s(12), AppColors.textMuted),
              ),
            ),
            SizedBox(height: m.s(20)),

            // Four slots always, so the table reads as a table: the empty ones
            // are as informative as the taken ones while you wait.
            Wrap(
              alignment: WrapAlignment.center,
              spacing: m.s(14),
              runSpacing: m.s(12),
              children: [
                for (var seat = 0; seat < 4; seat++)
                  _LobbySeatView(
                    seat: _seatAt(seat),
                    palette: palette,
                    size: m.sc(52, 44),
                  ),
              ],
            ),

            SizedBox(height: m.s(20)),
            // Private rooms agree on the match length here, before the deal.
            // The host picks; everyone else just sees the chosen length.
            if (!lobby.isOnline) ...[
              _LobbyHandsPicker(
                hands: lobby.handsPerGame,
                onChanged: lobby.isHost ? onHandsChange : null,
              ),
              SizedBox(height: m.s(20)),
            ],
            // The countdown ticks every second; fading each new number over
            // the old is the only motion in a countdown that reassures rather
            // than stutters.
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 240),
              child: countdown != null
                  ? Text(
                      'Starting in $countdown…',
                      key: ValueKey('countdown-$countdown'),
                      style: AppText.bold(m.s(15), AppColors.gold),
                    )
                  : const SizedBox.shrink(),
            ),
            if (countdown == null)
              if (lobby.canStart && lobby.isHost)
                _LobbyButton(label: 'Start game', onTap: onStart, primary: true)
              else
                Text(
                  lobby.isOnline
                      ? 'You can leave any time before the game starts.'
                      : lobby.isHost
                      ? 'Waiting for at least one more player — you need 2 to start.'
                      : 'Waiting for the host to start…',
                  textAlign: TextAlign.center,
                  style: AppText.medium(m.s(12), AppColors.textMuted),
                ),

            SizedBox(height: m.s(14)),
            _LobbyButton(label: 'Leave', onTap: onLeave, primary: false),
          ],
        ),
      ),
    );
  }

  LobbySeat? _seatAt(int index) {
    for (final seat in lobby.seats) {
      if (seat.seat == index) return seat;
    }
    return null;
  }
}

/// One place at the pre-game table: an avatar and a name, or an empty chair.
///
/// The avatar deliberately echoes the one [SeatView] draws around the felt, so
/// the people you waited with are recognisably the same people you then play
/// against.
class _LobbySeatView extends StatelessWidget {
  const _LobbySeatView({
    required this.seat,
    required this.palette,
    required this.size,
  });

  final LobbySeat? seat;
  final ThemePalette palette;
  final double size;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final occupant = seat;

    return SizedBox(
      width: size + m.s(26),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (occupant == null)
            _EmptyChair(size: size)
          else
            _LobbyAvatar(seat: occupant, palette: palette, size: size),
          SizedBox(height: m.s(6)),
          Text(
            occupant == null ? 'Open' : occupant.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: AppText.semiBold(
              m.s(12),
              occupant == null || !occupant.connected
                  ? AppColors.textMuted
                  : AppColors.textPrimary,
            ),
          ),
          if (occupant != null && occupant.isYou && !occupant.isBot)
            Text('you', style: AppText.medium(m.s(10), AppColors.textMuted)),
          if (occupant != null && occupant.isHost && !occupant.isYou)
            const _HostBadge(),
          if (occupant != null && occupant.isBot)
            Text('bot', style: AppText.medium(m.s(10), AppColors.textMuted)),
        ],
      ),
    );
  }
}

/// A small gold "host" mark, so it is obvious at a glance who runs the table —
/// the same player the afterscreen will stamp on the seat around the felt.
class _HostBadge extends StatelessWidget {
  const _HostBadge();

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Container(
      padding: EdgeInsets.symmetric(horizontal: m.s(7), vertical: m.s(2)),
      decoration: BoxDecoration(
        color: AppColors.gold.withValues(alpha: 0.15),
        border: Border.all(color: AppColors.goldBorder.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(m.s(6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.workspace_premium_rounded,
            size: m.s(10),
            color: AppColors.gold,
          ),
          SizedBox(width: m.s(3)),
          Text('host', style: AppText.bold(m.s(9), AppColors.gold)),
        ],
      ),
    );
  }
}

class _LobbyAvatar extends StatelessWidget {
  const _LobbyAvatar({
    required this.seat,
    required this.palette,
    required this.size,
  });

  final LobbySeat seat;
  final ThemePalette palette;
  final double size;

  /// The same initial rule [PlayerInfo.initial] uses, so a player's mark does
  /// not change between the lobby and the table.
  String get _initial {
    final trimmed = seat.name.trim();
    return trimmed.isEmpty ? '?' : trimmed[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: seat.connected ? 1 : 0.45,
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: seat.isYou
                ? const [AppColors.gold, AppColors.goldDeep]
                : palette.avatar,
          ),
          border: Border.all(
            color: seat.isYou
                ? AppColors.goldLight.withValues(alpha: 0.9)
                : AppColors.textMuted.withValues(alpha: 0.3),
            width: seat.isYou ? 2 : 1.5,
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x73000000),
              blurRadius: 10,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: seat.isBot
            ? Icon(
                Icons.smart_toy_outlined,
                size: size * 0.45,
                color: AppColors.textOnDark,
              )
            : Text(
                _initial,
                style: AppText.bold(
                  size * 0.37,
                  seat.isYou ? AppColors.onGold : AppColors.textOnDark,
                ),
              ),
      ),
    );
  }
}

/// A seat nobody has taken yet. It breathes — border and glyph slowly
/// brightening and dimming — as the "someone could sit here" invitation the
/// lobby is waiting on, rather than a static outline.
class _EmptyChair extends StatefulWidget {
  const _EmptyChair({required this.size});

  final double size;

  @override
  State<_EmptyChair> createState() => _EmptyChairState();
}

class _EmptyChairState extends State<_EmptyChair>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.textPrimary.withValues(alpha: 0.04 + 0.03 * t),
            border: Border.all(
              color: AppColors.textMuted.withValues(alpha: 0.25 + 0.25 * t),
              width: 1.5,
            ),
          ),
          child: Icon(
            Icons.person_add_alt_1_outlined,
            size: size * 0.4,
            color: AppColors.textMuted.withValues(alpha: 0.5 + 0.25 * t),
          ),
        );
      },
    );
  }
}

class _LobbyButton extends StatelessWidget {
  const _LobbyButton({
    required this.label,
    required this.onTap,
    required this.primary,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: m.s(180)),
      child: primary
          ? GoldButton(
              label: label,
              icon: Icons.play_arrow_rounded,
              onTap: onTap,
            )
          : GhostButton(label: label, dense: true, onTap: onTap),
    );
  }
}

class _LobbyHandsPicker extends StatelessWidget {
  const _LobbyHandsPicker({required this.hands, this.onChanged});

  final int hands;

  /// Null for everyone but the host: the length is then shown read-only.
  final ValueChanged<int>? onChanged;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final onChange = onChanged;

    // Non-hosts just see the chosen length as a label — no picker to change.
    if (onChange == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Match length',
            style: AppText.semiBold(m.sc(12, 11), AppColors.textMuted),
          ),
          SizedBox(height: m.s(4)),
          Text(
            hands == 3 ? 'Quickplay · 3 hands' : 'Normal Play · 5 hands',
            style: AppText.bold(m.sc(14, 12), AppColors.gold),
          ),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Match length',
          style: AppText.semiBold(m.sc(12, 11), AppColors.textMuted),
        ),
        SizedBox(height: m.s(8)),
        // A compact, width-capped row so the two cards sit side by side
        // without dominating the lobby panel.
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: m.s(300)),
            child: Row(
              children: [
                Expanded(
                  child: RoundsCard(
                    title: 'Quickplay',
                    subtitle: '3 hands · fast matches',
                    selected: hands == 3,
                    onTap: () => onChange(3),
                    compact: true,
                  ),
                ),
                SizedBox(width: m.sc(10, 8)),
                Expanded(
                  child: RoundsCard(
                    title: 'Normal Play',
                    subtitle: '5 hands · the full game',
                    selected: hands == 5,
                    onTap: () => onChange(5),
                    compact: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ table

class _TableBody extends StatelessWidget {
  const _TableBody({
    required this.session,
    required this.palette,
    required this.showRoundHistory,
    required this.onToggleRoundHistory,
    required this.onOpenSettings,
    required this.onPlayAgain,
    required this.seatKeys,
    required this.feltStackKey,
    required this.tableStackKey,
    required this.throwOrigins,
    required this.flights,
    required this.flownIds,
    required this.onFlightLanded,
    required this.onCardThrown,
    required this.onIllegal,
    required this.onNotYourTurn,
    required this.hint,
    required this.dealKey,
    required this.dealProgress,
    required this.onDealComplete,
    required this.onDealProgress,
    required this.onHandSlotsMeasured,
    required this.handSlots,
  });

  final GameSession session;
  final ThemePalette palette;
  final bool showRoundHistory;
  final VoidCallback onToggleRoundHistory;
  final VoidCallback onOpenSettings;
  final VoidCallback onPlayAgain;
  final Map<SeatSlot, GlobalKey> seatKeys;
  final GlobalKey feltStackKey;
  final GlobalKey tableStackKey;
  final Map<String, Offset> throwOrigins;
  final Map<String, _Flight> flights;
  final Set<String> flownIds;
  final ValueChanged<String> onFlightLanded;
  final void Function(PlayingCard card, ThrowRelease? release) onCardThrown;
  final ValueChanged<PlayingCard> onIllegal;
  final VoidCallback onNotYourTurn;
  final _HandHint? hint;

  /// Non-null only while a new hand is being dealt.
  final Key? dealKey;

  /// Cards dealt to each seat so far (null outside a deal).
  final ValueListenable<List<int>?> dealProgress;
  final VoidCallback onDealComplete;
  final ValueChanged<List<int>> onDealProgress;
  final ValueChanged<Map<String, FanSlot>> onHandSlotsMeasured;
  final Map<String, FanSlot>? Function() handSlots;

  @override
  Widget build(BuildContext context) {
    final view = session.view!;
    final m = Metrics.of(context);
    // The hand and bid UI stay hidden until the deal is down, so nothing that
    // depends on seeing the cards can happen before they have been dealt.
    final dealing = dealKey != null;
    // The turn clock starts when the deal view lands; hide the countdowns
    // until the cards are down so the deal does not appear to eat into
    // anyone's time. Test stubs are never mid-deal and keep their clocks.
    final isReal =
        session is RemoteSession ||
        session is LocalSession ||
        session is LanHostSession;
    final clockDeadline = (dealing && isReal) ? null : session.turnDeadline;
    final hidden = flights.keys.toSet();

    return Stack(
      key: tableStackKey,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            m.sc(12, 7),
            m.sc(8, 4),
            m.sc(12, 7),
            m.sc(14, 4),
          ),
          child: Column(
            children: [
              if (m.isPortrait) ...[
                _Hud(
                  view: view,
                  onTapRoundPill: onToggleRoundHistory,
                  onTapSettings: onOpenSettings,
                ),
                SizedBox(height: m.sc(6, 4)),
              ] else
                // Clears the floating HUD.
                SizedBox(height: m.s(34)),
              Expanded(
                child: _Felt(
                  view: view,
                  palette: palette,
                  seatKeys: seatKeys,
                  feltStackKey: feltStackKey,
                  throwOrigins: throwOrigins,
                  hiddenIds: hidden,
                  settledIds: flownIds,
                  turnDeadline: clockDeadline,
                  dealing: dealing,
                  dealProgress: dealProgress,
                ),
              ),
              SizedBox(height: m.sc(4, 0)),
              _HandArea(
                view: view,
                seatKeys: seatKeys,
                onCardThrown: onCardThrown,
                onIllegal: onIllegal,
                onNotYourTurn: onNotYourTurn,
                hint: hint,
                dealing: dealing,
                dealProgress: dealProgress,
                hiddenIds: hidden,
                turnDeadline: clockDeadline,
                onHandSlotsMeasured: onHandSlotsMeasured,
              ),
            ],
          ),
        ),
        // Local throws in flight, above both the felt and the hand.
        for (final flight in flights.values)
          _ThrowFlight(
            key: ValueKey(flight.card.id),
            flight: flight,
            tableStackKey: tableStackKey,
            onLanded: onFlightLanded,
          ),
        // The dealing flourish, above the felt, hand and seats.
        if (dealKey != null)
          _DealOverlay(
            key: dealKey,
            view: view,
            seatKeys: seatKeys,
            feltStackKey: feltStackKey,
            tableStackKey: tableStackKey,
            handSlots: handSlots,
            onDone: onDealComplete,
            onProgress: onDealProgress,
          ),
        // In landscape the HUD floats over the felt so the table can run to
        // the top edge; portrait keeps it in flow above the table.
        if (!m.isPortrait)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Padding(
              padding: EdgeInsets.fromLTRB(m.s(14), m.s(10), m.s(14), 0),
              child: _Hud(
                view: view,
                onTapRoundPill: onToggleRoundHistory,
                onTapSettings: onOpenSettings,
              ),
            ),
          ),
        if (view.phase == GamePhase.bidding &&
            view.isMyTurn &&
            !view.iHaveBid &&
            !dealing)
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: m.s(320)),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: m.s(16)),
                child: PopIn(
                  child: BidPanel(
                    hand: view.hand,
                    onBid: session.placeBid,
                    deadline: session.turnDeadline,
                  ),
                ),
              ),
            ),
          ),
        if (view.phase == GamePhase.handOver)
          _Overlay(
            child: Scoreboard(
              view: view,
              onContinue: session.continueToNextHand,
              deadline: session.handAdvanceDeadline,
            ),
          ),
        if (view.phase == GamePhase.gameOver)
          WinnerScreen(
            view: view,
            onPlayAgain: onPlayAgain,
            onHome: () =>
                Navigator.of(context).popUntil((route) => route.isFirst),
          ),
        if (showRoundHistory)
          RoundHistoryOverlay(view: view, onClose: onToggleRoundHistory),
      ],
    );
  }
}

/// Shows the "quit game?" confirmation and resolves to `true` if the player
/// chose to leave. Callers are responsible for actually popping the route.
Future<bool> _confirmQuit(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierColor: const Color(0x8C000000),
    barrierDismissible: false,
    builder: (context) => const ConfirmDialog(
      title: 'Quit game?',
      message: 'Your progress in this round will be lost.',
      confirmLabel: 'Quit',
      cancelLabel: 'Cancel',
      icon: Icons.logout_rounded,
    ),
  );
  return confirmed ?? false;
}

class _Overlay extends StatelessWidget {
  const _Overlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Positioned.fill(
      child: ColoredBox(
        color: AppColors.scrim,
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: m.s(360)),
            child: Padding(
              padding: EdgeInsets.all(m.sc(20, 12)),
              child: PopIn(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------- hud

/// The debug "Go offline" / "Back online" button for a networked table.
/// Only ever shown once debug mode is armed — see [AppSettings.debugMode].
class _GoOfflinePill extends StatelessWidget {
  const _GoOfflinePill({required this.offline, required this.onTap});

  final bool offline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return GlassPill(
      radius: m.sc(16, 12),
      padding: EdgeInsets.symmetric(
        horizontal: m.sc(10, 8),
        vertical: m.sc(8, 5),
      ),
      border: offline
          ? AppColors.success.withValues(alpha: 0.7)
          : AppColors.hairlineStrong,
      background: offline
          ? AppColors.success.withValues(alpha: 0.18)
          : AppColors.panelSoft,
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            offline ? Icons.cloud_done_rounded : Icons.wifi_off_rounded,
            size: m.sc(14, 12),
            color: offline ? AppColors.success : AppColors.textOnDark,
          ),
          SizedBox(width: m.s(5)),
          Text(
            offline ? 'Back online' : 'Go offline',
            style: AppText.semiBold(
              m.sc(12, 11),
              offline ? AppColors.success : AppColors.textOnDark,
            ),
          ),
        ],
      ),
    );
  }
}

class _Hud extends StatelessWidget {
  const _Hud({
    required this.view,
    required this.onTapRoundPill,
    required this.onTapSettings,
  });

  final GameView view;
  final VoidCallback onTapRoundPill;
  final VoidCallback onTapSettings;

  String? get _progress => switch (view.phase) {
    GamePhase.bidding => 'Bidding',
    GamePhase.playing => 'Trick ${math.min(view.trickNumber + 1, 13)} of 13',
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final progress = _progress;

    return Row(
      children: [
        _HudButton(
          icon: Icons.arrow_back_rounded,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        SizedBox(width: m.s(8)),
        _HudButton(icon: Icons.tune_rounded, onTap: onTapSettings),
        SizedBox(width: m.s(8)),
        // Scales down rather than overflowing on the narrowest phones.
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Spades are always trump — said once, quietly, where it can be
                  // checked at a glance.
                  GlassPill(
                    radius: m.sc(14, 13),
                    padding: EdgeInsets.symmetric(
                      horizontal: m.sc(10, 10),
                      vertical: m.sc(7, 7),
                    ),
                    border: AppColors.goldBorder.withValues(alpha: 0.3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SuitGlyph(
                          suit: Suit.spades,
                          size: m.sc(14, 14),
                          color: AppColors.gold,
                        ),
                        SizedBox(width: m.s(5)),
                        Text(
                          'Trump',
                          style: AppText.semiBold(m.sc(11, 11), AppColors.gold),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: m.s(8)),
                  GlassPill(
                    radius: m.sc(14, 13),
                    padding: EdgeInsets.symmetric(
                      horizontal: m.sc(12, 14),
                      vertical: m.sc(
                        progress == null ? 9 : 5,
                        progress == null ? 9 : 5,
                      ),
                    ),
                    border: AppColors.goldBorder.withValues(alpha: 0.45),
                    onTap: onTapRoundPill,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              'Round ${view.handNumber} / ${view.handsPerGame}',
                              style: AppText.bold(m.sc(12, 12), AppColors.gold),
                            ),
                            if (progress != null)
                              Text(
                                progress,
                                style: AppText.medium(
                                  m.sc(10, 10),
                                  AppColors.textMuted,
                                ),
                              ),
                          ],
                        ),
                        SizedBox(width: m.s(4)),
                        Icon(
                          Icons.leaderboard_rounded,
                          size: m.sc(15, 15),
                          color: AppColors.gold.withValues(alpha: 0.8),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HudButton extends StatelessWidget {
  const _HudButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    return GlassPill(
      radius: m.sc(14, 13),
      padding: EdgeInsets.all(m.sc(9, 9)),
      border: AppColors.hairlineStrong,
      onTap: onTap,
      child: Icon(icon, size: m.sc(18, 18), color: AppColors.textOnDark),
    );
  }
}

// -------------------------------------------------------------------- felt

/// How far [seatKey]'s centre sits from [feltKey]'s centre, after layout, or
/// null when either hasn't been laid out yet (callers fall back).
Offset? _measureSeatAnchor(GlobalKey seatKey, GlobalKey feltKey) {
  final seatBox = seatKey.currentContext?.findRenderObject();
  final feltBox = feltKey.currentContext?.findRenderObject();
  if (seatBox is! RenderBox || feltBox is! RenderBox) return null;
  if (!seatBox.attached ||
      !feltBox.attached ||
      !seatBox.hasSize ||
      !feltBox.hasSize) {
    return null;
  }
  final seatCenterGlobal = seatBox.localToGlobal(
    seatBox.size.center(Offset.zero),
  );
  final feltCenterGlobal = feltBox.localToGlobal(
    feltBox.size.center(Offset.zero),
  );
  return seatCenterGlobal - feltCenterGlobal;
}

/// Converts a screen position into the felt-centred space of
/// [_measureSeatAnchor]. Null without a position or before layout.
Offset? _feltRelativeOffset(Offset? globalPosition, GlobalKey feltKey) {
  if (globalPosition == null) return null;
  final feltBox = feltKey.currentContext?.findRenderObject();
  if (feltBox is! RenderBox || !feltBox.attached || !feltBox.hasSize) {
    return null;
  }
  final feltCenterGlobal = feltBox.localToGlobal(
    feltBox.size.center(Offset.zero),
  );
  return globalPosition - feltCenterGlobal;
}

/// The table's long axis relative to its short one — the same shape in both
/// orientations, only turned to suit the screen.
const _feltAspect = 1.62;

// Landscape's placement within its box, as fractions of the box's height. It
// runs past the bottom by [_feltOverhang] so its rim tucks behind the hand.
const _feltTopInset = 0.04;
const _feltBottomInset = _feltTopInset * (1 - 0.33);
const _feltOverhang = 0.12;
const _feltHeightFactor = 1 + _feltOverhang - _feltTopInset - _feltBottomInset;

/// The table's size, and its top edge's distance from its box's top edge.
/// Portrait stands the oval on end (long axis from the top seat down to the
/// player's own); landscape lays it on its side.
({double width, double height, double top}) _feltGeometry(
  BoxConstraints c,
  bool isPortrait,
) {
  if (isPortrait) {
    final height = math.min(
      c.maxHeight * 0.86,
      c.maxWidth * 0.86 * _feltAspect,
    );
    return (
      width: height / _feltAspect,
      height: height,
      top: (c.maxHeight - height) / 2,
    );
  }
  return (
    width: c.maxWidth * 0.6,
    height: c.maxHeight * _feltHeightFactor,
    top: c.maxHeight * _feltTopInset,
  );
}

/// How far the table's visual centre sits below its box's centre. Thrown
/// cards rest on this offset so they read as mid-table.
double _feltCenterBias(Size box, bool isPortrait) {
  final felt = _feltGeometry(
    BoxConstraints(maxWidth: box.width, maxHeight: box.height),
    isPortrait,
  );
  return felt.top + felt.height / 2 - box.height / 2;
}

class _Felt extends StatelessWidget {
  const _Felt({
    required this.view,
    required this.palette,
    required this.seatKeys,
    required this.feltStackKey,
    required this.throwOrigins,
    required this.hiddenIds,
    required this.settledIds,
    required this.turnDeadline,
    required this.dealing,
    required this.dealProgress,
  });

  final GameView view;
  final ThemePalette palette;
  final Map<SeatSlot, GlobalKey> seatKeys;
  final GlobalKey feltStackKey;
  final Map<String, Offset> throwOrigins;
  final Set<String> hiddenIds;
  final Set<String> settledIds;
  final DateTime? turnDeadline;
  final bool dealing;
  final ValueListenable<List<int>?> dealProgress;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final trickCards = view.awaitingTrickClear
        ? view.lastTrick!.plays
        : view.trick;
    final winner = view.awaitingTrickClear ? view.lastTrick!.winner : null;
    final waitingOn =
        !dealing &&
            view.turn != null &&
            !view.awaitingTrickClear &&
            (view.phase == GamePhase.bidding || view.phase == GamePhase.playing)
        ? slotFor(seat: view.turn!, viewer: view.you)
        : null;
    final leadSuit = !view.awaitingTrickClear && view.trick.isNotEmpty
        ? view.trick.first.card.suit
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final cardWidth = trickCardWidth(m, constraints.biggest);
        final felt = _feltGeometry(constraints, m.isPortrait);
        // Side seats are measured in from the box edge so they track the
        // table's rim.
        final feltInsetH = math.max(
          0.0,
          (constraints.maxWidth - felt.width) / 2,
        );
        final seatOverlap = m.sc(16, 12);
        final seatInsetH = (feltInsetH - seatOverlap).clamp(0.0, feltInsetH);

        // Real measured seat anchors relative to this stack's centre (the
        // origin TrickCluster's offsets use). Unmeasured slots fall back.
        final seatAnchors = <SeatSlot, Offset>{
          for (final slot in SeatSlot.values)
            slot: ?_measureSeatAnchor(seatKeys[slot]!, feltStackKey),
        };
        final restBias = Offset(
          0,
          _feltCenterBias(constraints.biggest, m.isPortrait),
        );

        return Stack(
          key: feltStackKey,
          alignment: Alignment.center,
          // Thrown cards travel in from well outside this box; Clip.none keeps
          // the whole path visible.
          clipBehavior: Clip.none,
          children: [
            // Reports constraints.biggest as its size whatever the table
            // measures, so the anchors measured off this stack never move;
            // excess spills past the box (under the hand) instead.
            OverflowBox(
              alignment: Alignment.topCenter,
              minWidth: 0,
              minHeight: 0,
              maxWidth: felt.width,
              maxHeight: felt.top + felt.height,
              child: Padding(
                padding: EdgeInsets.only(top: felt.top),
                child: SizedBox(
                  width: felt.width,
                  height: felt.height,
                  child: FeltSurface(
                    palette: palette,
                    spotlight: waitingOn,
                    leadSuit: leadSuit,
                  ),
                ),
              ),
            ),
            TrickCluster(
              plays: trickCards,
              viewer: view.you,
              cardWidth: cardWidth,
              winner: winner,
              seatAnchors: seatAnchors,
              throwOrigins: throwOrigins,
              hiddenIds: hiddenIds,
              settledIds: settledIds,
              restBias: restBias,
            ),
            for (final seat in [0, 1, 2, 3])
              _SeatAt(
                view: view,
                seat: seat,
                seatKeys: seatKeys,
                horizontalInset: seatInsetH,
                feltTopEdge: felt.top,
                turnDeadline: turnDeadline,
                dealProgress: dealProgress,
              ),
          ],
        );
      },
    );
  }
}

class _SeatAt extends StatelessWidget {
  const _SeatAt({
    required this.view,
    required this.seat,
    required this.seatKeys,
    required this.horizontalInset,
    required this.feltTopEdge,
    required this.turnDeadline,
    required this.dealProgress,
  });

  final GameView view;
  final int seat;
  final Map<SeatSlot, GlobalKey> seatKeys;
  final double horizontalInset;
  final DateTime? turnDeadline;

  /// Distance from the stack's top edge down to the table's real top edge —
  /// where the top seat straddles the rim.
  final double feltTopEdge;

  /// Cards dealt per seat so far, while dealing; the face-down fan grows
  /// card by card. Only this seat rebuilds as it ticks.
  final ValueListenable<List<int>?> dealProgress;

  @override
  Widget build(BuildContext context) {
    final slot = slotFor(seat: seat, viewer: view.you);
    if (slot == SeatSlot.bottom) return const SizedBox.shrink();
    final palette = SettingsScope.of(context).palette;

    final seatView = ValueListenableBuilder<List<int>?>(
      valueListenable: dealProgress,
      builder: (context, dealt, _) => SeatView(
        key: seatKeys[slot],
        player: view.players[seat],
        slot: slot,
        palette: palette,
        bid: view.bids[seat],
        tricksWon: view.tricksWon[seat],
        isTurn: view.turn == seat,
        isDealer: view.dealer == seat,
        isHost: view.hostSeat == seat,
        deadline: view.turn == seat ? turnDeadline : null,
        handCount: dealt != null && seat < dealt.length
            ? dealt[seat]
            : (seat < view.handCounts.length ? view.handCounts[seat] : null),
      ),
    );

    return switch (slot) {
      // Anchored at the table's top edge and pulled up by half its own height,
      // so it straddles the rim.
      SeatSlot.top => Positioned(
        top: feltTopEdge,
        child: FractionalTranslation(
          translation: const Offset(0, -0.5),
          child: seatView,
        ),
      ),
      SeatSlot.left => Positioned(left: horizontalInset, child: seatView),
      SeatSlot.right => Positioned(right: horizontalInset, child: seatView),
      SeatSlot.bottom => const SizedBox.shrink(),
    };
  }
}

// ---------------------------------------------------------------- hand area

class _HandArea extends StatelessWidget {
  const _HandArea({
    required this.view,
    required this.seatKeys,
    required this.onCardThrown,
    required this.onIllegal,
    required this.onNotYourTurn,
    required this.hint,
    required this.dealing,
    required this.dealProgress,
    required this.hiddenIds,
    required this.turnDeadline,
    required this.onHandSlotsMeasured,
  });

  final GameView view;
  final Map<SeatSlot, GlobalKey> seatKeys;
  final void Function(PlayingCard card, ThrowRelease? release) onCardThrown;
  final ValueChanged<PlayingCard> onIllegal;
  final VoidCallback onNotYourTurn;
  final _HandHint? hint;

  /// True while the hand is still being dealt — the fan stays inert.
  final bool dealing;

  /// Cards dealt per seat so far; the hand reveals card by card from it.
  final ValueListenable<List<int>?> dealProgress;

  /// Thrown cards awaiting confirmation, kept out of the fan.
  final Set<String> hiddenIds;

  /// When the seat on the clock runs out; nulled while dealing.
  final DateTime? turnDeadline;

  final ValueChanged<Map<String, FanSlot>> onHandSlotsMeasured;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final you = view.you;
    final interactive =
        !dealing && view.phase == GamePhase.playing && view.isMyTurn;

    final fan = ValueListenableBuilder<List<int>?>(
      valueListenable: dealProgress,
      builder: (context, dealt, _) {
        final revealed = !dealing
            ? null
            : (dealt != null && you != null && you < dealt.length
                  ? dealt[you]
                  : 0);
        return HandFan(
          cards: view.hand,
          revealedCount: revealed,
          hiddenIds: hiddenIds,
          legalIds: view.legalMoveIds,
          interactive: interactive,
          gesturesEnabled: !dealing,
          cardWidth: _handCardWidth(m),
          onPlay: onCardThrown,
          onIllegal: onIllegal,
          onNotYourTurn: onNotYourTurn,
          onSlotsMeasured: onHandSlotsMeasured,
        );
      },
    );

    final plate = you == null
        ? null
        : SeatView(
            key: seatKeys[SeatSlot.bottom],
            player: view.players[you],
            slot: SeatSlot.bottom,
            palette: SettingsScope.of(context).palette,
            bid: view.bids[you],
            tricksWon: view.tricksWon[you],
            isTurn: view.turn == you,
            isDealer: view.dealer == you,
            isHost: view.hostSeat == you,
            deadline: view.turn == you ? turnDeadline : null,
            axis: m.isPortrait ? Axis.horizontal : Axis.vertical,
          );

    final shownHint = hint ?? (interactive ? const _HandHint.yourTurn() : null);
    final hintLine = IgnorePointer(child: _HintLine(hint: shownHint));

    if (m.isPortrait) {
      // The player's own plate sits between the table and the hand, never on
      // top of the cards.
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              plate ?? SizedBox(height: m.s(40)),
              Positioned(top: -m.s(40), child: hintLine),
            ],
          ),
          SizedBox(height: m.s(2)),
          fan,
        ],
      );
    }

    // Landscape has width to spare and no height: the plate stands at the
    // left edge, level with the hand.
    final side = m.s(104);
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: side),
          child: fan,
        ),
        if (plate != null) Positioned(left: 0, bottom: m.s(2), child: plate),
        Positioned(top: -m.s(30), child: hintLine),
      ],
    );
  }
}

enum _HintTone { turn, refused, info }

/// One line of help above the hand: whose move it is, or why a card was
/// refused ("Follow suit — play a heart").
class _HandHint {
  const _HandHint._(this.text, this.tone, {this.suit, this.icon});

  const _HandHint.yourTurn()
    : text = 'Your turn',
      tone = _HintTone.turn,
      suit = null,
      icon = Icons.touch_app_rounded;

  const _HandHint.waiting()
    : text = 'Wait for your turn',
      tone = _HintTone.info,
      suit = null,
      icon = Icons.hourglass_top_rounded;

  /// Explains, from the rules, why [card] cannot be played into the trick.
  factory _HandHint.illegal(GameView view, PlayingCard card) {
    const fallback = _HandHint._(
      "That card can't be played right now",
      _HintTone.refused,
      icon: Icons.block_rounded,
    );
    final trick = view.trick;
    if (trick.isEmpty) return fallback;
    final led = trick.first.card.suit;
    final hand = view.hand;
    if (hand.any((c) => c.suit == led)) {
      if (card.suit != led) {
        return _HandHint._(
          'Follow suit — play a ${_one(led)}',
          _HintTone.refused,
          suit: led,
        );
      }
      return _HandHint._(
        'Beat the trick — play a higher ${_one(led)}',
        _HintTone.refused,
        suit: led,
      );
    }
    if (hand.any((c) => c.isTrump)) {
      final trumped = trick.any((p) => p.card.isTrump);
      return _HandHint._(
        trumped
            ? 'Overtrump — play a higher spade'
            : 'No ${_one(led)}s left — you must play a spade',
        _HintTone.refused,
        suit: Suit.spades,
      );
    }
    return fallback;
  }

  final String text;
  final _HintTone tone;
  final Suit? suit;
  final IconData? icon;

  static String _one(Suit s) => switch (s) {
    Suit.spades => 'spade',
    Suit.hearts => 'heart',
    Suit.diamonds => 'diamond',
    Suit.clubs => 'club',
  };
}

class _HintLine extends StatelessWidget {
  const _HintLine({required this.hint});

  final _HandHint? hint;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final h = hint;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      switchInCurve: Curves.easeOutBack,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween(begin: 0.85, end: 1.0).animate(a),
          child: child,
        ),
      ),
      child: h == null ? const SizedBox.shrink() : _pill(m, h),
    );
  }

  Widget _pill(Metrics m, _HandHint h) {
    final turn = h.tone == _HintTone.turn;
    final refused = h.tone == _HintTone.refused;
    final fg = turn
        ? AppColors.onGold
        : (refused ? const Color(0xFFFFB4AC) : AppColors.textOnDark);
    return Container(
      key: ValueKey(h.text),
      padding: EdgeInsets.symmetric(horizontal: m.s(12), vertical: m.s(6)),
      decoration: BoxDecoration(
        gradient: turn ? goldButtonGradient : surfaceGradient,
        borderRadius: BorderRadius.circular(m.s(20)),
        border: Border.all(
          color: turn
              ? const Color(0x66FFF6D8)
              : refused
              ? AppColors.danger.withValues(alpha: 0.7)
              : AppColors.hairlineStrong,
        ),
        boxShadow: turn
            ? AppShadows.glow(AppColors.goldDeep, strength: 0.9)
            : AppShadows.low,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (h.suit != null)
            SuitGlyph(
              suit: h.suit!,
              size: m.s(13),
              color: h.suit!.isRed
                  ? const Color(0xFFFF8A7E)
                  : AppColors.textPrimary,
            )
          else if (h.icon != null)
            Icon(h.icon, size: m.s(14), color: fg),
          SizedBox(width: m.s(6)),
          Text(h.text, style: AppText.bold(m.s(12), fg)),
        ],
      ),
    );
  }
}
