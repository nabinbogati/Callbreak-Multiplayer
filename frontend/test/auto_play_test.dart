import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/engine/card.dart';
import 'package:callbreak/engine/game.dart';
import 'package:callbreak/engine/rules.dart';
import 'package:callbreak/net/session.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/ui/screens/table_screen.dart';

/// A session the test drives by hand: the table auto-throws against this stub,
/// and every play it makes is recorded so the tests can assert on it.
class _RecordingSession extends GameSession {
  _RecordingSession(this._view);

  GameView _view;
  final _events = StreamController<GameEvent>.broadcast();
  final List<PlayingCard> played = [];

  @override
  GameView? get view => _view;

  @override
  SessionStatus get status => SessionStatus.ready;

  @override
  String? get errorMessage => null;

  @override
  GameMode get mode => GameMode.bots;

  @override
  Stream<GameEvent> get events => _events.stream;

  @override
  void placeBid(int bid) {}

  @override
  void play(PlayingCard card) {
    played.add(card);
  }

  @override
  void continueToNextHand() {}

  @override
  void restart() {}

  void update(GameView view) {
    _view = view;
    notifyListeners();
  }

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}

Future<void> _pumpTable(WidgetTester tester, _RecordingSession session) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    SettingsScope(
      settings: AppSettings(),
      child: MaterialApp(home: TableScreen(session: session)),
    ),
  );
  await tester.pump();
}

/// A playing-phase view from seat 0's own perspective: [hand], [trick], and
/// [legalMoveIds] computed from the real rules so the auto-throw only ever sees
/// the same legal cards a genuine engine view would carry.
GameView _view({
  required List<PlayingCard> hand,
  required List<TrickPlay> trick,
  bool autoplay = false,
}) {
  return GameView(
    phase: GamePhase.playing,
    handIndex: 0,
    handsPerGame: handsPerGame,
    dealer: 3,
    turn: 0,
    players: [
      PlayerInfo(seat: 0, name: 'You', kind: PlayerKind.human, autoplay: autoplay),
      const PlayerInfo(seat: 1, name: 'Bina', kind: PlayerKind.bot),
      const PlayerInfo(seat: 2, name: 'Kamal', kind: PlayerKind.bot),
      const PlayerInfo(seat: 3, name: 'Sita', kind: PlayerKind.bot),
    ],
    you: 0,
    hand: hand,
    legalMoveIds: legalMoves(hand, trick).map((c) => c.id).toSet(),
    handCounts: [hand.length, 13, 13, 13],
    bids: [3, 3, 3, 3],
    tricksWon: [0, 0, 0, 0],
    trick: trick,
    trickNumber: 1,
    awaitingTrickClear: false,
    lastTrick: null,
    roundScores: const [[], [], [], []],
    totals: const [0, 0, 0, 0],
    rankings: const [],
  );
}

/// A heart led, and the trick it creates.
const _heartLead = TrickPlay(1, PlayingCard(9, Suit.hearts));
const _heartsLed = [_heartLead];

void main() {
  testWidgets('the last card is thrown automatically the moment it is the turn', (
    tester,
  ) async {
    final session = _RecordingSession(
      _view(hand: const [PlayingCard(3, Suit.clubs)], trick: _heartsLed),
    );
    await _pumpTable(tester, session);

    session.update(_view(hand: const [PlayingCard(3, Suit.clubs)], trick: _heartsLed));
    // One beat for the scheduled throw to fire.
    await tester.pump(const Duration(milliseconds: 600));

    expect(session.played, [const PlayingCard(3, Suit.clubs)]);

    // The auto-throw now flies in via a top-level flight layer; let its
    // removal timer elapse so the test doesn't end with a pending timer.
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('the only card of the led suit is thrown when following is forced', (
    tester,
  ) async {
    final hand = [const PlayingCard(2, Suit.hearts), const PlayingCard(3, Suit.clubs)];
    final session = _RecordingSession(_view(hand: hand, trick: _heartsLed));
    await _pumpTable(tester, session);

    session.update(_view(hand: hand, trick: _heartsLed));
    await tester.pump(const Duration(milliseconds: 600));

    expect(
      session.played,
      [const PlayingCard(2, Suit.hearts)],
      reason: 'the sole heart must go, the club stays',
    );

    // Let the auto-throw's flight removal timer elapse (see the test above).
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('leading with a singleton is a choice and is not auto-thrown', (
    tester,
  ) async {
    final hand = [const PlayingCard(2, Suit.hearts), const PlayingCard(3, Suit.clubs)];
    final session = _RecordingSession(_view(hand: hand, trick: const []));
    await _pumpTable(tester, session);

    session.update(_view(hand: hand, trick: const []));
    await tester.pump(const Duration(milliseconds: 600));

    expect(session.played, isEmpty, reason: 'the player is deciding what to lead');
  });

  testWidgets('two cards of the led suit is not forced, so nothing auto-throws', (
    tester,
  ) async {
    final hand = [
      const PlayingCard(2, Suit.hearts),
      const PlayingCard(5, Suit.hearts),
      const PlayingCard(3, Suit.clubs),
    ];
    final session = _RecordingSession(_view(hand: hand, trick: _heartsLed));
    await _pumpTable(tester, session);

    session.update(_view(hand: hand, trick: _heartsLed));
    await tester.pump(const Duration(milliseconds: 600));

    expect(session.played, isEmpty, reason: 'which heart to play is still a decision');
  });

  testWidgets('turning the setting off leaves the last card to the player', (
    tester,
  ) async {
    final settings = AppSettings()..autoThrowLastCard = false;
    final session = _RecordingSession(
      _view(hand: const [PlayingCard(3, Suit.clubs)], trick: _heartsLed),
    );

    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      SettingsScope(
        settings: settings,
        child: MaterialApp(home: TableScreen(session: session)),
      ),
    );
    await tester.pump();
    session.update(_view(hand: const [PlayingCard(3, Suit.clubs)], trick: _heartsLed));
    await tester.pump(const Duration(milliseconds: 600));

    expect(session.played, isEmpty);
  });

  testWidgets('an autoplay play of the player seat flies above the hand', (tester) async {
    final session = _RecordingSession(
      _view(
        hand: const [PlayingCard(3, Suit.clubs), PlayingCard(4, Suit.clubs)],
        trick: const [],
        autoplay: true,
      ),
    );
    await _pumpTable(tester, session);

    Finder throwFlight() => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ThrowFlight',
    );

    // Publish the initial (empty-trick) view, as a real session does before
    // any plays, so the rejoin snapshot sees nothing to skip.
    session.update(
      _view(
        hand: const [PlayingCard(3, Suit.clubs), PlayingCard(4, Suit.clubs)],
        trick: const [],
        autoplay: true,
      ),
    );
    await tester.pump();

    // The seat is on autoplay, so the server plays a card: it lands in the
    // view's trick with no gesture on this device.
    session.update(
      _view(
        hand: const [PlayingCard(4, Suit.clubs)],
        trick: const [TrickPlay(0, PlayingCard(3, Suit.clubs))],
        autoplay: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(
      throwFlight(),
      findsOneWidget,
      reason: 'an autoplay play must render via the top-level flight layer',
    );

    // Let the flight finish so no removal timer is left pending.
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 600));
  });
}