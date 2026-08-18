import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart'
    show kDebugMode, listEquals, debugPrint;
import 'package:flutter/material.dart';

import '../../audio/audio_controller.dart';
import '../../design/metrics.dart';
import '../../design/tokens.dart';
import '../../engine/card.dart';
import '../../engine/game.dart';
import '../../net/lan_host_session.dart' show LanHostSession;
import '../../net/local_session.dart' show LocalSession;
import '../../net/remote_session.dart' show kQuickplayRoom, RemoteSession;
import '../../net/session.dart';
import '../../state/active_game_binding.dart' show wireActiveGamePersistence;
import '../../state/app_settings.dart';
import '../widgets/backdrop.dart';
import '../widgets/bid_panel.dart';
import '../widgets/felt_table.dart';
import '../widgets/hand_fan.dart';
import '../widgets/playing_card_view.dart';
import '../widgets/pulse_ripple.dart';
import '../widgets/quick_settings_panel.dart';
import '../widgets/round_history.dart';
import '../widgets/scoreboard.dart';
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

class _TableScreenState extends State<TableScreen> {
  bool _showRoundHistory = false;

  /// Game-event subscription for table sounds (a card lands, a trick is won).
  /// Fired from the session's event stream so it covers local throws, bots and
  /// remote plays alike.
  StreamSubscription<GameEvent>? _eventsSub;

  // Persist for the whole screen's lifetime (not recreated on every build)
  // so the GlobalKeys stay attached to the same seat/hand widgets across
  // rebuilds — TrickCluster measures real on-screen positions through these.
  final Map<SeatSlot, GlobalKey> _seatKeys = {
    for (final slot in SeatSlot.values) slot: GlobalKey(),
  };
  final GlobalKey _feltStackKey = GlobalKey();

  /// Key for the outer table Stack (built in [_TableBody]) — the flight
  /// layer positions itself relative to this, since (unlike the felt or the
  /// hand) it's a common ancestor of both and painted last, on top of both.
  final GlobalKey _tableStackKey = GlobalKey();

  /// Where this client's own thrown cards should start their arc, keyed by
  /// [PlayingCard.id] and expressed relative to the felt's centre (the same
  /// origin [TrickCluster.seatAnchors] already uses). Populated the moment a
  /// card leaves the hand — see [_handleCardThrown] — so the throw reads as
  /// coming from wherever the gesture actually released it rather than from
  /// the seat avatar. Pruned as tricks clear so it never grows unbounded.
  final Map<String, Offset> _throwOrigins = {};

  /// This client's own thrown cards still mid-entrance, keyed by
  /// [PlayingCard.id]. A local throw starts right next to (or under) the
  /// remaining hand, and the felt is painted before the hand in the widget
  /// tree — so [TrickCluster]'s own copy of the card would render *behind*
  /// the hand for that first stretch. Instead it's kept invisible
  /// ([TrickCluster.hiddenIds]) and a [_ThrowFlight] renders the entrance in
  /// the outer table Stack instead, which paints above everything. Entries
  /// remove themselves once that entrance finishes — see [_handleCardThrown].
  final Map<String, _Flight> _flights = {};

  /// Viewer-seat plays already on the table when this table first observed a
  /// trick — a rejoin lands mid-hand and must not re-fly those cards. Set on
  /// the first [_maybeStartAutoplayFlight], pruned alongside throw origins
  /// once the trick clears.
  Set<String>? _seenViewerPlayIds;

  /// Cached from the most recent build's [MetricsScope] — [_handleCardThrown]
  /// fires from a gesture callback, outside any build, and needs it to
  /// reproduce [_Felt]'s own card-size formula for [_flightTargetGlobal].
  Metrics? _metrics;

  /// The last hand we saw the session deal, so [_onSessionChanged] can spot a
  /// brand-new hand and play the dealing flourish. Null until the first deal.
  int? _lastDealtHand;

  /// Whether this table was opened to reclaim a seat in a game already under
  /// way (the "Rejoin your game?" path), detected from the constructor-passed
  /// [RemoteSession.resumeToken] before any `joined` frame can reissue one.
  ///
  /// Consumed by the first deal attempt: only the hand that was already dealt
  /// while the app was away is skipped, so every hand (and game) after it still
  /// plays its dealing flourish. A rejoin that lands on a freshly dealt hand
  /// therefore only misses that one animation, never the ones that follow.
  late bool _rejoined;

  /// A key that changes every time a deal starts, so [_DealOverlay] re-runs its
  /// entrance for each new hand. Null while no deal is being animated.
  Key? _dealKey;

  /// How many of the local player's 13 cards the hand fan has revealed so far
  /// during the current deal. Starts at zero when a deal begins and climbs as
  /// each card is dealt, so the player's hand is never on screen whole before
  /// the dealing flourish, and instead fills in card-by-card in real time.
  /// Always 13 (the full hand) once the deal has finished or no deal is
  /// running.
  int _handRevealed = 13;

  /// How many cards each seat has been dealt so far during the current deal,
  /// by seat index. Non-null only while a deal runs — it starts at all-zero
  /// and climbs as each card lands, so the opponents' face-down fans fill in
  /// in real time; null once the deal finishes (seats then show their real
  /// [GameView.handCounts]).
  List<int>? _dealRevealed;

  /// Global centre of every resting card slot in the player's hand fan, as
  /// reported by [HandFan]. The dealing flourish uses these to land each
  /// flying card on the exact slot the real card will occupy rather than on
  /// the seat avatar. Null until the fan has been laid out at least once.
  List<Offset>? _handCardCenters;

  /// Slot centres of the hand fan as last laid out, aligned with
  /// [_handSlotIds] (the card ids that occupied them), tracked during play as
  /// well as dealing. Throw-less plays of the viewer's own seat (autoplay)
  /// start their top-level flight from the card's actual resting slot here,
  /// so they follow the same path a finger release would have taken.
  List<Offset>? _handSlotCenters;
  List<String>? _handSlotIds;

  void _onHandSlotsMeasured(List<Offset> centers) {
    final hand = widget.session.view?.hand;
    final ids = hand == null ? null : [for (final c in hand) c.id];
    if (ids == null) return;
    if (_dealKey != null) {
      // The dealing flourish needs these to land the player's own cards on
      // their exact slots; during the deal the fan is laid out for the full
      // hand, which is also a valid playing-time layout.
      if (listEquals(centers, _handCardCenters)) return;
      setState(() {
        _handCardCenters = centers;
        _handSlotCenters = centers;
        _handSlotIds = ids;
      });
      return;
    }
    // Outside a deal, only the throw-start tracking matters. Ignore reports
    // from an empty hand (scoreboard, lift) by comparing against what we
    // already have.
    if (listEquals(centers, _handSlotCenters)) return;
    setState(() {
      _handSlotCenters = centers;
      _handSlotIds = ids;
    });
  }

  /// The last-known global centre of [cardId]'s resting slot in the hand fan,
  /// or null if it wasn't in the most recently laid-out hand. Used to start
  /// throw-less flights (autoplay, client auto-throw) from where the card
  /// actually sat.
  Offset? _handSlotCenterFor(String cardId) {
    final ids = _handSlotIds;
    final centers = _handSlotCenters;
    if (ids == null || centers == null) return null;
    final index = ids.indexOf(cardId);
    if (index < 0 || index >= centers.length) return null;
    return centers[index];
  }

  /// The "someone dropped / someone is back" banner currently showing, if any.
  /// A player's connection changing is easy to miss on a seat avatar alone, so
  /// it is also announced once, briefly, where the eye already is.
  _PresenceNotice? _presenceNotice;
  Timer? _presenceTimer;

  void _toggleRoundHistory() =>
      setState(() => _showRoundHistory = !_showRoundHistory);

  /// Opens the compact gameplay/sound settings sheet over the table.
  void _openQuickSettings() {
    if (!mounted) return;
    unawaited(showQuickSettingsSheet(context));
  }

