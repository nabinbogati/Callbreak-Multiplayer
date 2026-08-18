import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/engine/card.dart';
import 'package:callbreak/engine/game.dart';
import 'package:callbreak/net/session.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/ui/screens/table_screen.dart';
import 'package:callbreak/ui/widgets/turn_clock.dart';

/// A session the test drives by hand, so the clock and the autoplay banner can
/// be put in states a real table only reaches after minutes of waiting.
class _StubSession extends GameSession {
  _StubSession(this._view);

  GameView _view;
  DateTime? _deadline;
  final _events = StreamController<GameEvent>.broadcast();

  /// How many times the table has told the server we are still here.
  int wakeCalls = 0;

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
  DateTime? get turnDeadline => _deadline;

  @override
  void wakeUp() => wakeCalls++;

  @override
  void placeBid(int bid) {}

  @override
  void play(PlayingCard card) {}

  @override
  void continueToNextHand() {}

  @override
  void restart() {}

  void update({GameView? view, DateTime? deadline, bool clearDeadline = false}) {
    if (view != null) _view = view;
    if (clearDeadline) {
      _deadline = null;
    } else if (deadline != null) {
      _deadline = deadline;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}

/// A dealt hand, viewed from seat 0, with seat 0 on the clock.
GameView _dealtView({bool youAreOnAutoplay = false}) {
  final game = CallBreakGame(
    players: const [
      PlayerInfo(seat: 0, name: 'You', kind: PlayerKind.human),
      PlayerInfo(seat: 1, name: 'Bina', kind: PlayerKind.human),
      PlayerInfo(seat: 2, name: 'Bot 2', kind: PlayerKind.bot),
      PlayerInfo(seat: 3, name: 'Bot 3', kind: PlayerKind.bot),
    ],
    seed: 7,
  )..start();

  final base = game.viewFor(0);
  // The engine deals to seat 1 first; the tests are about seat 0's clock.
  final json = base.toJson()..['turn'] = 0;
  if (youAreOnAutoplay) {
    final players = (json['players'] as List)
        .map((p) => Map<String, dynamic>.from(p as Map))
        .toList();
    players[0]['autoplay'] = true;
    json['players'] = players;
  }
  return GameView.fromJson(json);
}

Future<void> _pumpTable(WidgetTester tester, _StubSession session) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    SettingsScope(
      settings: AppSettings(),
      child: MaterialApp(home: TableScreen(session: session)),
    ),
  );
  // Never pumpAndSettle here: the clock repeats forever by design, so a settle
  // would spin until the test timed out.
  await tester.pump();
}

/// The seconds shown on the ring. Scoped to the clock because the table is
/// covered in small numbers — bids and tricks won — that would otherwise match.
Finder _count(String seconds) =>
    find.descendant(of: find.byType(TurnClock), matching: find.text(seconds));

void main() {
  testWidgets('the clock stays out of the way until time is genuinely short', (
    tester,
  ) async {
    final session = _StubSession(_dealtView());
    await _pumpTable(tester, session);

    // A whole minute left is not news.
    session.update(deadline: clock.now().add(const Duration(seconds: 60)));
    await tester.pump();
    expect(
      find.byType(TurnClock),
      findsOneWidget,
      reason: 'the widget is mounted for the seat on the clock',
    );
    expect(_count('60'), findsNothing);
    expect(_count('9'), findsNothing);

    // Inside the final stretch it puts a number on the table.
    session.update(deadline: clock.now().add(const Duration(milliseconds: 8400)));
    await tester.pump();
    expect(_count('9'), findsOneWidget);
  });

  testWidgets('the count runs down on its own, without a new frame from the server', (
    tester,
  ) async {
    final session = _StubSession(_dealtView());
    await _pumpTable(tester, session);

    session.update(deadline: clock.now().add(const Duration(milliseconds: 4900)));
    await tester.pump();
    expect(_count('5'), findsOneWidget);

    // The server sends nothing more; the ring is driven by the wall clock.
    await tester.pump(const Duration(seconds: 2));
    expect(_count('3'), findsOneWidget);

    // Past the deadline there is nothing left to count.
    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(TurnClock), findsOneWidget);
    expect(_count('0'), findsNothing);
  });

  testWidgets('nobody on the clock means no clock', (tester) async {
    final session = _StubSession(_dealtView());
    await _pumpTable(tester, session);

    session.update(clearDeadline: true);
    await tester.pump();
    expect(find.byType(TurnClock), findsNothing);
  });

  testWidgets('a touch anywhere takes your seat back from autoplay', (tester) async {
    final session = _StubSession(_dealtView(youAreOnAutoplay: true));
    await _pumpTable(tester, session);

    expect(find.text('Autoplay is on'), findsOneWidget);
    expect(find.text('Tap anywhere to take your seat back.'), findsOneWidget);

    // Bare felt, well away from any control.
    await tester.tapAt(const Offset(200, 300));
    await tester.pump();
    expect(session.wakeCalls, 1);

    // Drumming on the screen must not turn into a burst the server's frame
    // budget would refuse — one is enough, and the answer is already coming.
    for (var i = 0; i < 10; i++) {
      await tester.tapAt(const Offset(200, 300));
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(session.wakeCalls, 1);

    // Once the floor has passed, a fresh tap is heard again — the first frame
    // may have been lost with the connection that carried it.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(const Offset(200, 300));
    await tester.pump();
    expect(session.wakeCalls, 2);
  });

  testWidgets('a table nobody is idle at sends nothing and says nothing', (tester) async {
    final session = _StubSession(_dealtView());
    await _pumpTable(tester, session);

    expect(find.text('Autoplay is on'), findsNothing);

    await tester.tapAt(const Offset(200, 300));
    await tester.pump();
    expect(
      session.wakeCalls,
      0,
      reason: 'every tap in an ordinary game would be a wasted frame',
    );
  });
}
