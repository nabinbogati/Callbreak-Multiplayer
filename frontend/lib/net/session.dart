import 'dart:async';

import 'package:flutter/foundation.dart';

import '../engine/card.dart';
import '../engine/game.dart';

/// How the table is being played.
enum GameMode { bots, private, online, lan }

extension GameModeInfo on GameMode {
  String get label => switch (this) {
    GameMode.private => 'Private',
    GameMode.bots => 'vs Bots',
    GameMode.online => 'vs Humans',
    GameMode.lan => 'LAN',
  };

  /// True when the table is driven entirely on this device.
  bool get isOffline => this == GameMode.bots;
}

enum SessionStatus { connecting, ready, error, closed }

/// A seat at a Call Break table.
///
/// The UI only ever talks to this interface, so a solo game against bots and a
/// networked table look identical from the widget side: a redacted [GameView]
/// to render, a stream of [GameEvent]s to animate, and three intents to send.
abstract class GameSession extends ChangeNotifier {
  GameView? get view;

  SessionStatus get status;

  String? get errorMessage;

  GameMode get mode;

  /// Discrete happenings (a card played, a trick won) for animation and sound.
  Stream<GameEvent> get events;

  bool get isReady => status == SessionStatus.ready && view != null;

  /// When the seat on the clock runs out of time, measured on *this device's*
  /// clock. Null when nothing is being timed — an offline game, or a networked
  /// turn belonging to a bot.
  ///
  /// The view carries the deadline on the server's clock, which is useless to
  /// compare against `DateTime.now()` on a phone whose clock is minutes off. A
  /// session therefore converts it once, when the view lands, by treating the
  /// view's own `serverTimeMs` as "now". What survives is a duration, which
  /// both clocks agree on.
  DateTime? get turnDeadline => null;

  /// When the between-hands scoreboard stops waiting and the table deals the
  /// next hand on its own, on *this device's* clock. Null when nothing is
  /// timing it — an offline game, or any phase but the scoreboard.
  ///
  /// A table with other people at it cannot sit on a scoreboard forever
  /// because one player put their phone down, so the wait is capped and the
  /// popup counts down to say so. Converted from server time the same way
  /// [turnDeadline] is.
  DateTime? get handAdvanceDeadline => null;

  /// Tell the table this player is still here, cancelling any autoplay their
  /// silence caused. Sent on a tap, so it must be cheap and harmless to repeat;
  /// sessions with no server to tell simply ignore it.
  void wakeUp() {}

  void placeBid(int bid);

  void play(PlayingCard card);

  /// Leave the between-hands scoreboard and deal the next hand.
  void continueToNextHand();

  /// Start a fresh game with the same seats.
  void restart();
}

/// One seat in a table that has not been dealt yet.
class LobbySeat {
  const LobbySeat({
    required this.seat,
    required this.name,
    required this.isBot,
    required this.connected,
    required this.isYou,
    required this.isHost,
  });

  final int seat;
  final String name;
  final bool isBot;
  final bool connected;
  final bool isYou;
  final bool isHost;

  factory LobbySeat.fromJson(Map<String, dynamic> json) => LobbySeat(
    seat: json['seat'] as int? ?? 0,
    name: json['name'] as String? ?? 'Guest',
    isBot: json['kind'] == 'bot',
    connected: json['connected'] as bool? ?? true,
    isYou: json['isYou'] as bool? ?? false,
    isHost: json['isHost'] as bool? ?? false,
  );
}

/// A table waiting to be dealt: who is here, and what it is still waiting for.
///
/// Quickplay players are seated at a real table the moment they arrive rather
/// than held in an anonymous queue, so this describes both modes — the only
/// difference is that a private table is started by its host and a quickplay
/// one deals itself once [minPlayers] are present.
class LobbyState {
  const LobbyState({
    required this.roomCode,
    required this.isOnline,
    required this.seats,
    required this.isHost,
    required this.canStart,
    required this.humansSeated,
    required this.minPlayers,
    required this.handsPerGame,
  });

