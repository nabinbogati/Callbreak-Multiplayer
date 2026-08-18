import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:http/http.dart' as http;

import '../state/app_settings.dart';
import '../state/identity_store.dart';
import 'api_models.dart';

/// A non-2xx answer from `/v1`, or a request that never got one.
///
/// The server's error envelope is `{"error":{"code","message"}}`; [code] is the
/// stable machine-readable half and [message] is the sentence written for the
/// player. Failures that never reached the server ([network], [timeout]) are
/// modelled the same way rather than as a separate exception type, so every
/// caller has exactly one thing to catch.
class ApiException implements Exception {
  const ApiException({required this.code, required this.message, this.statusCode = 0});

  final String code;
  final String message;

  /// HTTP status, or 0 when the request never completed.
  final int statusCode;

  static const network = 'network';
  static const timeout = 'timeout';
  static const malformed = 'malformed';

  /// The server has no database configured (`503`). Not a fault: `make run`
  /// with no `DATABASE_URL` is a supported deployment, so this has to read as
  /// "history is off here", never as a crash.
  bool get isPersistenceDisabled => code == 'persistence_disabled';

  bool get isUnauthorized => code == 'unauthorized' || statusCode == 401;

  /// The endpoint is reserved for a future release (`501`) — what
  /// `POST /v1/auth/link` answers today.
  bool get isNotImplemented => code == 'not_implemented' || statusCode == 501;

  /// Whether re-sending the identical request could plausibly succeed later.
  /// A 4xx other than 429 says the request itself is wrong, and repeating it
  /// only wastes the battery.
  bool get isTransient => statusCode == 0 || statusCode == 429 || statusCode >= 500;

  /// What to put on screen. The server writes player-facing copy, so its own
  /// message wins whenever there is one. When it gave none — the body was
  /// empty, truncated, or a proxy's HTML page — the status class still says
  /// something real, so each one gets language that matches it instead of one
  /// generic line for everything.
  String get displayMessage => message.isNotEmpty ? message : _fallbackMessage;

  String get _fallbackMessage => switch (code) {
    network => 'No connection to the game server.',
    timeout => 'The server took too long to answer.',
    // A bare 5xx is a server or proxy that choked on the request, not the
    // player; there is nothing to fix except to wait it out.
    _ when statusCode >= 500 =>
      'The server hit a snag. Please try again in a moment.',
    // The API only answers 429 with its own copy, so a bare one means a
    // proxy or gateway throttling the player.
    _ when statusCode == 429 => 'A little too fast. Give it a moment, then try again.',
    // A bare 404 on an endpoint the app calls is the signature of a server
    // that does not know the route — most often an older deployment.
    _ when statusCode == 404 => 'This server does not recognise that request — '
        'it may be an older version. Please try again.',
    _ when statusCode >= 400 => 'That request did not go through. Check your '
        'input and try again.',
    _ => 'Something unexpected happened. Please try again.',
  };

  /// Reads the documented error envelope, tolerating a body that is empty,
  /// truncated or an HTML error page from a proxy in front of the server.
  factory ApiException.fromBody(int statusCode, Map<String, dynamic> body) {
    final error = body['error'];
    final fields = error is Map ? Map<String, dynamic>.from(error) : const {};
    final code = fields['code'];
    final message = fields['message'];
    return ApiException(
      code: code is String && code.isNotEmpty ? code : 'http_$statusCode',
      message: message is String ? message : '',
      statusCode: statusCode,
    );
  }

  @override
  String toString() => 'ApiException($code, $statusCode): $displayMessage';
}

