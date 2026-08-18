import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/engine/game.dart';
import 'package:callbreak/net/lan_host_session.dart';
import 'package:callbreak/net/remote_session.dart';
import 'package:callbreak/net/session.dart';

void main() {
  test('a LAN guest sees a fresh bidding hand 0 after the host restarts',
      () async {
    // flutter_test installs a mock HttpClient that 400s every request; this
    // LAN table really needs the loopback socket, so restore real networking.
    HttpOverrides.global = null;

    final host = LanHostSession(playerName: 'Host', roomCode: 'TEST');
    addTearDown(host.dispose);

    await host.startHosting();
    final port = host.wsPort;
    expect(port, isNotNull, reason: 'host server should be up');
    debugPrint(
        'host started=${host.started} wsPort=$port players=${host.lobbyPlayers.length} canStart=${host.canStart}');

    // Guest must join BEFORE the host starts, exactly like the real lobby.
    final guest = RemoteSession(
      serverUrl: 'ws://127.0.0.1:$port',
      roomCode: 'TEST',
      playerName: 'Guest',
      mode: GameMode.lan,
    );
    addTearDown(guest.dispose);

    await _waitFor(guest, (g) => g.seat != null);
    expect(guest.seat, isNotNull,
        reason: 'guest should be seated before the game starts');
    expect(guest.status, SessionStatus.ready, reason: 'guest should be ready');
    debugPrint('guest seated: seat=${guest.seat} status=${guest.status}');

    host.startGame();
    await _waitFor(guest, (g) => g.view != null && g.view!.phase == GamePhase.bidding);
    expect(guest.view?.phase, GamePhase.bidding,
        reason: 'game 1 should deal (hand 0 bidding)');
    expect(guest.view?.handIndex, 0);
    debugPrint('guest game 1: handIndex=${guest.view?.handIndex}');

    // ---- restart, exactly what the host taps on the winner screen -------------
    host.restart();
    await _waitFor(guest, (g) => g.view != null && g.view!.phase == GamePhase.bidding);
    debugPrint(
        'guest after restart: handIndex=${guest.view?.handIndex} phase=${guest.view?.phase}');

    expect(guest.view?.phase, GamePhase.bidding,
        reason: 'after restart the guest should get a fresh bidding view');
    expect(guest.view?.handIndex, 0,
        reason: 'restart deals hand 0, so the dealing flourish must re-run');
  });
}

Future<void> _waitFor(
  RemoteSession session,
  bool Function(RemoteSession s) test,
) async {
  for (var i = 0; i < 500; i++) {
    if (test(session)) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}