@Tags(['live'])
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/net/session.dart';
import 'package:callbreak/net/remote_session.dart';

/// Drives the real client against a server on :8099 (started by hand).
void main() {
  test('private lobby: host switches the match length', () async {
    final host = RemoteSession(
      serverUrl: 'ws://127.0.0.1:8099/ws',
      roomCode: 'ZK47',
      playerName: 'Nabin',
      mode: GameMode.private,
      handsPerGame: 3,
      creating: true,
    );

    await _until(() => host.lobby != null, 'host lobby');
    // ignore: avoid_print
    print('created lobby hands=${host.lobby!.handsPerGame} '
        'isHost=${host.lobby!.isHost} isOnline=${host.lobby!.isOnline}');

    final guest = RemoteSession(
      serverUrl: 'ws://127.0.0.1:8099/ws',
      roomCode: 'ZK47',
      playerName: 'Riya',
      mode: GameMode.private,
    );
    await _until(() => guest.lobby != null, 'guest lobby');

    host.setHandsPerGame(5);
    await _until(() => host.lobby?.handsPerGame == 5, 'host sees 5 hands');
    await _until(() => guest.lobby?.handsPerGame == 5, 'guest sees 5 hands');
    // ignore: avoid_print
    print('after Normal Play tap: host=${host.lobby!.handsPerGame} '
        'guest=${guest.lobby!.handsPerGame}');

    host.setHandsPerGame(3);
    await _until(() => host.lobby?.handsPerGame == 3, 'host back to 3 hands');
    // ignore: avoid_print
    print('after Quickplay tap: host=${host.lobby!.handsPerGame}');

    host.dispose();
    guest.dispose();
  }, timeout: const Timeout(Duration(seconds: 30)));
}

Future<void> _until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