/// Typed access to every endpoint in `backend/docs/API.md`.
///
/// The client owns the session token end to end: it mints one from the device
/// id on first use, persists it through [IdentityStore], and re-mints it once
/// on a `401` before giving up. No caller has to think about auth — which is
/// the point, because "did you remember to authenticate first" is exactly the
/// bug that shows up only on a fresh install.
class ApiClient {
  ApiClient({
    required this.origin,
    required this.identity,
    String Function()? displayName,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 12),
  }) : _displayName = displayName ?? _defaultDisplayName,
       _http = httpClient ?? http.Client(),
       _ownsHttpClient = httpClient == null;

  /// Builds a client for the server [settings] is pointed at right now.
  factory ApiClient.forSettings(AppSettings settings, {http.Client? httpClient}) =>
      ApiClient(
        origin: originFromSocketUrl(settings.effectiveServerUrl),
        identity: settings.identity,
        // Read at call time, not at construction: a client built during
        // startup would otherwise name the account whatever the default was
        // before the player had a chance to type their own name in.
        displayName: () => settings.playerName,
        httpClient: httpClient,
      );

  static String _defaultDisplayName() => 'Player';

  /// The HTTP origin the REST API is mounted on, e.g. `https://host:8443`.
  final Uri origin;
  final IdentityStore identity;

  final String Function() _displayName;

  /// Applied only when `auth/device` *creates* the account; it never renames
  /// an existing one (that is `PATCH /v1/me`).
  String get displayName => _displayName();

  /// Every request gets one. A history screen that spins forever is worse than
  /// one that says it could not load and offers a retry.
  final Duration timeout;

  final http.Client _http;
  final bool _ownsHttpClient;
  Future<void>? _pendingAuth;

  /// Called after any request the server answered successfully — the signal
  /// the upload queue drains on. Set by [GameUploader]; null everywhere else.
  void Function()? onServerReachable;

  /// The HTTP origin behind a websocket URL.
  ///
  /// [AppSettings.effectiveServerUrl] is the socket endpoint (`wss://host/ws`)
  /// because that is what the game actually connects to, but REST lives on the
  /// same mux one level up. Converting here rather than storing a second URL
  /// keeps the debug server override in the settings sheet pointing both at
  /// once — set one address, and the socket and the profile follow it together.
  static Uri originFromSocketUrl(String socketUrl) {
    final uri = Uri.parse(socketUrl.trim());
    final scheme = switch (uri.scheme) {
      'ws' || 'http' => 'http',
      // Anything unrecognised is assumed secure: guessing `http` for an
      // unknown scheme would silently downgrade a production URL.
      _ => 'https',
    };

    // `/ws` is the socket's own path segment and is not part of the origin;
    // any prefix in front of it (a reverse proxy mounting the app under a
    // subpath) is, so only the trailing segment is dropped.
    final segments = [
      for (final segment in uri.pathSegments)
        if (segment.isNotEmpty) segment,
    ];
    if (segments.isNotEmpty && segments.last == 'ws') segments.removeLast();

    return Uri(
      scheme: scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      pathSegments: segments.isEmpty ? null : segments,
    );
  }

  // ----------------------------------------------------------------- auth

  /// Ensures a usable bearer token exists, minting one from the device id if
  /// not. Concurrent callers — the three profile tabs all loading at once —
  /// share one in-flight handshake rather than racing to create the account.
  Future<void> ensureSession() {
    if (!identity.needsSession) return Future<void>.value();
    return _pendingAuth ??= authenticateDevice().then<void>((_) {}).whenComplete(() {
      _pendingAuth = null;
    });
  }

  /// `POST /v1/auth/device` — the only unauthenticated endpoint. Creates the
  /// account on first sight and returns the existing one afterwards.
  Future<AuthResult> authenticateDevice() async {
    final body = await _send(
      'POST',
      '/v1/auth/device',
      body: {
        'deviceId': identity.deviceId,
        'displayName': displayName,
        'platform': ?_platformName,
      },
      authenticated: false,
    );
    return _storeSession(body);
  }

  /// `POST /v1/auth/refresh`.
  Future<AuthResult> refreshSession() async =>
      _storeSession(await _send('POST', '/v1/auth/refresh'));

  /// `POST /v1/auth/link` — answers `501 not_implemented` today. Written
  /// against its final shape so switching the upgrade flow on is a flag flip
  /// (see [kAccountLinkingEnabled]) rather than a new code path.
  Future<AuthResult> linkAccount(String idToken) async =>
      _storeSession(await _send('POST', '/v1/auth/link', body: {'idToken': idToken}));

  /// `POST /v1/auth/restore` — re-anchors this install's device id onto the
  /// account whose id the player saved from their old device. The session lands
  /// in the identity store like any other auth result;
  /// [RestoreResult.abandoned] is set exactly when the install being replaced
  /// still had games, which means the caller should offer to bring them along
  /// or leave them behind.
  Future<RestoreResult> restoreAccount(String accountId) async {
    final body = await _send(
      'POST',
      '/v1/auth/restore',
      body: {'accountId': accountId},
    );
    final result = RestoreResult.fromJson(body);
    await _storeSession(body);
    return result;
  }

  /// `POST /v1/me/merge/{id}` — folds the abandoned guest account into the
  /// caller, so the games it carried appear in the restored account's history.
  /// A 404 means the offer is already consumed or was never real.
  Future<UserProfile> mergeAbandoned(String accountId) async {
    final user = UserProfile.fromJson(
      _map((await _send('POST', '/v1/me/merge/$accountId'))['user']),
    );
    await identity.saveUser(user);
    return user;
  }

  /// `DELETE /v1/me/abandoned/{id}` — discards the abandoned guest account and
  /// the games it carried. Games shared with other humans survive; this is the
  /// "leave them behind" half of the post-restore choice.
  Future<void> discardAbandoned(String accountId) =>
      _send('DELETE', '/v1/me/abandoned/$accountId');

  Future<AuthResult> _storeSession(Map<String, dynamic> body) async {
    final result = AuthResult.fromJson(body);
    if (result.token.isNotEmpty) {
      await identity.saveSession(
        token: result.token,
        expiresAt: result.expiresAt,
        user: result.user,
      );
    }
    return result;
  }

  // ------------------------------------------------------------------- me

  /// `GET /v1/me`.
  Future<UserProfile> fetchMe() async {
    final user = UserProfile.fromJson(_map((await _send('GET', '/v1/me'))['user']));
    await identity.saveUser(user);
    return user;
  }

  /// `PATCH /v1/me`.
  Future<UserProfile> updateDisplayName(String name) async {
    final body = await _send('PATCH', '/v1/me', body: {'displayName': name});
    final user = UserProfile.fromJson(_map(body['user']));
    await identity.saveUser(user);
    return user;
  }

  /// `GET /v1/me/stats` — every scope in one response.
  Future<StatsBundle> fetchStats() async =>
      StatsBundle.fromJson(await _send('GET', '/v1/me/stats'));

  /// `GET /v1/me/games?mode=&limit=&cursor=`.
  Future<GamePage> fetchGames({String? mode, int? limit, String? cursor}) async =>
      GamePage.fromJson(
        await _send(
          'GET',
          '/v1/me/games',
          query: {
            if (mode != null && mode.isNotEmpty) 'mode': mode,
            if (limit != null) 'limit': '$limit',
            if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
          },
        ),
      );

  /// `GET /v1/games/{id}` — the summary plus its hand-by-hand scoreboard.
  Future<GameDetail> fetchGame(String id) async =>
      GameDetail.fromJson(await _send('GET', '/v1/games/${Uri.encodeComponent(id)}'));

  /// `POST /v1/games` — idempotent on `clientGameId`.
  Future<UploadResult> uploadGame(Map<String, dynamic> payload) async =>
      UploadResult.fromJson(await _send('POST', '/v1/games', body: payload));

  // -------------------------------------------------------------- plumbing

  Uri _uri(String path, Map<String, String>? query) => origin.replace(
    path: '${origin.path}$path',
    queryParameters: (query == null || query.isEmpty) ? null : query,
  );

  static String? get _platformName => switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.windows => 'windows',
    TargetPlatform.linux => 'linux',
    TargetPlatform.fuchsia => null,
  };

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : const {};

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool authenticated = true,
    bool allowReauth = true,
  }) async {
    if (authenticated) await ensureSession();

    final response = await _perform(method, _uri(path, query), body, authenticated);
    final decoded = _decode(response.body);

    if (response.statusCode >= 200 && response.statusCode < 300) {
      onServerReachable?.call();
      return decoded;
    }

    // A token that expired between two screens should cost a round trip, not a
    // trip through the sign-in flow — the device id can always mint a new one.
    if (response.statusCode == 401 && authenticated && allowReauth) {
      await identity.clearSession();
      await ensureSession();
      return _send(
        method,
        path,
        query: query,
        body: body,
        authenticated: authenticated,
        allowReauth: false,
      );
    }

    throw ApiException.fromBody(response.statusCode, decoded);
  }

  Future<http.Response> _perform(
    String method,
    Uri uri,
    Object? body,
    bool authenticated,
  ) async {
    final token = authenticated ? identity.sessionToken : null;
    final headers = <String, String>{
      'accept': 'application/json',
      if (body != null) 'content-type': 'application/json',
      if (token != null && token.isNotEmpty) 'authorization': 'Bearer $token',
    };
    final encoded = body == null ? null : jsonEncode(body);

    try {
      final request = switch (method) {
        'GET' => _http.get(uri, headers: headers),
        'POST' => _http.post(uri, headers: headers, body: encoded),
        'PATCH' => _http.patch(uri, headers: headers, body: encoded),
        'DELETE' => _http.delete(uri, headers: headers),
        _ => throw ArgumentError.value(method, 'method'),
      };
      return await request.timeout(timeout);
    } on TimeoutException {
      throw const ApiException(
        code: ApiException.timeout,
        message: 'The server took too long to answer.',
      );
    } on ApiException {
      rethrow;
    } catch (error) {
      throw ApiException(
        code: ApiException.network,
        message: 'No connection to the game server.',
        statusCode: 0,
      );
    }
  }

  static Map<String, dynamic> _decode(String body) {
    if (body.trim().isEmpty) return const {};
    try {
      return _map(jsonDecode(body));
    } catch (_) {
      // A proxy's HTML error page, or a truncated response. Treated as an
      // empty envelope so the status code still decides the outcome.
      return const {};
    }
  }

  /// Releases the underlying connection pool. Only closes a client this
  /// instance created — an injected one belongs to whoever passed it in.
  void close() {
    if (_ownsHttpClient) _http.close();
  }
}

/// Whether the Google/Facebook/Apple upgrade flow is live.
///
/// Off, and deliberately so: `POST /v1/auth/link` answers `501` and the
/// Firebase SDK is not in this app. The buttons, their copy and the call into
/// [ApiClient.linkAccount] are all built and wired, so turning the feature on
/// is this constant plus a sign-in SDK — not a rewrite of the account tab.
const bool kAccountLinkingEnabled = false;