  /// The "Play again" button at game over.
  ///
  /// On a quickplay table this always means going back into matchmaking for a
  /// fresh set of opponents — never a same-table re-deal. A same-table rematch
  /// can only re-pit the player against whoever is left at the table, which is
  /// exactly what the matchmaker exists to avoid. Other modes have no
  /// matchmaking to return to, so they just re-deal the same seats.
  void _handlePlayAgain() {
    if (widget.session.mode == GameMode.online) {
      _startQuickplayRematch();
      return;
    }
    widget.session.restart();
  }

  /// Leaves this (stale) quickplay table and immediately re-enters
  /// matchmaking against the same server and hand count, so "Play again"
  /// never boils down to a solo game versus bots.
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
    // A real session may already have dealt by the time this screen builds — a
    // LocalSession publishes its first (bidding/playing) view from its own
    // constructor, before this listener exists — so if it has, start the
    // dealing flourish here rather than waiting for a notify. Otherwise the
    // full hand would sit on screen for a stretch and only then be covered by
    // the animation. Test stubs (plain GameSession/NetworkSession subclasses)
    // present an already-playable view on purpose and are left alone so they
    // don't get an unexpected dealing overlay.
    if (_isRealSession) {
      _maybeStartDeal();
    }
  }

  /// True for the concrete table sessions ([LocalSession], [RemoteSession],
  /// [LanHostSession]) as opposed to the plain [GameSession] stubs used in
  /// widget tests. Only those real sessions deal a hand and therefore warrant
  /// the dealing flourish; a stub hands the table a ready-made view instead.
  bool get _isRealSession =>
      widget.session is LocalSession ||
      widget.session is RemoteSession ||
      widget.session is LanHostSession;

  @override
  void dispose() {
    _autoPlayTimer?.cancel();
    _presenceTimer?.cancel();
    _eventsSub?.cancel();
    // Leaving mid-deal must not leave the deal loop playing to nobody.
    AudioController.instance?.stopDeal();
    widget.session.removeListener(_onSessionChanged);
    widget.session.dispose();
    super.dispose();
  }

  /// Turns discrete happenings into table sounds: a card hitting the felt and
  /// the winner taking the trick.
  void _onGameEvent(GameEvent event) {
    if (event is PresenceChanged) {
      _announce(_PresenceNotice.from(event), skipSeat: event.seat);
      return;
    }
    if (event is AutoplayChanged) {
      // Your own seat is not announced here: it gets the standing banner
      // instead, which stays up for as long as the condition does.
      _announce(_PresenceNotice.autoplay(event), skipSeat: event.seat);
      return;
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

  /// Whether [card] is a trump landing into a trick that a normal (non-trump)
  /// suit led — the "the lead suit no longer matters" moment that earns the
  /// trump flourish. A trick led with trumps is ordinary gameplay, so those
  /// plays keep just the plain card shot. Safe against a slightly-stale view:
  /// a trump can only ever read as "into a side suit" when the trick already
  /// had a non-trump lead in it.
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

  /// Shows a notice about somebody else's seat for a few seconds, then lets it
  /// fade.
  ///
  /// [skipSeat] suppresses news about the viewer's own seat: their own
  /// connection dropping is not something they can act on from here (the
  /// reconnect overlay covers it), and their own autoplay has a standing banner
  /// that says what to do about it.
  void _announce(_PresenceNotice notice, {required int skipSeat}) {
    if (widget.session.view?.you == skipSeat) return;
    // Over the winner screen a seat notice has nothing useful to say — the
    // game is over, there is no seat action left to announce.
    if (widget.session.view?.phase == GamePhase.gameOver) return;

    _presenceTimer?.cancel();
    setState(() => _presenceNotice = notice);
    _presenceTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _presenceNotice = null);
    });
  }

  /// Any touch anywhere is proof the player is still at the table, so it takes
  /// their seat back from autoplay.
  ///
  /// This is a [Listener] rather than a gesture recogniser on purpose: it must
  /// not compete in the gesture arena with the card fan underneath it, and a
  /// pointer-down is the earliest and most forgiving signal of "someone is
  /// there" — it does not require the touch to resolve into a tap.
  void _handleTouch(PointerDownEvent _) {
    final view = widget.session.view;
    final you = view?.you;
    if (view == null || you == null) return;
    if (!view.players[you].autoplay) return;

    // One frame is enough; the seat is released the moment the server reads it.
    // Until that answer arrives the view still says autoplay, so a player
    // drumming on the screen out of frustration would keep sending — and the
    // server drops connections that exceed their frame budget. A floor between
    // sends keeps a burst of taps well inside it whatever the latency.
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
    // Spot server/bot plays of the viewer's own seat (autoplay) and give them
    // the same above-the-hand flight a local throw gets.
    _maybeStartAutoplayFlight();
    // If the game just ended while a notice was on screen, clear it so it does
    // not linger over the winner screen (the build also hides the banners
    // there, but an already-shown notice would otherwise keep its own timer).
    if (widget.session.view?.phase == GamePhase.gameOver) {
      _presenceTimer?.cancel();
      _presenceNotice = null;
    }
    _maybeStartDeal();
    setState(() {});
  }

  /// Spots a freshly dealt hand and kicks off the dealing flourish once.
  ///
  /// A view reaching the playing (or bidding) phase with a hand number we have
  /// not seen yet is the moment the cards were dealt. We only fire on the
  /// *first* such view for each hand (guarded by [_lastDealtHand]) so a
  /// reconnect re-sending the same hand — or the session notifying repeatedly
  /// about an unchanged view — cannot replay the animation.
  ///
  /// Sets the deal state fields directly rather than calling setState, because
  /// it is also invoked from [initState] before the first build (a session that
  /// has already dealt publishes from its constructor, so the flourish must
  /// start immediately or the full hand would flash on screen first). Callers
  /// that run after a build are responsible for their own setState.
  void _maybeStartDeal() {
    final view = widget.session.view;
    if (view == null) {
      debugPrint('[DEAL] _maybeStartDeal: view is null');
      return;
    }
    if (view.phase != GamePhase.bidding && view.phase != GamePhase.playing) {
      debugPrint(
        '[DEAL] _maybeStartDeal: phase=${view.phase}, not bidding/playing',
      );
      return;
    }
    if (_lastDealtHand == view.handIndex) {
      debugPrint(
        '[DEAL] _maybeStartDeal: SKIP _lastDealtHand=$_lastDealtHand == handIndex=${view.handIndex}',
      );
      return;
    }
    debugPrint(
      '[DEAL] _maybeStartDeal: STARTING DEAL _lastDealtHand=$_lastDealtHand -> handIndex=${view.handIndex}, phase=${view.phase}',
    );
    _lastDealtHand = view.handIndex;
    // A rejoin picks up a hand that may already be under way — replaying the
    // flourish over live cards would be noise. But only skip it if there is
    // actually progress (a bid placed or a card played): a rejoin that lands
    // on a just-dealt hand still gets its deal, and the flag is consumed so
    // every later hand and game plays its flourish too.
    if (_rejoined) {
      _rejoined = false;
      final handInProgress =
          view.phase == GamePhase.playing || view.bids.any((b) => b != null);
      if (handInProgress) {
        debugPrint(
          '[DEAL] _maybeStartDeal: rejoined an in-progress hand, skipping its deal',
        );
        return;
      }
      debugPrint(
        '[DEAL] _maybeStartDeal: rejoined a fresh hand, playing its deal',
      );
    }
    _handRevealed = 0;
    _dealRevealed = [0, 0, 0, 0];
    _dealKey = UniqueKey();
    _handCardCenters = null;
    AudioController.instance?.playDeal();
  }

  /// Clears the dealing flourish once its cards have all landed.
  void _clearDeal() {
    if (_dealKey == null) return;
    setState(() {
      _dealKey = null;
      // The whole hand is now revealed and stands on its own.
      _handRevealed = 13;
      _dealRevealed = null;
    });
    // The cards are down; the deal's looping sound has nothing left to keep
    // time with.
    AudioController.instance?.stopDeal();
    // The hand is now on screen, so a convenience auto-throw that was deferred
    // while the cards were hidden can be scheduled again.
    _maybeAutoPlay();
  }

  /// The card the table should throw for the player right now, or null.
  ///
  /// Two convenience rules, both all-but-forced so no real choice is skipped:
  /// 1. the player's very last card — with one card left every play is legal;
  /// 2. the only remaining card of the led suit — following suit is forced.
  /// Both are played through [_handleCardThrown] with no gesture position, so
  /// the card still arcs in above the hand instead of rendering its entrance
  /// underneath the remaining hand cards.
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
  ///
  /// The key is kept until the view shows the throw actually gone, so a slow
  /// network re-notifying the same view can't schedule it twice. It is cleared
  /// the moment the turn moves on or the card leaves the hand.
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
      // Thrown with no gesture position: [.._handleCardThrown] starts the
      // flight from the player's own seat anchor so the card still arcs in
      // above the hand instead of rendering its entrance underneath it.
      _handleCardThrown(card, null);
    });
  }

  /// Drops any recorded origin for a card that's no longer part of the
  /// in-progress trick or the one currently lingering before it's cleared —
  /// otherwise a card id (there are only 52) could resurface in a later hand
  /// and briefly reuse a stale screen position from a previous throw. Also
  /// prunes the rejoin snapshot so a later hand's plays of the same card ids
  /// aren't suppressed.
  void _pruneThrowOrigins() {
    if (_throwOrigins.isEmpty && _seenViewerPlayIds?.isEmpty != false) return;
    final view = widget.session.view;
    final liveIds = {
      if (view != null) ...view.trick.map((p) => p.card.id),
      if (view?.lastTrick != null)
        ...view!.lastTrick!.plays.map((p) => p.card.id),
    };
    _throwOrigins.removeWhere((id, _) => !liveIds.contains(id));
    _seenViewerPlayIds?.removeWhere((id) => !liveIds.contains(id));
  }

  /// Handles a card leaving the hand (tap, drag-release, or an auto-throw):
  /// records where it left from, then forwards the play to the session exactly
  /// as before.
  void _handleCardThrown(PlayingCard card, Offset? releasePosition) {
    _startFlight(card, releasePosition);
    widget.session.play(card);
  }

  /// Spots plays of the viewer's own seat that arrive through the session with
  /// no gesture — the seat going on autoplay (idle/away) while the server or a
  /// bot plays it. Those cards would otherwise render their entrance inside
  /// the felt, underneath the hand. Run them through the same top-level flight
  /// layer, starting from the card's resting slot, so the z-order rule (stay
  /// above the hand until the destination) holds during autoplay too.
  void _maybeStartAutoplayFlight() {
    final view = widget.session.view;
    final you = view?.you;
    if (view == null || you == null) return;
    final plays = view.awaitingTrickClear
        ? view.lastTrick?.plays ?? const <TrickPlay>[]
        : view.trick;
    // First observation of a live trick: a rejoin landing mid-hand. Cards
    // already on the table must not re-fly, so snapshot them and skip forever
    // (pruned alongside throw origins once the trick clears).
    _seenViewerPlayIds ??= {
      for (final p in plays)
        if (p.seat == you) p.card.id,
    };
    for (final play in plays) {
      if (play.seat != you) continue;
      // Already on the table when we first looked (rejoin), thrown locally (a
      // throw origin was recorded), or a flight is already running.
      if (_seenViewerPlayIds!.contains(play.card.id)) continue;
      if (_throwOrigins.containsKey(play.card.id)) continue;
      if (_flights.containsKey(play.card.id)) continue;
      _startFlight(play.card, null);
    }
  }

  /// Starts the top-level flight that carries a locally-thrown card above the
  /// hand to its destination, and records the throw origin so the settled card
  /// [TrickCluster] reveals is where the flight landed. A null
  /// [releasePosition] (auto-throw, autoplay) falls back to the card's resting
  /// slot, then to the player's own seat anchor.
  void _startFlight(PlayingCard card, Offset? releasePosition) {
    final startGlobal =
        releasePosition ??
        _handSlotCenterFor(card.id) ??
        _ownSeatAnchorGlobal();
    final origin = _feltRelativeOffset(startGlobal, _feltStackKey);
    if (origin != null) {
      _throwOrigins[card.id] = origin;
    }
    final target = _flightTargetGlobal();
    if (startGlobal != null && target != null) {
      final flight = _Flight(
        card: card,
        startGlobal: startGlobal,
        targetGlobal: target.center,
        cardWidth: target.cardWidth,
      );
      setState(() => _flights[card.id] = flight);
      // Must match _ThrownCardState._entranceBaseMs in felt_table.dart —
      // TrickCluster's own copy of this card stays hidden for exactly this
      // long (see TrickCluster.hiddenIds), so it's already settled at rest
      // the instant the flight layer above removes itself.
      final scale = SettingsScope.of(context).animationSpeed.durationScale;
      Future.delayed(Duration(milliseconds: (520 * scale).round()), () {
        if (mounted) setState(() => _flights.remove(card.id));
      });
    }
  }

  /// The point (screen-global) and card size a locally-thrown card's flight
  /// should land on: reproduces [_Felt]'s own `cardWidth` clamp and
  /// [TrickCluster]'s bottom-seat rest offset (the 0.55 constant) off the
  /// felt's last measured size, so [_ThrowFlight] lands exactly where
  /// [TrickCluster] itself will settle the real card. Null before the felt
  /// has been laid out at least once.
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
    final cardWidth = m
        .s(44)
        .clamp(
          0.0,
          [
            size.width * 0.16,
            size.height * 0.3,
          ].reduce((a, b) => a < b ? a : b),
        );
    final cardHeight = cardWidth * PlayingCardView.aspect;
    final feltCenterGlobal = feltBox.localToGlobal(size.center(Offset.zero));
    final bias = _feltCenterBias(size, m.isPortrait);
    return (
      center: feltCenterGlobal + Offset(0, cardHeight * 0.55 + bias),
      cardWidth: cardWidth,
    );
  }

  /// The player's own seat avatar centre in screen-global coordinates — the
  /// fallback start for a thrown card's flight when there is no gesture to
  /// measure (auto-throws). Same anchor [TrickCluster] would use for the
  /// bottom seat, so the flight and the settled card agree.
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
      // An explicit quit forfeits the seat, so the seat record that would
      // otherwise offer a "Rejoin your game?" popup next time the home screen
      // opens must go with it. The session's own dispose never reaches the
      // active-game binding (it closes without notifying), so this is the only
      // place a deliberate quit can clear it.
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
    // `isResuming` only ever turns true with a view already in hand, so a
    // reconnect always has something to render beneath the overlay.
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
              glowAlignment: const Alignment(0, -0.6),
              glowScale: 1.4,
              child: SafeArea(
                // Extra buffer on top of the OS-reported safe inset: on
                // notched/cutout devices in landscape the reported padding
                // sometimes runs right up against the cutout with no
                // breathing room, so the felt and seat avatars end up
                // visually flush against it.
                minimum: EdgeInsets.symmetric(horizontal: m.sc(0, 8)),
                child: Listener(
                  // Wraps the whole table so a touch anywhere counts as a sign
                  // of life. Translucent so it also sees touches on bare felt,
                  // and a Listener so it never intercepts anything.
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
                                onCardThrown: _handleCardThrown,
                                dealKey: _dealKey,
                                handRevealed: _handRevealed,
                                dealRevealed: _dealRevealed,
                                onDealComplete: _clearDeal,
                                onDealProgress: (counts) {
                                  if (!mounted) return;
                                  final you = session.view?.you;
                                  final revealed =
                                      you != null && you < counts.length
                                      ? counts[you]
                                      : 0;
                                  if (revealed != _handRevealed ||
                                      !listEquals(counts, _dealRevealed)) {
                                    setState(() {
                                      _handRevealed = revealed;
                                      _dealRevealed = List.of(counts);
                                    });
                                  }
                                },
                                onHandSlotsMeasured: _onHandSlotsMeasured,
                                handCardCenters: _handCardCenters,
                              )
                            : _ConnectionState(session: session),
                      ),

                      // While a mid-game connection is being reclaimed the table
                      // stays visible behind a small centered card instead of a
                      // full-page spinner.
                      if (resuming && !session.isReady)
                        Positioned.fill(
                          child: _ReconnectOverlay(network: debugNetwork!),
                        ),

                      // The debug "Go offline" button, armed by the settings panel's Developer
                      // section. It floats at the top where the HUD has a clear
                      // gap between its icon pills and the round pill, so it
                      // never forces the HUD to overflow on a narrow screen.
                      // Only a live networked mid-game table has a connection
                      // worth severing.
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

                      // Announcements ride above the table rather than inside it,
                      // so they never disturb the felt's measured geometry — the
                      // card-flight code reads real on-screen positions from it.
                      // The winner screen takes the whole screen over at game
                      // over, so neither banner is useful there: "take your seat
                      // back" is meaningless once the game has ended, and a
                      // presence toast over the podium is just noise.
                      Positioned(
                        top: m.s(8),
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
/// Unlike the presence notices this does not time out, because the condition it
/// describes does not: it is up for exactly as long as the seat is on autoplay,
/// and it names the way out. Ignoring pointers is deliberate — the whole screen
/// is the button, so a banner that swallowed the touch would be the one place
/// tapping did not work.
class _AutoplayBanner extends StatelessWidget {
  const _AutoplayBanner({required this.showing});

  final bool showing;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      child: !showing
          ? const SizedBox.shrink()
          : Padding(
              padding: EdgeInsets.only(bottom: m.s(6)),
              child: Container(
                margin: EdgeInsets.symmetric(horizontal: m.s(16)),
                padding: EdgeInsets.symmetric(
                  horizontal: m.s(14),
                  vertical: m.s(9),
                ),
                decoration: BoxDecoration(
                  color: const Color(0xF00A1207),
                  border: Border.all(
                    color: AppColors.goldMid.withValues(alpha: 0.75),
                  ),
                  borderRadius: BorderRadius.circular(m.s(12)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x99000000),
                      blurRadius: 18,
                      offset: Offset(0, 5),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.smart_toy_outlined,
                      size: m.s(15),
                      color: AppColors.goldMid,
                    ),
                    SizedBox(width: m.s(9)),
                    Flexible(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Autoplay is on',
                            style: AppText.bold(m.s(12), AppColors.goldMid),
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

/// One local throw's flight, rendered by [_ThrowFlight] in the outer table
/// Stack while [TrickCluster]'s own copy of [card] stays hidden.
class _Flight {
  const _Flight({
    required this.card,
    required this.startGlobal,
    required this.targetGlobal,
    required this.cardWidth,
  });

  final PlayingCard card;
  final Offset startGlobal;
  final Offset targetGlobal;
  final double cardWidth;
}

/// Renders one [_Flight]'s entrance — a straight-line move from
/// [_Flight.startGlobal] to [_Flight.targetGlobal] — positioned in
/// [tableStackKey] (the outer table Stack)'s coordinate space rather than the
/// felt's, so it paints above both the felt and the hand regardless of which
/// one the path happens to cross. The card stays solid for the whole flight
/// (it was already visible in the hand when it was thrown), so the only
/// stacking change happens at the destination, where the settled card in
/// [TrickCluster] takes over. Removes itself (via the parent's [_Flight] map)
/// once the entrance finishes; see [_TableScreenState._handleCardThrown].
class _ThrowFlight extends StatefulWidget {
  const _ThrowFlight({
    super.key,
    required this.flight,
    required this.tableStackKey,
  });

  final _Flight flight;
  final GlobalKey tableStackKey;

  @override
  State<_ThrowFlight> createState() => _ThrowFlightState();
}

class _ThrowFlightState extends State<_ThrowFlight>
    with SingleTickerProviderStateMixin {
  // Must match _ThrownCardState._entranceBaseMs/curve in felt_table.dart —
  // this stands in for that card's own entrance while it stays hidden, so
  // the two need to move in lockstep.
  static const _entranceBaseMs = 520;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: _entranceBaseMs),
  );
  late final Animation<double> _entrance = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final scale = SettingsScope.of(context).animationSpeed.durationScale;
    _controller.duration = Duration(
      milliseconds: (_entranceBaseMs * scale).round(),
    );
    _controller.forward();
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
    final startLocal = tableBox.globalToLocal(flight.startGlobal);
    final targetLocal = tableBox.globalToLocal(flight.targetGlobal);
    final half = Offset(
      flight.cardWidth / 2,
      flight.cardWidth * PlayingCardView.aspect / 2,
    );
    return AnimatedBuilder(
      animation: _entrance,
      builder: (context, child) {
        final t = _entrance.value;
        final topLeft = Offset.lerp(startLocal, targetLocal, t)! - half;
        return Positioned(left: topLeft.dx, top: topLeft.dy, child: child!);
      },
      child: PlayingCardView(card: flight.card, width: flight.cardWidth),
    );
  }
}

// --------------------------------------------------------------- dealing

/// The global (screen) landing centre for a seat's dealt cards: the seat
/// avatar for the three opponents, and the local player's hand area below the
/// felt for their own flight. Falls back to an approximate reach toward that
/// seat's side of the table when the seat hasn't been laid out yet (the very
/// first frame).
Offset _dealTargetGlobal(SeatSlot slot, Map<SeatSlot, GlobalKey> seatKeys) {
  final box = seatKeys[slot]?.currentContext?.findRenderObject();
  if (box is RenderBox && box.attached && box.hasSize) {
    return box.localToGlobal(box.size.center(Offset.zero));
  }
  // Approximate reach when unmeasured; the overlay only exists for a few
  // hundred milliseconds, and the seat is almost always laid out by then.
  return switch (slot) {
    SeatSlot.bottom => Offset.zero,
    SeatSlot.left => Offset(-200, 0),
    SeatSlot.top => Offset(0, -200),
    SeatSlot.right => Offset(200, 0),
  };
}

/// The dealing flourish: a fan of face-down cards deals out from the centre
/// of the felt to all four seats, staggered so it reads as a real deal rather
/// than a burst. Painted in the outer table Stack's coordinate space (so it
/// sits above the felt, hand and seats), and re-keyed by the parent for each
/// new hand. Once every card has landed it fades out and reports completion,
/// at which point the real hand below stands alone.
class _DealOverlay extends StatefulWidget {
  const _DealOverlay({
    super.key,
    required this.view,
    required this.seatKeys,
    required this.feltStackKey,
    required this.tableStackKey,
    required this.handCardCenters,
    required this.onDone,
    required this.onProgress,
  });

  final GameView view;
  final Map<SeatSlot, GlobalKey> seatKeys;
  final GlobalKey feltStackKey;
  final GlobalKey tableStackKey;

  /// The player's hand fan's card-slot centres, in global coordinates — one
  /// per revealed slot in deal order. Flights for the player's own seat aim
  /// at these instead of the seat avatar, so each flying card lands exactly
  /// where the real card is being revealed underneath it. Null before the fan
  /// has been laid out, in which case the seat target is used.
  final List<Offset>? handCardCenters;

  /// Fired once the deal finishes, so the parent clears the overlay.
  final VoidCallback onDone;

  /// Fired as each card lands, with how many cards each seat has been dealt
  /// so far (indexed by seat), so every player's hand fills in card-by-card
  /// during the deal.
  final ValueChanged<List<int>> onProgress;

  @override
  State<_DealOverlay> createState() => _DealOverlayState();
}

class _DealOverlayState extends State<_DealOverlay>
    with SingleTickerProviderStateMixin {
  // One card landing every ~55ms, plus a short tail fade: the whole flourish
  // is comfortably under a second at normal animation speed.
  static const _cardGapMs = 55;
  static const _flightBaseMs = 420;
  static const _fadeBaseMs = 220;

  late final AnimationController _controller = AnimationController(vsync: this);

  double _scale = 1.0;
  bool _started = false;

  /// The order seats receive cards, exactly as laid out in [build]: starting
  /// just past the dealer, one card to each seat in turn, 13 rounds. Computed
  /// lazily so [._onDealTick] can count each seat's landed cards without
  /// re-deriving it.
  late final List<int> _order = [
    for (var round = 0; round < 13; round++)
      for (var d = 1; d <= 4; d++) (widget.view.dealer + d) % 4,
  ];

  List<int>? _lastReported;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Set the total controller window from the (possibly changed) animation
    // speed before starting, exactly like the other one-shot animations here.
    _scale = SettingsScope.of(context).animationSpeed.durationScale;
    final ms = (_cardGapMs * 52 + _flightBaseMs + _fadeBaseMs) * _scale;
    _controller.duration = Duration(milliseconds: ms.round());
    if (!_started) {
      _started = true;
      _controller.addListener(_onDealTick);
      _controller.forward().whenComplete(() {
        if (mounted) widget.onDone();
      });
    }
  }

  /// As each of the local player's own cards lands, reports the new reveal
  /// count so the real hand fills in in real time (a card every ~55ms).
  /// As each card lands, reports how many cards each seat has been dealt so
  /// far, so every player's hand — the local one and the opponents' fans —
  /// fills in in real time rather than all appearing at once.
  void _onDealTick() {
    final you = widget.view.you;
    if (you == null) return;
    final elapsed = _controller.value * _controller.duration!.inMilliseconds;

    final counts = [0, 0, 0, 0];
    for (var i = 0; i < _order.length; i++) {
      final end = (i * _cardGapMs + _flightBaseMs) * _scale;
      if (elapsed >= end) counts[_order[i]]++;
    }
    if (!listEquals(counts, _lastReported)) {
      _lastReported = List.of(counts);
      widget.onProgress(counts);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The real on-screen centre of the table felt, in the overlay's own
  /// (table Stack) coordinate space. This is where every card starts its
  /// flight. Returns null if the felt hasn't been laid out yet.
  Offset? _startLocal() {
    final tableBox = widget.tableStackKey.currentContext?.findRenderObject();
    if (tableBox is! RenderBox || !tableBox.attached || !tableBox.hasSize) {
      return null;
    }
    final feltBox = widget.feltStackKey.currentContext?.findRenderObject();
    if (feltBox is! RenderBox || !feltBox.attached || !feltBox.hasSize) {
      return tableBox.size.center(Offset.zero);
    }
    return tableBox.globalToLocal(
      feltBox.localToGlobal(feltBox.size.center(Offset.zero)),
    );
  }

  /// Converts a seat target's global centre into the overlay's coordinate
  /// space, falling back to the raw value before the table has laid out.
  Offset _targetLocal(SeatSlot slot) =>
      _tableLocal(_dealTargetGlobal(slot, widget.seatKeys));

  /// Converts a global point into the overlay's (table Stack) coordinate
  /// space, falling back to the raw value before the table has laid out.
  Offset _tableLocal(Offset global) {
    final tableBox = widget.tableStackKey.currentContext?.findRenderObject();
    if (tableBox is! RenderBox || !tableBox.attached || !tableBox.hasSize) {
      return global;
    }
    return tableBox.globalToLocal(global);
  }

  @override
  Widget build(BuildContext context) {
    final start = _startLocal();
    if (start == null) {
      // Felt not yet measured — keep trying next frame without replaying.
      return const SizedBox.shrink();
    }
    final palette = SettingsScope.of(context).palette;

    // Deal order: starting just past the dealer, one card to each seat in
    // turn, 13 rounds.
    final you = widget.view.you;
    final order = _order;

    // The player's own cards land on the exact slot they will occupy in the
    // hand fan (handCardCenters, in deal order), rather than on the seat
    // avatar, so the flight hands off cleanly to the real card being revealed
    // underneath it.
    final targets = <Offset>[];
    final endRotations = <double>[];
    var playerCardsSeen = 0;
    for (var i = 0; i < order.length; i++) {
      final slot = slotFor(seat: order[i], viewer: you);
      final centers = widget.handCardCenters;
      final isPlayer = slot == SeatSlot.bottom;
      if (isPlayer && centers != null && playerCardsSeen < centers.length) {
        targets.add(_tableLocal(centers[playerCardsSeen]));
      } else {
        targets.add(_targetLocal(slot));
      }
      if (isPlayer) playerCardsSeen++;
      // The card arrives already turned the way its seat's face-down fan holds
      // cards — upright at the top seat, sideways toward the table centre for
      // the side seats (matching [_handFanCards]); the player's own flight
      // stays upright as it turns over into the real hand.
      endRotations.add(switch (slot) {
        SeatSlot.top => 0.0,
        SeatSlot.left => -math.pi / 2,
        SeatSlot.right => math.pi / 2,
        SeatSlot.bottom => 0.0,
      });
    }

    return Positioned.fill(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // The deck at the table centre: a stack of face-down cards that
          // thins as each card flies out to its seat, instead of every card
          // lingering stacked on the same spot (which read as a static shadow).
          _DealDeck(
            start: start,
            controller: _controller,
            scale: _scale,
            cardSize: 44.0 * _scale,
            palette: palette,
          ),
          for (var i = 0; i < order.length; i++)
            Builder(
              key: ValueKey(i),
              builder: (context) {
                // Every seat gets the flight, the player's own included. The
                // card flies face-down from the centre to the hand, and the
                // real face-up card is revealed underneath the moment it lands
                // (see onProgress/_handRevealed) — the brief overlap as the
                // flight fades reads as the card turning over into the fan.
                // Skipping the bottom seat here left the player's own deal
                // invisible, showing only the other three seats' flights.
                return _DealtCard(
                  start: start,
                  target: targets[i],
                  endRotation: endRotations[i],
                  cardIndex: i,
                  controller: _controller,
                  scale: _scale,
                  palette: palette,
                );
              },
            ),
        ],
      ),
    );
  }
}

/// One face-down card in the dealing flourish. It waits in the deck at the
/// table centre (rendered by [_DealDeck]) until its turn, then flies in a
/// straight line to its seat and fades out, handing off to the real card
/// already waiting underneath.
class _DealtCard extends StatelessWidget {
  const _DealtCard({
    required this.start,
    required this.target,
    required this.endRotation,
    required this.cardIndex,
    required this.controller,
    required this.scale,
    required this.palette,
  });

  final Offset start;
  final Offset target;

  /// The rotation the card should finish its flight at, matching how its
  /// seat's face-down fan holds cards (upright at the top seat, sideways at
  /// the side seats, upright into the player's own hand).
  final double endRotation;
  final int cardIndex;
  final AnimationController controller;
  final double scale;
  final ThemePalette palette;

  @override
  Widget build(BuildContext context) {
    // Each card flies during its own [cardIndex]-sized window, after the
    // cards before it. Before that window it is part of the deck and is not
    // drawn here at all.
    final begin = cardIndex * _DealOverlayState._cardGapMs * scale;
    final end = begin + _DealOverlayState._flightBaseMs * scale;
    final fadeEnd = end + _DealOverlayState._fadeBaseMs * scale;

    final cardSize = 44.0 * scale;
    final half = Offset(cardSize / 2, cardSize * CardBackView.aspect / 2);

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final elapsed = controller.value * controller.duration!.inMilliseconds;
        if (elapsed < begin) {
          // Still in the deck — [_DealDeck] draws it.
          return const SizedBox.shrink();
        }
        if (elapsed >= fadeEnd) return const SizedBox.shrink();
        final t = ((elapsed - begin) / (end - begin)).clamp(0.0, 1.0);
        final pos = Offset.lerp(start, target, t)!;
        final opacity = elapsed < end
            ? 1.0
            : 1.0 - ((elapsed - end) / (fadeEnd - end)).clamp(0.0, 1.0);
        return Positioned(
          left: pos.dx - half.dx,
          top: pos.dy - half.dy,
          child: Opacity(
            opacity: opacity,
            child: Transform.rotate(
              // Start with a slight travel tilt (so the card reads as being
              // flipped off the deck) and turn toward the seat's resting
              // orientation as it lands, so a side-seat card arrives sideways.
              angle: endRotation * t + 0.2 * (1 - t),
              child: child,
            ),
          ),
        );
      },
      child: CardBackView(width: cardSize, palette: palette),
    );
  }
}

