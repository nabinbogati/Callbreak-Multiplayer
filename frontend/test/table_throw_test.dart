import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/engine/card.dart';
import 'package:callbreak/engine/game.dart';
import 'package:callbreak/engine/rules.dart';
import 'package:callbreak/net/session.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/ui/screens/table_screen.dart';
import 'package:callbreak/ui/widgets/hand_fan.dart';
import 'package:callbreak/ui/widgets/playing_card_view.dart';

/// Behaves like a networked table: a play is only sent, and the view changes
/// only when the test (standing in for the server) says so.
class _ServerLikeSession extends GameSession {
  _ServerLikeSession(this._view);

  GameView _view;
  final _events = StreamController<GameEvent>.broadcast();
  final played = <PlayingCard>[];

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
  void play(PlayingCard card) => played.add(card);

  @override
  void continueToNextHand() {}

  @override
  void restart() {}

  void confirm(GameView view) {
    _view = view;
    notifyListeners();
  }

  @override
  void dispose() {
    _events.close();
    super.dispose();
  }
}

const _lead = TrickPlay(1, PlayingCard(9, Suit.hearts));
const _five = PlayingCard(5, Suit.hearts);
const _club = PlayingCard(3, Suit.clubs);
const _hand = [PlayingCard(2, Suit.hearts), _five, _club];

GameView _view({required List<PlayingCard> hand, required List<TrickPlay> trick, int turn = 0}) {
  return GameView(
    phase: GamePhase.playing,
    handIndex: 0,
    handsPerGame: handsPerGame,
    dealer: 3,
    turn: turn,
    players: const [
      PlayerInfo(seat: 0, name: 'You', kind: PlayerKind.human),
      PlayerInfo(seat: 1, name: 'Bina', kind: PlayerKind.human),
      PlayerInfo(seat: 2, name: 'Kamal', kind: PlayerKind.bot),
      PlayerInfo(seat: 3, name: 'Sita', kind: PlayerKind.bot),
    ],
    you: 0,
    hand: hand,
    legalMoveIds: turn == 0 ? legalMoves(hand, trick).map((c) => c.id).toSet() : const {},
    handCounts: [hand.length, 12, 13, 13],
    bids: const [3, 3, 3, 3],
    tricksWon: const [0, 0, 0, 0],
    trick: trick,
    trickNumber: 0,
    awaitingTrickClear: false,
    lastTrick: null,
    roundScores: const [[], [], [], []],
    totals: const [0, 0, 0, 0],
    rankings: const [],
  );
}

Future<_ServerLikeSession> _pumpTable(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  final session = _ServerLikeSession(_view(hand: _hand, trick: const [_lead]));
  await tester.pumpWidget(
    SettingsScope(
      settings: AppSettings(),
      child: MaterialApp(home: TableScreen(session: session)),
    ),
  );
  await tester.pump(const Duration(milliseconds: 400));
  return session;
}

Finder _inHand(PlayingCard card) => find.descendant(
  of: find.byType(HandFan),
  matching: find.byWidgetPredicate((w) => w is PlayingCardView && w.card == card),
);

Finder _flight() =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == '_ThrowFlight');

Offset _strip(WidgetTester tester, PlayingCard card) {
  final rect = tester.getRect(_inHand(card));
  return Offset(rect.left + 8, rect.center.dy);
}

void main() {
  testWidgets('a throw waits, landed, for a slow server and then hands off', (tester) async {
    final session = await _pumpTable(tester);

    await tester.tapAt(_strip(tester, _five));
    await tester.pump();
    expect(session.played, [_five]);
    expect(_flight(), findsOneWidget);
    expect(_inHand(_five), findsNothing, reason: 'never both in the air and in the hand');

    // Well past the flight's own length: still no word from the server.
    await tester.pump(const Duration(milliseconds: 700));
    expect(_flight(), findsOneWidget, reason: 'the landed card holds until confirmed');

    session.confirm(
      _view(hand: const [PlayingCard(2, Suit.hearts), _club], trick: const [_lead, TrickPlay(0, _five)], turn: 2),
    );
    await tester.pump();
    expect(_flight(), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is PlayingCardView && w.card == _five),
      findsOneWidget,
      reason: 'the settled copy on the felt has taken over',
    );
  });

  testWidgets('a throw the server never confirms comes back to the hand', (tester) async {
    final session = await _pumpTable(tester);

    await tester.tapAt(_strip(tester, _five));
    await tester.pump();
    expect(session.played, [_five]);
    expect(_inHand(_five), findsNothing);

    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_flight(), findsNothing);
    expect(_inHand(_five), findsOneWidget);
  });

  testWidgets('a refused card says why', (tester) async {
    final session = await _pumpTable(tester);

    await tester.tapAt(_strip(tester, _club));
    await tester.pump(const Duration(milliseconds: 300));
    expect(session.played, isEmpty);
    expect(find.text('Follow suit — play a heart'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    // Let the pill's exit transition finish.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Follow suit — play a heart'), findsNothing);
  });
}
