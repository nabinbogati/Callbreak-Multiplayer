@Tags(['live'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/net/remote_session.dart';
import 'package:callbreak/net/session.dart';
import 'package:callbreak/state/app_settings.dart';
import 'package:callbreak/ui/screens/settings_sheet.dart';
import 'package:callbreak/ui/screens/table_screen.dart';

/// Real widgets + real session + real server on :8099.
void main() {
  testWidgets('private lobby picker switches the length through the UI', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    late RemoteSession host;
    late RemoteSession guest;
    await tester.runAsync(() async {
      host = RemoteSession(
        serverUrl: 'ws://127.0.0.1:8099/ws',
        roomCode: 'QQ92',
        playerName: 'Nabin',
        mode: GameMode.private,
        handsPerGame: 3,
        creating: true,
      );
      try {
        await _until(() => host.lobby != null, 'host lobby');
      } catch (e) {
        // ignore: avoid_print
        print('host status=${host.status} err=${host.errorMessage} seat=${host.seat}');
        rethrow;
      }
      guest = RemoteSession(
        serverUrl: 'ws://127.0.0.1:8099/ws',
        roomCode: 'QQ92',
        playerName: 'Riya',
        mode: GameMode.private,
      );
      await _until(() => guest.lobby != null, 'guest lobby');
    });

    await tester.pumpWidget(
      SettingsScope(
        settings: AppSettings(),
        child: MaterialApp(home: TableScreen(session: host)),
      ),
    );
    await tester.pump();

    expect(find.text('Quickplay'), findsOneWidget);
    expect(find.text('Normal Play'), findsOneWidget);

    await tester.tap(find.text('Normal Play'));
    await tester.pump();
    await tester.runAsync(
      () => _until(() => host.lobby?.handsPerGame == 5, 'server echoes 5'),
    );
    await tester.pump();
    // ignore: avoid_print
    print('host lobby now ${host.lobby!.handsPerGame}');

    await tester.tap(find.text('Quickplay'));
    await tester.pump();
    await tester.runAsync(
      () => _until(() => host.lobby?.handsPerGame == 3, 'server echoes 3'),
    );
    await tester.pump();
    // ignore: avoid_print
    print('host lobby back to ${host.lobby!.handsPerGame}');

    await tester.runAsync(() async {
      guest.dispose();
    });
  }, timeout: const Timeout(Duration(seconds: 40)));
}

Future<void> _until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
