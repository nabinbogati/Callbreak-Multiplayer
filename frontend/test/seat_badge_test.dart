import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/engine/game.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/ui/widgets/seat_view.dart';

/// Pumps a single [SeatView] so a test can home in on one player's avatar
/// without dealing a real hand first.
Future<void> pumpSeat(
  WidgetTester tester,
  PlayerInfo player, {
  bool isHost = false,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    SettingsScope(
      settings: AppSettings(),
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => SeatView(
                player: player,
                slot: SeatSlot.top,
                palette: SettingsScope.of(context).palette,
                bid: null,
                tricksWon: 0,
                isTurn: false,
                isDealer: false,
                isHost: isHost,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  final connectedHuman = PlayerInfo(
    seat: 1,
    name: 'Bina',
    kind: PlayerKind.human,
    connected: true,
    autoplay: false,
  );

  final droppedHuman = PlayerInfo(
    seat: 1,
    name: 'Bina',
    kind: PlayerKind.human,
    connected: false,
    autoplay: false,
  );

  final idleHuman = PlayerInfo(
    seat: 1,
    name: 'Bina',
    kind: PlayerKind.human,
    connected: true,
    autoplay: true,
  );

  final bot = PlayerInfo(
    seat: 2,
    name: 'Bot',
    kind: PlayerKind.bot,
    connected: true,
    autoplay: false,
  );

  testWidgets('a present, attentive human carries no robot mark', (tester) async {
    await pumpSeat(tester, connectedHuman);
    expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
  });

  testWidgets('a dropped player looks offline and marked with a bot', (tester) async {
    await pumpSeat(tester, droppedHuman);
    // The scrim + wifi-off icon says the player is gone…
    expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
    // …and the robot says a bot is playing their hand in the meantime.
    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
  });

  testWidgets('an idle player on autoplay keeps the robot mark', (tester) async {
    await pumpSeat(tester, idleHuman);
    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
  });

  testWidgets('a seat handed to a bot outright shows the robot mark', (tester) async {
    await pumpSeat(tester, bot);
    expect(find.byIcon(Icons.smart_toy_outlined), findsOneWidget);
  });

  testWidgets('only the host seat carries the host badge', (tester) async {
    await pumpSeat(tester, connectedHuman);
    expect(find.byIcon(Icons.workspace_premium_rounded), findsNothing);

    await pumpSeat(tester, connectedHuman, isHost: true);
    expect(find.byIcon(Icons.workspace_premium_rounded), findsOneWidget);
  });
}