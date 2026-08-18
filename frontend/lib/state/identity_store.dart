import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../net/api_models.dart';

/// A random RFC 4122 version-4 uuid, lower-case and hyphenated.
///
/// Hand-rolled rather than pulled from a package because this is the only
/// thing the app would use one for, and the whole specification is the two
/// bit-twiddles below: version nibble to 4, variant bits to `10`. [Random.secure]
/// because two ids that collide would silently merge two games on the server —
/// `Random()` is seeded from the clock, and phones start games at round numbers
/// of milliseconds far more often than a uniform distribution would suggest.
String uuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  String hex(int start, int end) =>
      bytes.sublist(start, end).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

/// Everything about "who this player is" that has to outlive the process.
///
/// The device id is the load-bearing value: `POST /v1/auth/device` resolves it
/// to a `users` row, so it is the account's only anchor until a Google/Apple
/// login is linked to it (`docs/PERSISTENCE.md` §1.2). Regenerating it would
/// orphan every game and every statistic the player has — hence [deviceId] is
/// written exactly once, on first launch, and only ever read afterwards.
///
/// Reads are synchronous because the whole store is pulled into memory by
/// [open] before `runApp`, and a widget cannot await in `build`. Writes go to
/// memory first and to disk in the background, so nothing on screen waits for
/// a flush.
class IdentityStore {
  IdentityStore._(this._prefs, this._deviceId, this._values);

  static const _kDeviceId = 'identity.deviceId';
  static const _kSessionToken = 'identity.sessionToken';
  static const _kSessionExpiresAt = 'identity.sessionExpiresAt';
  static const _kUser = 'identity.user';
  static const _kGuestToken = 'identity.guestToken';
  static const _kActiveGame = 'identity.activeGame';
  static const _kAbandoned = 'identity.pendingAbandoned';

  /// The uuid the device id is generated as, minus the hyphens, is 32 chars —
  /// comfortably inside the 8–128 `[A-Za-z0-9_-]` window `POST /v1/auth/device`
  /// enforces, and with no characters that need escaping in a JSON body.
  static String _newDeviceId() => uuidV4().replaceAll('-', '');

  final SharedPreferences? _prefs;
  final String _deviceId;
  final Map<String, String> _values;