  final String roomCode;

  /// True for a quickplay table, false for an invite-only one.
  final bool isOnline;
  final List<LobbySeat> seats;

  /// Whether this player may press Start. Only ever true on a private table —
  /// quickplay is hostless and deals itself on a countdown.
  final bool isHost;
  final bool canStart;

  /// People currently at the table, and how many it needs before it can deal.
  final int humansSeated;
  final int minPlayers;

  /// The table's current match length, changeable from the lobby before play.
  final int handsPerGame;

  /// How many more players a self-dealing table is still waiting for.
  int get stillNeeded {
    final missing = minPlayers - humansSeated;
    return missing > 0 ? missing : 0;
  }

  /// Whether the table is only waiting because there are not enough people yet.
  bool get isWaitingForPlayers => isOnline && stillNeeded > 0;

  factory LobbyState.fromJson(Map<String, dynamic> json) => LobbyState(
    roomCode: json['room'] as String? ?? '',
    isOnline: json['mode'] == 'online',
    seats: (json['seats'] as List? ?? const [])
        .map((s) => LobbySeat.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList(),
    isHost: json['isHost'] as bool? ?? false,
    canStart: json['canStart'] as bool? ?? false,
    humansSeated: json['humansSeated'] as int? ?? 0,
    minPlayers: json['minPlayers'] as int? ?? 1,
    handsPerGame: json['handsPerGame'] as int? ?? 5,
  );
}

/// A seat at a table the app does not own.
///
/// Networked play has states an offline game simply does not: waiting in a
/// lobby for friends to arrive, queuing for strangers, and counting down to a
/// deal. [GameSession] deliberately knows nothing about them so the table UI
/// stays identical across modes; this is where the table *screen* looks when it
/// needs to render the before-the-game part.
abstract class NetworkSession extends GameSession {
  /// The lobby, while the table is still filling. Null once play begins.
  LobbyState? get lobby;

  /// Seconds until the table deals itself, or null when nothing is counting.
  int? get countdown;

  /// Leave the table before it has dealt, freeing the seat for someone else.
  void leaveLobby();

  /// True while re-establishing a connection that dropped mid-game, so the UI
  /// can say "Reconnecting" — and that the seat is being held — rather than
  /// the bare "Connecting" of a first attempt.
  bool get isResuming;

  /// Whether a seat is still being held that this session could reclaim, and
  /// for how much longer. Null when there is nothing to go back to.
  bool get canResume;
  Duration? get seatHeldFor;

  /// Try to reclaim the seat immediately, rather than waiting for the next
  /// scheduled attempt.
  void retryNow();

  /// Retry a *first* connect that outright failed — the "Try again" button on
  /// the "Can't connect" screen. Unlike [retryNow], no seat is being held, so
  /// a session that never got in simply makes a brand-new attempt.
  ///
  /// A no-op for sessions that have nothing to reconnect to (or are already
  /// trying again); it is only wired where a live network connection exists.
  void retryConnect() {}

  /// Ask the server to deal. Only meaningful when `lobby.canStart` is true.
  void startGame();

  /// Ask the room to change its match length while still in the lobby, so
  /// host and players can agree on Quickplay/Normal Play before the game
  /// deals. No-op on sessions without a live lobby to talk to.
  void setHandsPerGame(int hands) {}

  /// Debug-only: pretend this device's internet just dropped, or came back.
  ///
  /// Exercises the exact same disconnect/backoff/reconnect path a real Wi-Fi
  /// or cellular drop would, instead of one hand-waved by a mock — which is
  /// what makes it useful for driving the reconnection UI on demand rather
  /// than waiting for a real network blip. No-op on a session with no live
  /// connection to sever.
  void simulateOffline(bool offline) {}

  /// Whether [simulateOffline] currently has this session pretending to be
  /// offline.
  bool get isSimulatedOffline => false;
}
