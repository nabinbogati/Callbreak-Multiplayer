import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/net/remote_session.dart' show kQuickplayRoom;
import 'package:callbreak/net/session.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/ui/screens/settings_sheet.dart';

/// Online ("vs Humans") used to hand the player a raw, prefilled room-code
/// field that only ever meant 'quickplay'. It now offers an explicit choice
/// between a short Quickplay match and the full Normal Play game instead,
/// and that choice has to actually reach the [JoinDetails] the caller acts
/// on — these pump the real sheet rather than exercising the state class
/// directly.
void main() {
  /// Opens the join sheet for [mode] and leaves it on screen. [onResult], if
  /// given, is handed whatever [JoinDetails] the sheet is eventually popped
  /// with — tests that only inspect the sheet's contents can omit it.
  Future<void> openJoinSheet(
    WidgetTester tester,
    GameMode mode, {
    void Function(JoinDetails?)? onResult,
  }) async {
    await tester.pumpWidget(
      SettingsScope(
        settings: AppSettings(),
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                final result = await showJoinSheet(context, mode: mode);
                onResult?.call(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'Online join sheet offers Quickplay/Normal Play instead of a room code field',
    (tester) async {
      await openJoinSheet(tester, GameMode.online);

      expect(find.text('Quickplay'), findsOneWidget);
      expect(find.text('Normal Play'), findsOneWidget);
      expect(find.text('3 hands · fast matches'), findsOneWidget);
      expect(find.text('5 hands · the full game'), findsOneWidget);
      expect(find.text('Room code'), findsNothing);
      // No manual server field — vs Humans uses the default server.
      expect(find.text('Game server'), findsNothing);
    },
  );

  testWidgets(
    'Connect defaults to Quickplay (3 hands) without any extra taps',
    (tester) async {
      JoinDetails? result;
      await openJoinSheet(tester, GameMode.online, onResult: (r) => result = r);

      await tester.tap(find.text('Find match'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.roomCode, kQuickplayRoom);
      expect(result!.handsPerGame, 3);
    },
  );

  testWidgets('tapping Normal Play then Connect requests 5 hands', (
    tester,
  ) async {
    JoinDetails? result;
    await openJoinSheet(tester, GameMode.online, onResult: (r) => result = r);

    await tester.tap(find.text('Normal Play'));
    await tester.pump();
    await tester.tap(find.text('Find match'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.roomCode, kQuickplayRoom);
    expect(result!.handsPerGame, 5);
  });

  testWidgets('LAN join sheet keeps its plain server + room code fields', (
    tester,
  ) async {
    await openJoinSheet(tester, GameMode.lan);

    expect(find.text('Room code'), findsOneWidget);
    expect(find.text('Quickplay'), findsNothing);
    expect(find.text('Normal Play'), findsNothing);
  });

  testWidgets('Bots sheet offers the length choice and deals a quickplay by default', (
    tester,
  ) async {
    JoinDetails? result;
    await openJoinSheet(tester, GameMode.bots, onResult: (r) => result = r);

    expect(find.text('Quickplay'), findsOneWidget);
    expect(find.text('Normal Play'), findsOneWidget);
    expect(find.text('Game server'), findsNothing);
    expect(find.text('Room code'), findsNothing);

    await tester.tap(find.text('Start game'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.handsPerGame, 3);
  });

  testWidgets('Bots sheet can pick a 5-hand normal play', (tester) async {
    JoinDetails? result;
    await openJoinSheet(tester, GameMode.bots, onResult: (r) => result = r);

    await tester.tap(find.text('Normal Play'));
    await tester.pump();
    await tester.tap(find.text('Start game'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.handsPerGame, 5);
  });

  group('dismissal', () {
    testWidgets('tapping the dim area outside the panel closes the sheet', (
      tester,
    ) async {
      var closed = false;
      JoinDetails? result;
      await openJoinSheet(
        tester,
        GameMode.bots,
        onResult: (r) {
          result = r;
          closed = true;
        },
      );

      expect(find.text('vs Bots'), findsOneWidget);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(closed, isTrue);
      expect(result, isNull);
    });

    testWidgets('tapping inside the panel keeps the sheet open', (tester) async {
      var closed = false;
      await openJoinSheet(tester, GameMode.bots, onResult: (_) => closed = true);

      expect(find.text('vs Bots'), findsOneWidget);

      await tester.tap(find.text('vs Bots'));
      await tester.pumpAndSettle();

      expect(closed, isFalse);
      expect(find.text('Start game'), findsOneWidget);
    });
  });

  group('Private join sheet', () {
    testWidgets('Create is the default and hands over the generated code', (
      tester,
    ) async {
      JoinDetails? result;
      await openJoinSheet(
        tester,
        GameMode.private,
        onResult: (r) => result = r,
      );

      expect(find.text('Create room'), findsOneWidget);
      await tester.tap(find.text('Create room'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.creating, isTrue);
      expect(result!.roomCode, matches(RegExp(r'^[A-HJ-NP-Z2-9]{4}$')));
    });

    testWidgets('Create asks for no match length but opens the room on Quickplay', (
      tester,
    ) async {
      JoinDetails? result;
      await openJoinSheet(
        tester,
        GameMode.private,
        onResult: (r) => result = r,
      );

      // Create shows the generated code, not a Quickplay/Normal Play pick.
      expect(find.text('Quickplay'), findsNothing);
      expect(find.text('Normal Play'), findsNothing);

      await tester.tap(find.text('Create room'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.creating, isTrue);
      // The length is still settled in the lobby, but the table is opened on
      // Quickplay rather than the server's full-game fallback.
      expect(result!.handsPerGame, 3);
      expect(result!.roomCode, matches(RegExp(r'^[A-HJ-NP-Z2-9]{4}$')));
    });

    testWidgets('an empty code is called out instead of silently ignored', (
      tester,
    ) async {
      JoinDetails? result;
      await openJoinSheet(
        tester,
        GameMode.private,
        onResult: (r) => result = r,
      );

      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Join room'));
      await tester.pumpAndSettle();

      expect(result, isNull);
      expect(
        find.text('Type the room code your friend shared.'),
        findsOneWidget,
      );
    });

    testWidgets('a typed code joins without creating a room', (tester) async {
      JoinDetails? result;
      await openJoinSheet(
        tester,
        GameMode.private,
        onResult: (r) => result = r,
      );

      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '7QF2');
      await tester.tap(find.text('Join room'));
      await tester.pumpAndSettle();

      expect(result, isNotNull);
      expect(result!.creating, isFalse);
      expect(result!.roomCode, '7QF2');
      // A joiner never states a length — the room already has one.
      expect(result!.handsPerGame, isNull);
    });
  });
}