/// The deck of face-down cards sitting at the table centre during a deal. The
/// cards are dealt one at a time to the four seats, so the deck starts thick
/// and thins to nothing as the last card leaves.
class _DealDeck extends StatelessWidget {
  const _DealDeck({
    required this.start,
    required this.controller,
    required this.scale,
    required this.cardSize,
    required this.palette,
  });

  final Offset start;
  final AnimationController controller;
  final double scale;
  final double cardSize;
  final ThemePalette palette;

  /// The most offset layers worth drawing at once — a real deck this thick
  /// reads the same whether it holds fifty cards or a dozen.
  static const _maxLayers = 12;
  static const _layerStep = 2.0;
  static const _totalCards = 52;

  int _remaining() {
    final elapsed = controller.value * controller.duration!.inMilliseconds;
    var remaining = 0;
    for (var i = 0; i < _totalCards; i++) {
      final begin = i * _DealOverlayState._cardGapMs * scale;
      if (elapsed < begin) remaining++;
    }
    return remaining;
  }

  @override
  Widget build(BuildContext context) {
    final half = Offset(cardSize / 2, cardSize * CardBackView.aspect / 2);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final remaining = _remaining();
        if (remaining <= 0) return const SizedBox.shrink();
        // Deck thickness tracks how many cards are still in it, so it thins
        // in step with the deal.
        var layers = (remaining * _maxLayers) ~/ _totalCards;
        if (layers < 1) layers = 1;
        if (layers > _maxLayers) layers = _maxLayers;
        final edge = (layers - 1) * _layerStep;
        final width = cardSize + edge;
        final height = cardSize * CardBackView.aspect + edge;
        return Positioned(
          left: start.dx - half.dx,
          top: start.dy - half.dy,
          // A SizedBox keeps the deck's inner Stack on bounded constraints (a
          // Stack whose children are all Positioned has no intrinsic size).
          child: SizedBox(
            width: width,
            height: height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Painted back to front: the bottom layer is offset furthest,
                // the top card sits flat at the centre.
                for (var i = layers - 1; i >= 0; i--)
                  Positioned(
                    left: i * _layerStep,
                    top: i * _layerStep,
                    // Only the top card casts a shadow; the offset layers
                    // beneath are the deck's edge, not a shadow blob.
                    child: CardBackView(
                      width: cardSize,
                      palette: palette,
                      shadow: i == 0,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
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
                        child: _FailureButton(
                          label: 'Try again',
                          primary: true,
                          onTap: onRetry!,
                        ),
                      ),
                      SizedBox(width: m.s(10)),
                    ],
                    Expanded(
                      child: _FailureButton(label: 'Back', onTap: onBack),
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

/// One of the two choices on the "can't connect" screen. Primary is the gold
/// gradient of every main action; the secondary is the quiet panel of Back.
class _FailureButton extends StatelessWidget {
  const _FailureButton({
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return PressFeedback(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(vertical: m.s(13)),
        decoration: BoxDecoration(
          gradient: primary
              ? const LinearGradient(
                  colors: [AppColors.gold, AppColors.goldDeep],
                )
              : null,
          color: primary ? null : AppColors.panel,
          borderRadius: BorderRadius.circular(m.s(13)),
          border: primary ? null : Border.all(color: AppColors.hairlineStrong),
        ),
        child: Text(
          label,
          style: AppText.bold(
            m.s(13),
            primary ? AppColors.onGold : AppColors.textOnDark,
          ),
        ),
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
          child: Container(
            constraints: BoxConstraints(maxWidth: m.s(300)),
            padding: EdgeInsets.all(m.s(20)),
            decoration: BoxDecoration(
              color: AppColors.panel,
              borderRadius: BorderRadius.circular(m.s(18)),
              border: Border.all(color: AppColors.hairline),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x99000000),
                  blurRadius: 30,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: _ReconnectNotice(
              resuming: true,
              showBackOnline: showBackOnline,
              onBackOnline: () => network.simulateOffline(false),
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

    return PressFeedback(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: m.s(28), vertical: m.s(12)),
        decoration: BoxDecoration(
          gradient: primary
              ? const LinearGradient(
                  colors: [AppColors.gold, AppColors.goldDeep],
                )
              : null,
          border: primary
              ? null
              : Border.all(color: AppColors.textMuted.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(m.s(12)),
        ),
        child: Text(
          label,
          style: AppText.bold(
            m.s(13),
            primary ? AppColors.onGold : AppColors.textMuted,
          ),
        ),
      ),
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
    required this.onCardThrown,
    required this.dealKey,
    required this.handRevealed,
    required this.onDealComplete,
    required this.onDealProgress,
    required this.onHandSlotsMeasured,
    required this.handCardCenters,
    required this.dealRevealed,
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
  final void Function(PlayingCard card, Offset? releasePosition) onCardThrown;

  /// Non-null only while a new hand is being dealt. Re-keyed each deal so
  /// [_DealOverlay] replays its entrance; null clears it.
  final Key? dealKey;

  /// How many of the local player's cards are revealed so far (see
  /// [_TableScreenState._handRevealed]). Drives the real hand filling in
  /// card-by-card as the dealing flourish runs.
  final int handRevealed;

  /// Called by [_DealOverlay] once every card has landed, so the parent can
  /// clear [_TableBody.dealKey] and let the real cards stand alone.
  final VoidCallback onDealComplete;

  /// Called by [_DealOverlay] as each card lands, with how many cards each
  /// seat has been dealt so far, so every hand fills in in real time.
  final ValueChanged<List<int>> onDealProgress;

  /// Reports the global centre of every card's resting slot in the hand fan
  /// (forwarded out of [HandFan]), so [_DealOverlay] can aim the player's own
  /// flights at the exact slot each card will occupy.
  final ValueChanged<List<Offset>> onHandSlotsMeasured;

  /// The latest [HandFan] slot centres, in global coordinates. Forwarded into
  /// [_DealOverlay] so the player's flights land on the fan, not the seat.
  final List<Offset>? handCardCenters;

  /// How many cards each seat has been dealt so far in the current deal, by
  /// seat index. Non-null only while dealing, so opponents' face-down fans
  /// fill in card-by-card; null once the deal is done (seats then show their
  /// real [GameView.handCounts]).
  final List<int>? dealRevealed;

  @override
  Widget build(BuildContext context) {
    final view = session.view!;
    final m = Metrics.of(context);
    // The hand and bid UI stay hidden until the dealing flourish has finished,
    // so nothing that depends on seeing the cards (bidding, throwing) can
    // happen before this player has actually been dealt them.
    final dealing = dealKey != null;
    // The turn clock starts the moment the deal view lands, while the dealing
    // flourish is still running. Hide the countdowns until the cards are down
    // so the deal does not appear to eat into anyone's bid or play time.
    // Only real table sessions get the hide — plain GameSession stubs used in
    // widget tests are never in the middle of an actual deal and must keep
    // their clocks visible so widget tests on TurnClock still pass.
    final isReal =
        session is RemoteSession ||
        session is LocalSession ||
        session is LanHostSession;
    final clockDeadline = (dealing && isReal) ? null : session.turnDeadline;

    return Stack(
      key: tableStackKey,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            m.sc(14, 7),
            m.sc(8, 4),
            m.sc(14, 7),
            m.sc(10, 4),
          ),
          child: Column(
            children: [
              if (m.isPortrait) ...[
                _Hud(
                  view: view,
                  onTapRoundPill: onToggleRoundHistory,
                  onTapSettings: onOpenSettings,
                ),
                SizedBox(height: m.sc(8, 4)),
              ] else
                // Clears the floating HUD and shifts the felt itself down,
                // trading that space for a tighter gap to the hand below.
                SizedBox(height: m.s(34)),
              Expanded(
                child: _Felt(
                  view: view,
                  palette: palette,
                  seatKeys: seatKeys,
                  feltStackKey: feltStackKey,
                  throwOrigins: throwOrigins,
                  hiddenIds: flights.keys.toSet(),
                  turnDeadline: clockDeadline,
                  dealRevealed: dealRevealed,
                ),
              ),
              SizedBox(height: m.sc(10, 0)),
              _HandArea(
                view: view,
                seatKeys: seatKeys,
                onCardThrown: onCardThrown,
                dealing: dealing,
                revealed: handRevealed,
                turnDeadline: clockDeadline,
                onHandSlotsMeasured: onHandSlotsMeasured,
              ),
            ],
          ),
        ),
        // Local throws in flight: rendered here, above the Padding/Column
        // above (so above both the felt and the hand) rather than inside
        // the felt itself — see [_TableScreenState._flights].
        for (final flight in flights.values)
          _ThrowFlight(
            key: ValueKey(flight.card.id),
            flight: flight,
            tableStackKey: tableStackKey,
          ),
        // The dealing flourish, when a hand is being dealt. Painted above the
        // felt, hand and seats (and above any throw flights already finishing)
        // so the flying cards are never hidden behind a seat avatar.
        if (dealKey != null)
          _DealOverlay(
            key: dealKey,
            view: view,
            seatKeys: seatKeys,
            feltStackKey: feltStackKey,
            tableStackKey: tableStackKey,
            handCardCenters: handCardCenters,
            onDone: onDealComplete,
            onProgress: onDealProgress,
          ),
        // In landscape the HUD floats over the felt so the table can run to
        // the very top edge of the screen; portrait keeps it in flow above
        // the table.
        if (!m.isPortrait)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Padding(
              padding: EdgeInsets.fromLTRB(m.s(14), m.s(12), m.s(14), 0),
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
              constraints: BoxConstraints(maxWidth: m.s(300)),
              child: BidPanel(
                hand: view.hand,
                onBid: session.placeBid,
                deadline: session.turnDeadline,
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
    barrierColor: Colors.transparent,
    barrierDismissible: false,
    builder: (context) => const _QuitConfirmDialog(),
  );
  return confirmed ?? false;
}

class _QuitConfirmDialog extends StatelessWidget {
  const _QuitConfirmDialog();

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(horizontal: m.s(32)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: m.s(300)),
        child: Container(
          padding: EdgeInsets.all(m.s(20)),
          decoration: BoxDecoration(
            color: const Color(0xE604120D),
            borderRadius: BorderRadius.circular(m.s(18)),
            border: Border.all(
              color: AppColors.goldBorder.withValues(alpha: 0.35),
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x99000000),
                blurRadius: 30,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Quit game?',
                textAlign: TextAlign.center,
                style: AppText.bold(m.s(16), AppColors.textPrimary),
              ),
              SizedBox(height: m.s(8)),
              Text(
                'Your progress in this round will be lost.',
                textAlign: TextAlign.center,
                style: AppText.medium(m.s(13), AppColors.textMuted),
              ),
              SizedBox(height: m.s(20)),
              Row(
                children: [
                  Expanded(
                    child: PressFeedback(
                      onTap: () => Navigator.of(context).pop(false),
                      child: Container(
                        alignment: Alignment.center,
                        padding: EdgeInsets.symmetric(vertical: m.s(13)),
                        decoration: BoxDecoration(
                          color: AppColors.panel,
                          borderRadius: BorderRadius.circular(m.s(14)),
                          border: Border.all(color: AppColors.hairlineStrong),
                        ),
                        child: Text(
                          'Cancel',
                          style: AppText.semiBold(
                            m.s(13),
                            AppColors.textOnDark,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: m.s(12)),
                  Expanded(
                    child: PressFeedback(
                      onTap: () => Navigator.of(context).pop(true),
                      child: Container(
                        alignment: Alignment.center,
                        padding: EdgeInsets.symmetric(vertical: m.s(13)),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [AppColors.gold, AppColors.goldDeep],
                          ),
                          borderRadius: BorderRadius.circular(m.s(14)),
                        ),
                        child: Text(
                          'Quit',
                          style: AppText.bold(m.s(13), AppColors.onGold),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Overlay extends StatelessWidget {
  const _Overlay({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Positioned.fill(
      child: Container(
        color: const Color(0x99000000),
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: m.s(340)),
          child: Padding(padding: EdgeInsets.all(m.s(20)), child: child),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------------- hud

/// The debug "Go offline" / "Back online" button for a networked table.
///
/// A single click severs the live connection exactly like a real drop would
/// (or, when already simulating that, brings it straight back), which is what
/// makes it useful for driving the reconnection UI on demand. Only ever shown
/// once debug mode is armed — see [AppSettings.debugMode].
class _GoOfflinePill extends StatelessWidget {
  const _GoOfflinePill({required this.offline, required this.onTap});

  /// Whether this table is currently pretending to be disconnected; flips the
  /// label and accent.
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

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);

    return Row(
      children: [
        GlassPill(
          radius: m.sc(16, 15),
          padding: EdgeInsets.all(m.sc(8, 9)),
          border: AppColors.hairlineStrong,
          onTap: () => Navigator.of(context).maybePop(),
          child: Icon(
            Icons.arrow_back_rounded,
            size: m.sc(16, 19),
            color: AppColors.textOnDark,
          ),
        ),
        SizedBox(width: m.s(8)),
        GlassPill(
          radius: m.sc(16, 15),
          padding: EdgeInsets.all(m.sc(8, 9)),
          border: AppColors.hairlineStrong,
          onTap: onTapSettings,
          child: Icon(
            Icons.tune_rounded,
            size: m.sc(16, 19),
            color: AppColors.textOnDark,
          ),
        ),
        const Spacer(),
        GlassPill(
          radius: m.sc(16, 15),
          padding: EdgeInsets.symmetric(
            horizontal: m.sc(14, 16),
            vertical: m.sc(8, 9),
          ),
          border: AppColors.goldBorder.withValues(alpha: 0.35),
          onTap: onTapRoundPill,
          child: Text(
            'Round ${view.handNumber} / ${view.handsPerGame}',
            style: AppText.semiBold(m.sc(12, 13), AppColors.gold),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------- felt

/// Reads a [GlobalKey]'s [RenderBox] after layout to find how far its centre
/// sits from [feltKey]'s own centre, in the same logical-pixel units the
/// felt's internal (un-positioned, centre-aligned) offsets already use.
/// Returns `null` when either widget hasn't been laid out yet (e.g. the very
/// first frame) — callers should fall back to an approximate offset then.
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

/// Converts a screen (global) position — typically where a drag/tap gesture
/// released a card — into the same felt-centred coordinate space as
/// [_measureSeatAnchor], so it can stand in for a seat anchor as a throw's
/// start point. Returns null if there's no position to convert or the felt
/// hasn't been laid out yet.
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

/// The felt's long axis relative to its short one. It's the same oval in both
/// orientations — only turned to suit the screen, so the table reads alike
/// however the device is held.
const _feltAspect = 1.66;

// Landscape's placement within its box, as fractions of the box's height. It
// deliberately runs past the bottom by [_feltOverhang] so its rim disappears
// behind the hand fan rather than stopping short of it.
const _feltTopInset = 0.03;
const _feltBottomInset = _feltTopInset * (1 - 0.33);
const _feltOverhang = 0.14;
const _feltHeightFactor = 1 + _feltOverhang - _feltTopInset - _feltBottomInset;

/// The felt's size, and its top edge's distance from its box's top edge.
///
/// Landscape lays the oval on its side, long axis running left seat to right
/// seat. Portrait stands the same oval on end — a quarter turn — so the long
/// axis instead runs from the top seat down to the player's own, which is the
/// way a tall screen wants it. Either way the near end of the table is the
/// player's end.
({double width, double height, double top}) _feltGeometry(
  BoxConstraints c,
  bool isPortrait,
) {
  if (isPortrait) {
    // Height leads and width follows from the aspect, so the oval keeps its
    // shape; the second term only bites on a screen too narrow to stand the
    // full-height oval up in.
    final height = [
      c.maxHeight * 0.79,
      c.maxWidth * 0.94 * _feltAspect,
    ].reduce((a, b) => a < b ? a : b);
    return (
      width: height / _feltAspect,
      height: height,
      top: (c.maxHeight - height) / 2,
    );
  }
  return (
    width: c.maxWidth * 0.575,
    height: c.maxHeight * _feltHeightFactor,
    top: c.maxHeight * _feltTopInset,
  );
}

/// How far the felt's visual centre sits below its box's centre — positive
/// means down. Zero in portrait, where the felt is vertically centred in its
/// box; positive in landscape, where the felt is pushed down so its bottom
/// tucks under the player's hand. Thrown cards land on this offset, so the
/// resting diamond reads as mid-table rather than crowding the opposite seat.
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
    required this.turnDeadline,
    required this.dealRevealed,
  });

  final GameView view;
  final ThemePalette palette;
  final Map<SeatSlot, GlobalKey> seatKeys;
  final GlobalKey feltStackKey;
  final Map<String, Offset> throwOrigins;
  final Set<String> hiddenIds;

  /// When the seat on the clock runs out of time. Null when nobody is being
  /// waited on — a bot's turn, or an offline game.
  final DateTime? turnDeadline;

  /// How many cards each seat has been dealt so far during the current deal,
  /// by seat index. Non-null only while dealing, so opponents' face-down fans
  /// grow card-by-card in real time; null lets seats show their real counts.
  final List<int>? dealRevealed;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final trickCards = view.awaitingTrickClear
        ? view.lastTrick!.plays
        : view.trick;
    final winner = view.awaitingTrickClear ? view.lastTrick!.winner : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Clamp against height as well as width — in landscape the felt is
        // wide but short, and cards sized purely off width would overflow
        // the available height (and crowd the seats around it).
        final cardWidth = m
            .s(44)
            .clamp(
              0.0,
              [
                constraints.maxWidth * 0.16,
                constraints.maxHeight * 0.3,
              ].reduce((a, b) => a < b ? a : b),
            );
        final spread = (constraints.maxHeight * 0.19).clamp(
          0.0,
          constraints.maxWidth * 0.22,
        );

        // Felt geometry as an explicit size and placement rather than four
        // independent insets, so the two orientations can be compared — and
        // matched — directly. [top] is measured from the box's own top edge;
        // where top + height runs past the box, the felt paints beyond its
        // bottom and tucks under the hand fan (see the OverflowBox below),
        // and where width exceeds the box it bleeds off both side edges.
        final felt = _feltGeometry(constraints, m.isPortrait);
        // Left/right seats are measured in from the box edge, so they track
        // the felt's own rim — clamped at 0 for a felt wider than the box.
        final feltInsetH = ((constraints.maxWidth - felt.width) / 2).clamp(
          0.0,
          double.infinity,
        );
        final seatOverlap = m.sc(14, 10);
        final seatInsetH = (feltInsetH - seatOverlap).clamp(0.0, feltInsetH);

        // Real measured seat/hand anchors, relative to the felt stack's own
        // centre — this is the coordinate origin TrickCluster's internal
        // offsets are already relative to, since the Stack below centres its
        // un-positioned children. Slots not yet laid out (first frame or
        // two) are simply absent; TrickCluster falls back for those.
        final seatAnchors = <SeatSlot, Offset>{
          for (final slot in SeatSlot.values)
            slot: ?_measureSeatAnchor(seatKeys[slot]!, feltStackKey),
        };

        // In landscape the felt is pushed down so its bottom tucks under the
        // hand, leaving its visual centre below this stack's centre; bias the
        // thrown-card diamond down by that gap so cards land mid-table instead
        // of crowding the opposite seat.
        final restBias = Offset(
          0,
          _feltCenterBias(constraints.biggest, m.isPortrait),
        );

        return Stack(
          key: feltStackKey,
          alignment: Alignment.center,
          // A thrown card's flight starts down at the player's hand, well
          // below this stack's own box — with the default hardEdge clip
          // that portion is cut off until it crosses back inside, so the
          // card seems to pop into view partway through the throw instead
          // of visibly leaving the hand. Clip.none keeps the whole path
          // visible and continuous.
          clipBehavior: Clip.none,
          children: [
            // Reports constraints.biggest as its own size whatever the felt
            // measures, so this Stack's size and centre never move — seat
            // anchors, TrickCluster's origin and the card-throw flight target
            // are all measured off them. The felt itself is laid out at its
            // own size, top-aligned then pushed down by [felt.top], so any
            // excess spills past the box's bottom and side edges instead of
            // resizing anything. The Column paints the felt before the hand,
            // so a bottom spill lands under the player's cards, not over them.
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
                  child: FeltSurface(palette: palette),
                ),
              ),
            ),
            TrickCluster(
              plays: trickCards,
              viewer: view.you,
              cardWidth: cardWidth,
              spread: spread,
              winner: winner,
              seatAnchors: seatAnchors,
              throwOrigins: throwOrigins,
              hiddenIds: hiddenIds,
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
                dealRevealed: dealRevealed,
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
    required this.dealRevealed,
  });

  final GameView view;
  final int seat;
  final Map<SeatSlot, GlobalKey> seatKeys;
  final double horizontalInset;
  final DateTime? turnDeadline;

  /// Distance from the stack's own top edge down to the felt surface's real
  /// top edge — where the top seat's avatar should straddle, half above the
  /// rim and half over the felt.
  final double feltTopEdge;

  /// How many cards this seat has been dealt so far during the current deal,
  /// by seat index. Non-null only while dealing, so the face-down fan grows
  /// card-by-card; null lets the seat show its real [GameView.handCounts].
  final List<int>? dealRevealed;

  @override
  Widget build(BuildContext context) {
    final slot = slotFor(seat: seat, viewer: view.you);
    if (slot == SeatSlot.bottom) return const SizedBox.shrink();

    final seatView = SeatView(
      key: seatKeys[slot],
      player: view.players[seat],
      slot: slot,
      palette: SettingsScope.of(context).palette,
      bid: view.bids[seat],
      tricksWon: view.tricksWon[seat],
      isTurn: view.turn == seat,
      isDealer: view.dealer == seat,
      isHost: view.hostSeat == seat,
      deadline: view.turn == seat ? turnDeadline : null,
      handCount: dealRevealed != null && seat < dealRevealed!.length
          ? dealRevealed![seat]
          : (seat < view.handCounts.length ? view.handCounts[seat] : null),
    );

    return switch (slot) {
      // Anchored at the felt's actual top edge, then pulled up by exactly
      // half its own height so it straddles the rim — half sitting above
      // the felt, half over it — instead of resting low enough to overlap
      // the top seat's thrown card, which lands just beneath it.
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
    required this.dealing,
    required this.revealed,
    required this.turnDeadline,
    required this.onHandSlotsMeasured,
  });

  final GameView view;
  final Map<SeatSlot, GlobalKey> seatKeys;
  final void Function(PlayingCard card, Offset? releasePosition) onCardThrown;

  /// True while a new hand is still being dealt out. The dealt cards are not
  /// this player's to touch until the flourish has finished, so the fan stays
  /// inert during it; the felt and seat geometry also stay fixed.
  final bool dealing;

  /// How many of the player's cards are revealed so far, which while dealing
  /// grows from 0 to 13 so the hand fills in card-by-card in real time instead
  /// of appearing all at once.
  final int revealed;

  /// When the seat on the clock runs out. Nulled out while dealing so the
  /// flourish does not render a draining clock.
  final DateTime? turnDeadline;

  /// Reports the global centre of every card's resting slot in the fan, so the
  /// dealing flourish can land each flying card on the slot it will actually
  /// occupy rather than on the seat avatar. Forwarded from [HandFan].
  final ValueChanged<List<Offset>> onHandSlotsMeasured;

  @override
  Widget build(BuildContext context) {
    final m = Metrics.of(context);
    final you = view.you;
    final cardWidth = m.sc(54, 61);
    // Reveal the dealt cards progressively, but always anchor layout to the
    // full hand so the fan and the seats never shift as it fills in.
    final shown = dealing ? revealed : view.hand.length;

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        Padding(
          // Nudges the fan up so its cards clear the overlaid avatar/chips
          // instead of being hidden underneath them. Landscape bumped to
          // match the bigger landscape avatar size.
          padding: EdgeInsets.only(bottom: m.sc(30, 30)),
          child: HandFan(
            cards: view.hand,
            revealedCount: shown,
            legalIds: view.legalMoveIds,
            interactive:
                !dealing && view.phase == GamePhase.playing && view.isMyTurn,
            cardWidth: cardWidth,
            onPlay: onCardThrown,
            onSlotsMeasured: onHandSlotsMeasured,
          ),
        ),
        if (you != null)
          SeatView(
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
          ),
      ],
    );
  }
}
