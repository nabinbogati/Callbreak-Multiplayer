import 'dart:async';

import '../engine/game.dart' show GamePhase;
import '../net/remote_session.dart';
import '../net/session.dart' show SessionStatus;
import 'app_settings.dart';
import 'identity_store.dart' show ActiveGame;

/// Keeps [AppSettings.identity] up to date with what this seat would need to
/// reclaim itself: the guest identity (stable across tables for as long as
/// the process lives) and, separately, the active-table record that survives
/// the process dying entirely.
///
/// The active-game record is written on every reissued `resumeToken` — join
/// and every reconnect — and cleared the moment this session reaches a
/// terminal state (closed, errored, or the game is over). It is scoped to the
/// session's own room: a session that never wrote the record currently on
/// disk (because some other table wrote it) must not erase it.
///
/// Shared by every place a [RemoteSession] is created — the home screen's
/// initial join and the table's re-match path — so identity follows a player
/// across tables no matter which code signed the session up.
void wireActiveGamePersistence(AppSettings settings, RemoteSession session) {
  String? persistedToken;
  session.addListener(() {
    settings.guestToken = session.guestToken;

    final view = session.view;
    final terminal =
        session.status == SessionStatus.closed ||
        session.status == SessionStatus.error ||
        view?.phase == GamePhase.gameOver;
    if (terminal) {
      final stored = settings.identity.activeGame;
      if (stored != null &&
          stored.serverUrl == session.serverUrl &&
          stored.roomCode == session.roomCode) {
        unawaited(settings.identity.clearActiveGame());
      }
      return;
    }

    final token = session.resumeToken;
    if (token != null && token != persistedToken) {
      persistedToken = token;
      unawaited(
        settings.identity.saveActiveGame(
          ActiveGame(
            serverUrl: session.serverUrl,
            roomCode: session.roomCode,
            mode: session.mode.name,
            resumeToken: token,
            playerName: session.playerName,
          ),
        ),
      );
    }
  });
}