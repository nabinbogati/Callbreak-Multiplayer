import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/engine/card.dart';
import 'package:callbreak/engine/game.dart';
import 'package:callbreak/net/session.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/ui/screens/table_screen.dart';
import 'package:callbreak/ui/widgets/deadline_bar.dart';

/// A session the test drives by hand, so the two panels can be put in front of
/// a clock that is about to run out without playing a real hand first.
class _StubSession extends GameSession {
  _StubSession(this._view, {this.turnDeadline, this.handAdvanceDeadline});

  final GameView _view;
  final _events = StreamController<GameEvent>.broadcast();

  @override
  final DateTime? turnDeadline;

  @override
  final DateTime? handAdvanceDeadline;

  @override
  GameView? get view => _view;

  @override
  SessionStatus get status => SessionStatus.ready;

  @override
  String? get errorMessage => null;

  @override
  GameMode get mode => GameMode.online;

  @override
  Stream<GameEvent> get events => _events.stream;

  @override
  void placeBid(int bid) {}

  @override
  void play(PlayingCard card) {}

  @override
  void continueToNextHand() {}

  @override
  void restart() {}

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}

/// A dealt hand seen from seat 0, forced into [phase] with seat 0 to act.
GameView _viewIn(GamePhase phase) {
  final game = CallBreakGame(
    players: const [
      PlayerInfo(seat: 0, name: 'You', kind: PlayerKind.human),
      PlayerInfo(seat: 1, name: 'Bina', kind: PlayerKind.human),
      PlayerInfo(seat: 2, name: 'Bot 2', kind: PlayerKind.bot),
      PlayerInfo(seat: 3, name: 'Bot 3', kind: PlayerKind.bot),
    ],
    seed: 7,
  )..start();

  // The engine deals to seat 1 first; these tests are about seat 0's panels.
  final json = game.viewFor(0).toJson()
    ..['turn'] = 0
    ..['phase'] = phase.name;
  return GameView.fromJson(json);
}

Future<void> _pumpTable(WidgetTester tester, GameSession session) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    SettingsScope(
      settings: AppSettings(),
      child: MaterialApp(home: TableScreen(session: session)),
    ),
  );
  // Never pumpAndSettle: the bar repeats its frame pump forever by design.
  await tester.pump();
}

void main() {
  testWidgets('the bid panel says when the table will bid for you', (tester) async {
    await _pumpTable(
      tester,
      _StubSession(
        _viewIn(GamePhase.bidding),
        // Not a round number, so a bar that rounded the wrong way would show 19.
        turnDeadline: clock.now().add(const Duration(milliseconds: 19500)),
      ),
    );

    expect(find.text('Bidding for you in 20s'), findsOneWidget);

    // The count runs down on its own, with nothing further from the table.
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Bidding for you in 15s'), findsOneWidget);
  });

  testWidgets('the scoreboard says when the next round is coming', (tester) async {
    await _pumpTable(
      tester,
      _StubSession(
        _viewIn(GamePhase.handOver),
        handAdvanceDeadline: clock.now().add(const Duration(milliseconds: 19500)),
      ),
    );

    expect(find.text('Next round in 20s'), findsOneWidget);

    await tester.pump(const Duration(seconds: 12));
    expect(find.text('Next round in 8s'), findsOneWidget);
  });

  testWidgets('a table that can afford to wait shows no clock at all', (tester) async {
    // An offline game against bots keeps neither deadline, and must not grow a
    // countdown telling a solo player to hurry up.
    await _pumpTable(tester, _StubSession(_viewIn(GamePhase.bidding)));
    expect(find.byType(DeadlineBar), findsNothing);

    await _pumpTable(tester, _StubSession(_viewIn(GamePhase.handOver)));
    expect(find.byType(DeadlineBar), findsNothing);
  });
}
