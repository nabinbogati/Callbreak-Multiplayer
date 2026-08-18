import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/engine/card.dart';
import 'package:callbreak/engine/game.dart';
import 'package:callbreak/engine/rules.dart';
import 'package:callbreak/net/session.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/ui/screens/settings_sheet.dart';
import 'package:callbreak/ui/screens/table_screen.dart';

/// A ready table with no network plumbing — the plain bots-style session.
class _PlainSession extends GameSession {
  @override
  GameView? get view => _tablePlayerView();

  @override
  SessionStatus get status => SessionStatus.ready;

  @override
  String? get errorMessage => null;

  @override
  GameMode get mode => GameMode.bots;

  @override
  Stream<GameEvent> get events => const Stream.empty();

  @override
  void placeBid(int bid) {}

  @override
  void play(PlayingCard card) {}

  @override
  void continueToNextHand() {}

  @override
  void restart() {}
}

/// A networked table the test can toggle offline on and off.
class _NetworkStub extends NetworkSession {
  bool simulatedOffline = false;

  @override
  GameView? get view => _tablePlayerView();

  @override
  SessionStatus get status => SessionStatus.ready;

  @override
  String? get errorMessage => null;

  @override
  GameMode get mode => GameMode.online;

  @override
  Stream<GameEvent> get events => const Stream.empty();

  @override
  LobbyState? get lobby => null;

  @override
  int? get countdown => null;

  @override
  bool get isResuming => false;

  @override
  bool get canResume => false;

  @override
  Duration? get seatHeldFor => null;

  @override
  bool get isSimulatedOffline => simulatedOffline;

  @override
  void leaveLobby() {}

  @override
  void retryNow() {}

  @override
  void startGame() {}

  @override
  void simulateOffline(bool offline) {
    simulatedOffline = offline;
    notifyListeners();
  }

  @override
  void placeBid(int bid) {}

  @override
  void play(PlayingCard card) {}

  @override
  void continueToNextHand() {}

  @override
  void restart() {}
}

/// A playing-phase view from seat 0 so the table renders its HUD and hand.
GameView _tablePlayerView() {
  return GameView(
    phase: GamePhase.playing,
    handIndex: 0,
    handsPerGame: handsPerGame,
    dealer: 3,
    turn: 1,
    players: const [
      PlayerInfo(seat: 0, name: 'You', kind: PlayerKind.human),
      PlayerInfo(seat: 1, name: 'Bot 1', kind: PlayerKind.bot),
      PlayerInfo(seat: 2, name: 'Bot 2', kind: PlayerKind.bot),
      PlayerInfo(seat: 3, name: 'Bot 3', kind: PlayerKind.bot),
    ],
    you: 0,
    hand: const [PlayingCard(2, Suit.hearts), PlayingCard(3, Suit.clubs)],
    legalMoveIds: const {},
    handCounts: const [2, 13, 13, 13],
    bids: const [3, 3, 3, 3],
    tricksWon: const [0, 0, 0, 0],
    trick: const [],
    trickNumber: 1,
    awaitingTrickClear: false,
    lastTrick: null,
    roundScores: const [[], [], [], []],
    totals: const [0, 0, 0, 0],
    rankings: const [],
  );
}

Future<void> _pumpTable(WidgetTester tester, GameSession session, {bool debugMode = false}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);

  final settings = AppSettings()..debugMode = debugMode;
  await tester.pumpWidget(
    SettingsScope(
      settings: settings,
      child: MaterialApp(home: TableScreen(session: session)),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the HUD gear opens the panel with the gameplay and sound toggles', (
    tester,
  ) async {
    await _pumpTable(tester, _PlainSession());

    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Drag to play'), findsOneWidget);
    expect(find.text('Auto throw last card'), findsOneWidget);
    expect(find.text('Auto throw last suit card'), findsOneWidget);
    expect(find.text('Background music'), findsOneWidget);
    expect(find.text('Sound effects'), findsOneWidget);
    // Debug tooling is not offered from the table; it stays in the home
    // settings sheet's Debug tab.
    expect(find.text('Debug mode'), findsNothing);
    expect(find.text('Go offline'), findsNothing);
  });

  testWidgets('tapping outside the panel dismisses it', (tester) async {
    await _pumpTable(tester, _PlainSession());

    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Drag to play'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('Drag to play'), findsNothing);
  });

  testWidgets('tapping inside the panel keeps it open', (tester) async {
    await _pumpTable(tester, _PlainSession());

    await tester.tap(find.byIcon(Icons.tune_rounded));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Drag to play'));
    await tester.pumpAndSettle();

    expect(find.text('Drag to play'), findsOneWidget);
  });

  testWidgets('a networked table in debug mode gets a clickable Go offline button', (
    tester,
  ) async {
    final network = _NetworkStub();
    await _pumpTable(tester, network, debugMode: true);

    expect(find.text('Go offline'), findsOneWidget);

    await tester.tap(find.text('Go offline'));
    await tester.pumpAndSettle();

    expect(network.simulatedOffline, isTrue);
    expect(find.text('Back online'), findsOneWidget);
    expect(find.text('Go offline'), findsNothing);

    await tester.tap(find.text('Back online'));
    await tester.pumpAndSettle();

    expect(network.simulatedOffline, isFalse);
    expect(find.text('Go offline'), findsOneWidget);
  });

  testWidgets('the Go offline button stays hidden until debug mode is armed', (
    tester,
  ) async {
    final network = _NetworkStub();
    await _pumpTable(tester, network);

    expect(find.text('Go offline'), findsNothing);

    // Arming happens from the home settings sheet's Debug tab; once armed, the
    // table reveals the button on its next build.
    SettingsScope.of(tester.element(find.byType(TableScreen))).debugMode = true;
    await tester.pump();

    expect(find.text('Go offline'), findsOneWidget);
  });

  testWidgets('the home settings sheet trips Debug mode from its Developer section', (
    tester,
  ) async {
    final settings = AppSettings();
    await tester.pumpWidget(
      SettingsScope(
        settings: settings,
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showSettingsSheet(context),
                  child: const Text('open settings'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open settings'));
    await tester.pumpAndSettle();

    // Profile is the default tab; the Developer section lives under Debug.
    expect(find.text('Debug'), findsOneWidget);
    expect(find.text('Debug mode'), findsNothing);

    await tester.tap(find.text('Debug'));
    await tester.pumpAndSettle();

    expect(find.text('Debug mode'), findsOneWidget);
    expect(find.text('Shows a "Go offline" button on networked tables.'), findsOneWidget);

    await tester.tap(find.text('On').last);
    await tester.pumpAndSettle();

    expect(settings.debugMode, isTrue);
  });
}