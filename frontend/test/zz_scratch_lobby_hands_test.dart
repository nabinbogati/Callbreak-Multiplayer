import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/engine/card.dart';
import 'package:callbreak/engine/game.dart';
import 'package:callbreak/net/session.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/ui/screens/settings_sheet.dart';
import 'package:callbreak/ui/screens/table_screen.dart';

class _PrivateLobbyStub extends NetworkSession {
  _PrivateLobbyStub({required this.hands, this.host = true});

  int hands;
  final bool host;
  final List<int> sent = [];

  @override
  GameView? get view => null;

  @override
  SessionStatus get status => SessionStatus.ready;

  @override
  String? get errorMessage => null;

  @override
  GameMode get mode => GameMode.private;

  @override
  Stream<GameEvent> get events => const Stream.empty();

  @override
  LobbyState? get lobby => LobbyState(
    roomCode: '7QF2',
    isOnline: false,
    seats: const [
      LobbySeat(
        seat: 0,
        name: 'You',
        isBot: false,
        connected: true,
        isYou: true,
        isHost: true,
      ),
      LobbySeat(
        seat: 1,
        name: 'Riya',
        isBot: false,
        connected: true,
        isYou: false,
        isHost: false,
      ),
    ],
    isHost: host,
    canStart: host,
    humansSeated: 2,
    minPlayers: 2,
    handsPerGame: hands,
  );

  @override
  int? get countdown => null;

  @override
  bool get isResuming => false;

  @override
  bool get canResume => false;

  @override
  Duration? get seatHeldFor => null;

  @override
  void leaveLobby() {}

  @override
  void retryNow() {}

  @override
  void startGame() {}

  @override
  void setHandsPerGame(int value) {
    sent.add(value);
    // Stand in for the server echo: the room accepts the change and the new
    // lobby frame arrives.
    hands = value;
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

Future<void> _pump(WidgetTester tester, GameSession session) async {
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

void main() {
  testWidgets('host switches the private lobby between the two lengths', (
    tester,
  ) async {
    final session = _PrivateLobbyStub(hands: 3);
    await _pump(tester, session);

    expect(find.text('Quickplay'), findsOneWidget);
    expect(find.text('Normal Play'), findsOneWidget);

    await tester.tap(find.text('Normal Play'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(session.sent, [5]);

    await tester.tap(find.text('Quickplay'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(session.sent, [5, 3]);
  });

  testWidgets('a guest sees the length read-only', (tester) async {
    final session = _PrivateLobbyStub(hands: 3, host: false);
    await _pump(tester, session);

    expect(find.text('Quickplay · 3 hands'), findsOneWidget);
  });
}
