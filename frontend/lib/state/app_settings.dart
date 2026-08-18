import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/widgets.dart';

import '../design/tokens.dart';
import '../engine/game.dart';
import 'identity_store.dart';

/// The game server. Every build connects here.
///
/// The server itself lives in `backend/` in this repository; run it locally
/// with `make up` and it is served on http/ws://localhost:8080, with the
/// socket mounted at `/ws`.
const kDefaultServerUrl = 'ws://192.168.1.133:8080/ws';

/// Relative speed for the app's transient UI animations (card lifts, drag
/// snap-back, bot pacing timers). Multiplies each animation's base duration.
enum AnimationSpeed { slow, normal, fast }

extension AnimationSpeedX on AnimationSpeed {
  double get durationScale => switch (this) {
    AnimationSpeed.slow => 1.6,
    AnimationSpeed.normal => 1.0,
    AnimationSpeed.fast => 0.6,
  };
}

/// App-wide preferences. The display settings live in memory for the life of
/// the process; anything that identifies the *player* is delegated to
/// [identity], which is backed by storage — a theme is cheap to pick again
/// after a reinstall, an account is not.
class AppSettings extends ChangeNotifier {
  /// [identity] is opened asynchronously in `main`, before `runApp`. Omitting
  /// it yields an in-memory store, which is what a widget test wants and what
  /// the app falls back to if the platform denies storage.
  AppSettings({IdentityStore? identity})
    : _identity = identity ?? IdentityStore.inMemory();

  final IdentityStore _identity;

  TableTheme _theme = TableTheme.emerald;
  CardStyle _cardStyle = CardStyle.classic;
  String _playerName = 'You';
  BotDifficulty _difficulty = BotDifficulty.normal;
  String _serverUrl = '';
  bool _dragToPlayEnabled = true;
  bool _autoThrowLastCard = true;
  bool _autoThrowLastSuitCard = true;
  bool _musicEnabled = true;
  bool _sfxEnabled = true;
  AnimationSpeed _animationSpeed = AnimationSpeed.normal;
  bool _debugMode = false;

  /// The persistent half of this player: the device id that anchors their
  /// account, the REST session token, and the last profile the server sent.
  IdentityStore get identity => _identity;

  TableTheme get theme => _theme;
  ThemePalette get palette => ThemePalette.of(_theme);

  /// Card-face colour style. Defaults to [CardStyle.classic], which matches
  /// the app's original hardcoded card look, so existing players see no
  /// change unless they opt into a different style.
  CardStyle get cardStyle => _cardStyle;
  String get playerName => _playerName;
  BotDifficulty get difficulty => _difficulty;

  /// Debug-only override for the game server URL. Empty means "no override
  /// set", in which case [effectiveServerUrl] falls back to
  /// [kDefaultServerUrl]. This is not a user-facing setting in release
  /// builds — see the developer section in the settings sheet, which is
  /// tree-shaken out of release builds via `kDebugMode`.
  String get serverUrl => _serverUrl;

  /// The server URL the app should actually connect to: the debug override
  /// when running in debug mode with one set, otherwise [kDefaultServerUrl].
  String get effectiveServerUrl =>
      (kDebugMode && _serverUrl.trim().isNotEmpty) ? _serverUrl : kDefaultServerUrl;

  /// Whether a legal card in the hand can be played by dragging it toward the
  /// table, in addition to tapping it. Defaults on as a convenience feature.
  bool get dragToPlayEnabled => _dragToPlayEnabled;

  /// Whether the player's last card is thrown automatically the moment it
  /// becomes their turn — with one card left every play is legal, so there is
  /// never a choice to skip. Defaults on as a convenience feature.
  bool get autoThrowLastCard => _autoThrowLastCard;

  /// Whether the sole remaining card of the led suit is thrown automatically
  /// while following — holding exactly one card of that suit makes following
  /// it forced, so no decision is skipped. Defaults on. Leading a trick is
  /// never auto-played; there the player is choosing what to lead.
  bool get autoThrowLastSuitCard => _autoThrowLastSuitCard;

  /// Whether looping background music plays. Defaults on.
  bool get musicEnabled => _musicEnabled;

  /// Whether card-play and trick-collect sound effects play. Defaults on.
  bool get sfxEnabled => _sfxEnabled;

  /// Relative speed of transient UI animations. Defaults to normal (1.0x).
  AnimationSpeed get animationSpeed => _animationSpeed;

  /// Whether the debug "go offline" tooling is armed. Debug builds only — the
  /// toggle lives in the Developer section of the settings sheet and gates a
  /// "Go offline" button on the table. Defaults off so normal play never sees
  /// it. Release builds never render the setting or the button, so this is
  /// always false there.
  bool get debugMode => _debugMode;

  /// The signed guest identity the socket gateway last issued, if any.
  ///
  /// Sending it back on the next join keeps the same player id across tables.
  /// It now lives in [identity] rather than in a field here, so it survives an
  /// app restart as well as a reconnect — the same reason the device id does.
  /// The read stays synchronous because the store is loaded before `runApp`;
  /// only the write goes to disk, and it goes there in the background.
  String? get guestToken => _identity.guestToken;

  set guestToken(String? value) {
    if (value == null || value.isEmpty || value == _identity.guestToken) return;
    unawaited(_identity.saveGuestToken(value));
    // Deliberately no notifyListeners: this is a credential, not UI state, and
    // rebuilding the tree on every join would be pure noise.
  }

  set theme(TableTheme value) {
    if (_theme == value) return;
    _theme = value;
    notifyListeners();
  }

  set cardStyle(CardStyle value) {
    if (_cardStyle == value) return;
    _cardStyle = value;
    notifyListeners();
  }

  set playerName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == _playerName) return;
    _playerName = trimmed;
    notifyListeners();
  }

  set difficulty(BotDifficulty value) {
    if (_difficulty == value) return;
    _difficulty = value;
    notifyListeners();
  }

  set serverUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || trimmed == _serverUrl) return;
    _serverUrl = trimmed;
    notifyListeners();
  }

  set dragToPlayEnabled(bool value) {
    if (_dragToPlayEnabled == value) return;
    _dragToPlayEnabled = value;
    notifyListeners();
  }

  set autoThrowLastCard(bool value) {
    if (_autoThrowLastCard == value) return;
    _autoThrowLastCard = value;
    notifyListeners();
  }

  set autoThrowLastSuitCard(bool value) {
    if (_autoThrowLastSuitCard == value) return;
    _autoThrowLastSuitCard = value;
    notifyListeners();
  }

  set musicEnabled(bool value) {
    if (_musicEnabled == value) return;
    _musicEnabled = value;
    notifyListeners();
  }

  set sfxEnabled(bool value) {
    if (_sfxEnabled == value) return;
    _sfxEnabled = value;
    notifyListeners();
  }

  set animationSpeed(AnimationSpeed value) {
    if (_animationSpeed == value) return;
    _animationSpeed = value;
    notifyListeners();
  }

  set debugMode(bool value) {
    if (_debugMode == value) return;
    _debugMode = value;
    notifyListeners();
  }
}

/// Makes [AppSettings] available down the tree and rebuilds dependents on change.
class SettingsScope extends InheritedNotifier<AppSettings> {
  const SettingsScope({super.key, required AppSettings settings, required super.child})
    : super(notifier: settings);

  static AppSettings of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SettingsScope>();
    assert(scope != null, 'No SettingsScope found in context');
    return scope!.notifier!;
  }
}