  /// Opens the on-disk store, minting the device id if this is a first launch.
  ///
  /// Falls back to [IdentityStore.inMemory] when the platform refuses storage.
  /// Losing history is bad; refusing to launch the game over it would be worse.
  static Future<IdentityStore> open() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var deviceId = prefs.getString(_kDeviceId);
      if (deviceId == null || deviceId.isEmpty) {
        deviceId = _newDeviceId();
        await prefs.setString(_kDeviceId, deviceId);
      }
      final values = <String, String>{
        for (final key in const [
          _kSessionToken,
          _kSessionExpiresAt,
          _kUser,
          _kGuestToken,
          _kActiveGame,
          _kAbandoned,
        ])
          key: ?prefs.getString(key),
      };
      return IdentityStore._(prefs, deviceId, values);
    } catch (_) {
      return IdentityStore.inMemory();
    }
  }

  /// A store with no disk behind it. Everything works for the life of the
  /// process and nothing survives a restart — which is exactly what tests
  /// want, and the least-bad behaviour when the platform denies storage.
  IdentityStore.inMemory({String? deviceId})
    : _prefs = null,
      _deviceId = deviceId ?? _newDeviceId(),
      _values = {};

  /// Stable for the lifetime of the install. Never regenerated.
  String get deviceId => _deviceId;

  /// The bearer token for `/v1`, or null before the first `auth/device` call.
  String? get sessionToken => _values[_kSessionToken];

  DateTime? get sessionExpiresAt =>
      DateTime.tryParse(_values[_kSessionExpiresAt] ?? '');

  /// Whether the session is missing or close enough to expiry to be worth
  /// re-minting. The minute of slack keeps a token from dying mid-request.
  bool get needsSession {
    final token = sessionToken;
    if (token == null || token.isEmpty) return true;
    final expiry = sessionExpiresAt;
    return expiry != null &&
        expiry.isBefore(DateTime.now().toUtc().add(const Duration(minutes: 1)));
  }

  /// The last profile the server sent, so the account tab can render the
  /// player's identity before — or entirely without — a network round trip.
  UserProfile? get cachedUser {
    final raw = _values[_kUser];
    if (raw == null || raw.isEmpty) return null;
    try {
      return UserProfile.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      // A profile written by an older build that no longer decodes is not
      // worth a crash — the next /v1/me replaces it.
      return null;
    }
  }

  /// The signed guest identity the *socket* gateway issues on join. Distinct
  /// from [sessionToken], which is the REST credential: the two are minted by
  /// the same server for the same person but are not interchangeable.
  String? get guestToken => _values[_kGuestToken];

  Future<void> saveSession({
    required String token,
    DateTime? expiresAt,
    UserProfile? user,
  }) async {
    _write(_kSessionToken, token);
    if (expiresAt != null) _write(_kSessionExpiresAt, expiresAt.toUtc().toIso8601String());
    if (user != null) _write(_kUser, jsonEncode(user.toJson()));
    await _flush();
  }

  Future<void> saveUser(UserProfile user) async {
    _write(_kUser, jsonEncode(user.toJson()));
    await _flush();
  }

  Future<void> saveGuestToken(String token) async {
    if (token.isEmpty || token == guestToken) return;
    _write(_kGuestToken, token);
    await _flush();
  }

  /// The networked table this player was last seated at, if it might still be
  /// running. Written on every `joined`/reconnect and cleared the moment the
  /// table is left or finishes — see [RemoteSession] in `net/remote_session.dart`.
  ///
  /// Surviving a restart is the whole point: the process dying (killed by the
  /// OS, a crash, a deliberate quit) leaves no chance to say goodbye to the
  /// server, so this is the only way the app can later offer to reclaim the
  /// seat instead of just forgetting it was ever there.
  ActiveGame? get activeGame {
    final raw = _values[_kActiveGame];
    if (raw == null || raw.isEmpty) return null;
    try {
      return ActiveGame.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      // Written by an older build that no longer decodes. Not worth a crash;
      // there is simply nothing to offer to rejoin.
      return null;
    }
  }

  Future<void> saveActiveGame(ActiveGame game) async {
    _write(_kActiveGame, jsonEncode(game.toJson()));
    await _flush();
  }

  Future<void> clearActiveGame() async {
    _values.remove(_kActiveGame);
    await _prefs?.remove(_kActiveGame);
  }

  /// The abandoned guest account a restore left behind, if the player has not
  /// yet decided what to do with its games. Survives a restart on purpose: a
  /// restore that ends with the app being killed mid-decision would otherwise
  /// leave an account nobody can ever sign into again, with no way to offer it.
  AbandonedAccount? get pendingAbandoned {
    final raw = _values[_kAbandoned];
    if (raw == null || raw.isEmpty) return null;
    try {
      return AbandonedAccount.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> savePendingAbandoned(AbandonedAccount? abandoned) async {
    if (abandoned == null) {
      _values.remove(_kAbandoned);
      await _prefs?.remove(_kAbandoned);
      return;
    }
    _write(_kAbandoned, jsonEncode(abandoned.toJson()));
    await _flush();
  }

  /// Forgets the session but keeps the device id, so the next call to
  /// `auth/device` lands back on the same account rather than creating a new
  /// one. There is deliberately no way to forget the device id.
  Future<void> clearSession() async {
    _values.remove(_kSessionToken);
    _values.remove(_kSessionExpiresAt);
    await _prefs?.remove(_kSessionToken);
    await _prefs?.remove(_kSessionExpiresAt);
  }

  final List<MapEntry<String, String>> _pending = [];

  void _write(String key, String value) {
    _values[key] = value;
    _pending.add(MapEntry(key, value));
  }

  Future<void> _flush() async {
    final prefs = _prefs;
    final pending = [..._pending];
    _pending.clear();
    if (prefs == null) return;
    for (final entry in pending) {
      try {
        await prefs.setString(entry.key, entry.value);
      } catch (_) {
        // A failed write costs this player their history on the next reinstall.
        // It must not cost them the game they are in the middle of.
      }
    }
  }
}

/// Enough of a networked table to reconnect to it cold, with no
/// [RemoteSession] left in memory to ask.
///
/// [mode] is stored as [GameMode.name] rather than the enum itself so this
/// file does not need to import `net/session.dart` — the caller that
/// reconstructs a session converts it back with `GameMode.values.byName`.
class ActiveGame {
  const ActiveGame({
    required this.serverUrl,
    required this.roomCode,
    required this.mode,
    required this.resumeToken,
    required this.playerName,
  });

  final String serverUrl;
  final String roomCode;
  final String mode;
  final String resumeToken;
  final String playerName;

  Map<String, dynamic> toJson() => {
    'serverUrl': serverUrl,
    'roomCode': roomCode,
    'mode': mode,
    'resumeToken': resumeToken,
    'playerName': playerName,
  };

  factory ActiveGame.fromJson(Map<String, dynamic> json) => ActiveGame(
    serverUrl: json['serverUrl'] as String,
    roomCode: json['roomCode'] as String,
    mode: json['mode'] as String,
    resumeToken: json['resumeToken'] as String,
    playerName: json['playerName'] as String,
  );
}
