import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:callbreak/net/api_client.dart';
import 'package:callbreak/net/api_models.dart';
import 'package:callbreak/net/session.dart';

/// The Go server in `backend/` and this client are two implementations of one
/// REST contract, and nothing in either language's type system connects them.
/// `wire_contract_test.dart` closes that gap for the socket by decoding bytes
/// the real server produced; this closes it for `/v1` by decoding the literal
/// examples in `backend/docs/API.md`.
///
/// The JSON below is copied verbatim from that document, which is the reason
/// it is written out as strings rather than built with Dart map literals: a
/// field renamed on the server is renamed in API.md first, and the diff
/// between this file and that document is then a one-line read. Do not
/// "tidy" these fixtures — their value is that they are not paraphrased.
void main() {
  group('shared objects decode as documented', () {
    // API.md § Shared objects → `user`
    const userJson = '''
{
  "id": "018f3a2b-7c41-7b3e-9a10-4f2c8d5e6b71",
  "displayName": "Nabin",
  "isGuest": true,
  "avatarId": "",
  "country": "",
  "createdAt": "2026-08-01T12:00:00Z",
  "lastSeenAt": "2026-08-10T09:41:22Z",
  "identities": [
    { "provider": "device", "linkedAt": "2026-08-01T12:00:00Z" }
  ]
}
''';

    // API.md § Shared objects → `gameSummary`
    const gameSummaryJson = '''
{
  "id": "018f3a2b-...",
  "mode": "online",
  "roomCode": "QUICKPLAY",
  "completed": true,
  "startedAt": "2026-08-10T09:10:00Z",
  "finishedAt": "2026-08-10T09:34:11Z",
  "handsTotal": 5,
  "you": {
    "seat": 2, "finalScore": 13.2, "place": 1,
    "totalBid": 14, "totalTricks": 15
  },
  "players": [
    { "seat": 0, "userId": null, "displayName": "Amit", "isBot": true,  "finalScore": 6.1,  "place": 3 },
    { "seat": 1, "userId": null, "displayName": "Riya", "isBot": true,  "finalScore": 8.0,  "place": 2 },
    { "seat": 2, "userId": "018f...", "displayName": "Nabin", "isBot": false, "finalScore": 13.2, "place": 1 },
    { "seat": 3, "userId": null, "displayName": "Sujan", "isBot": true, "finalScore": -2.0, "place": 4 }
  ]
}
''';

    // API.md § Shared objects → `stats` (one scope)
    const statsJson = '''
{
  "scope": "online",
  "gamesPlayed": 42, "gamesCompleted": 40, "gamesWon": 17, "gamesLost": 23,
  "bestPlace": 1,
  "handsPlayed": 200,
  "totalBid": 560, "bidsMade": 141, "bidsFailed": 59, "highestBid": 8,
  "totalTricks": 602,
  "totalScore": 318.4,
  "highestGameScore": 21.7, "lowestGameScore": -9.0, "highestHandScore": 8.3,
  "currentWinStreak": 2, "bestWinStreak": 5,
  "lastPlayedAt": "2026-08-10T09:34:11Z"
}
''';

    Map<String, dynamic> decode(String source) =>
        Map<String, dynamic>.from(jsonDecode(source) as Map);

    test('user carries its identities and its guest flag', () {
      final user = UserProfile.fromJson(decode(userJson));

      expect(user.id, '018f3a2b-7c41-7b3e-9a10-4f2c8d5e6b71');
      expect(user.displayName, 'Nabin');
      expect(user.isGuest, isTrue);
      expect(user.avatarId, isEmpty);
      expect(user.country, isEmpty);
      expect(user.createdAt, DateTime.utc(2026, 8, 1, 12));
      expect(user.lastSeenAt, DateTime.utc(2026, 8, 10, 9, 41, 22));

      expect(user.identities, hasLength(1));
      expect(user.identities.single.provider, AuthProvider.device);
      expect(user.identities.single.linkedAt, DateTime.utc(2026, 8, 1, 12));

      // A `device`-only account is a guest that can be upgraded: nothing about
      // it yet survives moving to another phone.
      expect(user.portableIdentities, isEmpty);
      expect(user.isLinked, isFalse);
    });

    test('a linked user is no longer a guest', () {
      final user = UserProfile.fromJson(
        decode('''
{
  "id": "018f", "displayName": "Nabin", "isGuest": false,
  "identities": [
    { "provider": "device", "linkedAt": "2026-08-01T12:00:00Z" },
    { "provider": "google", "linkedAt": "2026-08-09T18:02:00Z" }
  ]
}
'''),
      );

      expect(user.isGuest, isFalse);
      expect(user.isLinked, isTrue);
      expect(user.portableIdentities.single.provider, AuthProvider.google);
    });

    test('a provider this build has never heard of does not throw', () {
      // Providers are a vocabulary the server can extend; an unknown one has to
      // degrade to "some other sign-in", never to a crash on decode.
      final user = UserProfile.fromJson(
        decode('{"id":"1","identities":[{"provider":"steam"}]}'),
      );
      expect(user.identities.single.provider, AuthProvider.unknown);
    });

    test('user survives a round trip through the profile cache', () {
      final original = UserProfile.fromJson(decode(userJson));
      final restored = UserProfile.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(original.toJson())) as Map),
      );

      expect(restored.id, original.id);
      expect(restored.displayName, original.displayName);
      expect(restored.isGuest, original.isGuest);
      expect(restored.createdAt, original.createdAt);
      expect(restored.identities.single.provider, AuthProvider.device);
    });

    test('gameSummary decodes both seat shapes', () {
      final game = GameSummary.fromJson(decode(gameSummaryJson));

      expect(game.id, '018f3a2b-...');
      expect(game.mode, 'online');
      expect(game.gameMode, GameMode.online);
      expect(game.modeLabel, 'Normal Play');
      expect(game.roomCode, 'QUICKPLAY');
      expect(game.completed, isTrue);
      expect(game.startedAt, DateTime.utc(2026, 8, 10, 9, 10));
      expect(game.finishedAt, DateTime.utc(2026, 8, 10, 9, 34, 11));
      expect(game.handsTotal, 5);
      // `you` carries the bidding totals the `players` entries do not.
      expect(game.you, isNotNull);
      expect(game.you!.seat, 2);
      expect(game.you!.finalScore, 13.2);
      expect(game.you!.place, 1);
      expect(game.you!.isWinner, isTrue);
      expect(game.you!.totalBid, 14);
      expect(game.you!.totalTricks, 15);

      // `players` carries who sat there, which `you` does not.
      expect(game.players, hasLength(4));
      expect(game.players[0].displayName, 'Amit');
      expect(game.players[0].isBot, isTrue);
      expect(game.players[0].userId, isNull);
      expect(game.players[2].userId, '018f...');
      expect(game.players[2].isBot, isFalse);
      expect(game.players[3].finalScore, -2.0);

      // The opponents line is everyone but the caller's own seat.
      expect(
        game.opponents.map((p) => p.displayName),
        ['Amit', 'Riya', 'Sujan'],
      );
    });

    test('place 0 means abandoned, not fourth', () {
      final game = GameSummary.fromJson(
        decode('{"id":"1","mode":"bots","completed":false,"you":{"seat":0,"place":0}}'),
      );

      expect(game.completed, isFalse);
      expect(game.you!.place, 0);
      expect(game.you!.isRanked, isFalse);
      expect(game.you!.isWinner, isFalse);
      // An unfinished game still sorts and stamps by when it was started.
      expect(game.finishedAt, isNull);
    });

    test('online history labels split quickplay from a full match', () {
      // 3 hands is Quickplay; 5 hands is the full "Normal Play" length.
      final quickplay = GameSummary.fromJson(
        decode('{"id":"1","mode":"online","handsTotal":3}'),
      );
      final full = GameSummary.fromJson(
        decode('{"id":"2","mode":"online","handsTotal":5}'),
      );
      final unknown = GameSummary.fromJson(
        decode('{"id":"3","mode":"online","handsTotal":7}'),
      );

      expect(quickplay.modeLabel, 'Quickplay');
      expect(full.modeLabel, 'Normal Play');
      expect(unknown.modeLabel, 'vs Humans');
    });

    test('every mode name in API.md maps to a play mode', () {
      for (final mode in const ['bots', 'private', 'online', 'lan']) {
        final game = GameSummary.fromJson(decode('{"id":"1","mode":"$mode"}'));
        expect(game.gameMode, isNotNull, reason: mode);
        expect(game.gameMode!.name, mode);
      }
    });

    test('stats decode every counter §3.2 tracks', () {
      final stats = ScopeStats.fromJson(decode(statsJson));

      expect(stats.scope, StatsScope.online);
      expect(stats.gamesPlayed, 42);
      expect(stats.gamesCompleted, 40);
      expect(stats.gamesWon, 17);
      expect(stats.gamesLost, 23);
      expect(stats.bestPlace, 1);
      expect(stats.handsPlayed, 200);
      expect(stats.totalBid, 560);
      expect(stats.bidsMade, 141);
      expect(stats.bidsFailed, 59);
      expect(stats.highestBid, 8);
      expect(stats.totalTricks, 602);
      expect(stats.totalScore, 318.4);
      expect(stats.highestGameScore, 21.7);
      expect(stats.lowestGameScore, -9.0);
      expect(stats.highestHandScore, 8.3);
      expect(stats.currentWinStreak, 2);
      expect(stats.bestWinStreak, 5);
      expect(stats.lastPlayedAt, DateTime.utc(2026, 8, 10, 9, 34, 11));
    });

    test('lastPlayedAt is null for a scope never played', () {
      // The only nullable timestamp in the API. It arrives as an explicit
      // JSON null rather than as a zero-value date, because
      // "0001-01-01T00:00:00Z" would render as a real date in a list — and a
      // decoder that turned it into DateTime(0) would hide that bug.
      final never = ScopeStats.fromJson(
        decode('''
{
  "scope": "lan",
  "gamesPlayed": 0, "gamesCompleted": 0, "gamesWon": 0, "gamesLost": 0,
  "bestPlace": 0, "handsPlayed": 0,
  "totalBid": 0, "bidsMade": 0, "bidsFailed": 0, "highestBid": 0,
  "totalTricks": 0, "totalScore": 0,
  "highestGameScore": 0, "lowestGameScore": 0, "highestHandScore": 0,
  "currentWinStreak": 0, "bestWinStreak": 0,
  "lastPlayedAt": null
}
'''),
      );

      expect(never.scope, StatsScope.lan);
      expect(never.hasPlayed, isFalse);
      expect(never.lastPlayedAt, isNull);

      // Omitting the key entirely means the same thing.
      expect(ScopeStats.fromJson(decode('{"scope":"bots"}')).lastPlayedAt, isNull);

      // Every other field on an unplayed scope is a meaningful zero, so none
      // of them is allowed to be null.
      expect(never.gamesPlayed, 0);
      expect(never.bestPlace, 0);
      expect(never.totalScore, 0);
    });

    test('gameSummary timestamps are always concrete strings', () {
      // Unlike lastPlayedAt, these are never null on the wire — but a game
      // still in progress simply has no finishedAt key yet.
      final game = GameSummary.fromJson(decode(gameSummaryJson));
      expect(game.startedAt, isNotNull);
      expect(game.finishedAt, isNotNull);
      expect(game.playedAt, game.finishedAt);
    });

    test('an added field is ignored rather than fatal', () {
      // API.md is explicit that adding a field is a safe, unversioned change.
      // A client that threw here would turn a routine backend deploy into a
      // crash on every phone that had not updated yet.
      final stats = ScopeStats.fromJson(
        decode('{"scope":"bots","gamesPlayed":3,"perfectHands":9,"nested":{"a":1}}'),
      );
      expect(stats.scope, StatsScope.bots);
      expect(stats.gamesPlayed, 3);

      final game = GameSummary.fromJson(
        decode('{"id":"1","mode":"lan","tournamentId":"t1"}'),
      );
      expect(game.id, '1');
    });

    test('a missing field falls back rather than throwing', () {
      final stats = ScopeStats.fromJson(decode('{"scope":"lan"}'));
      expect(stats.gamesPlayed, 0);
      expect(stats.totalScore, 0);
      expect(stats.lastPlayedAt, isNull);

      final game = GameSummary.fromJson(decode('{}'));
      expect(game.id, isEmpty);
      expect(game.players, isEmpty);
      expect(game.you, isNull);
      expect(game.playedAt, isNull);
    });
  });

  group('endpoint envelopes', () {
    Map<String, dynamic> decode(String source) =>
        Map<String, dynamic>.from(jsonDecode(source) as Map);

    test('POST /v1/auth/device', () {
      // API.md § POST /v1/auth/device
      final auth = AuthResult.fromJson(
        decode('''
{ "token": "eyJ", "expiresAt": "2026-09-09T09:41:22Z",
  "user": { "id": "018f", "displayName": "Nabin", "isGuest": true } }
'''),
      );

      expect(auth.token, 'eyJ');
      expect(auth.expiresAt, DateTime.utc(2026, 9, 9, 9, 41, 22));
      expect(auth.user.displayName, 'Nabin');
    });

    test('POST /v1/auth/restore with an abandoned install', () {
      // API.md § POST /v1/auth/restore — the response is a session like any
      // other, plus the abandoned guest when the replaced install had games.
      final restore = RestoreResult.fromJson(
        decode('''
{ "token": "eyJ", "expiresAt": "2026-09-09T09:41:22Z",
  "user": { "id": "018f", "displayName": "Veteran", "isGuest": true },
  "abandoned": { "accountId": "018f-old", "games": 3 } }
'''),
      );

      expect(restore.session.user.id, '018f');
      expect(restore.session.token, 'eyJ');
      expect(restore.abandoned, isNotNull);
      expect(restore.abandoned!.accountId, '018f-old');
      expect(restore.abandoned!.games, 3);
    });

    test('POST /v1/auth/restore with nothing abandoned', () {
      // A restore whose install died empty omits `abandoned` entirely; the
      // decoder must not conjure an offer out of thin air.
      final restore = RestoreResult.fromJson(
        decode('''
{ "token": "eyJ",
  "user": { "id": "018f", "displayName": "Veteran", "isGuest": true } }
'''),
      );

      expect(restore.session.user.id, '018f');
      expect(restore.abandoned, isNull);
    });

    test('AbandonedAccount survives a round trip', () {
      final abandoned = AbandonedAccount(accountId: '018f-old', games: 1);
      expect(
        abandoned.toJson(),
        {'accountId': '018f-old', 'games': 1},
      );
      final decoded = AbandonedAccount.fromJson(decode('''
{ "accountId": "018f-old", "games": 7 }
'''));
      expect(decoded.accountId, '018f-old');
      expect(decoded.games, 7);
    });

    test('GET /v1/me/stats returns all five scopes in order', () {
      final bundle = StatsBundle.fromJson(
        decode('''
{ "scopes": [
  {"scope":"all","gamesPlayed":42},
  {"scope":"online","gamesPlayed":20},
  {"scope":"private","gamesPlayed":0},
  {"scope":"bots","gamesPlayed":22},
  {"scope":"lan","gamesPlayed":0}
] }
'''),
      );

      expect(
        bundle.scopes.map((s) => s.scope),
        [StatsScope.all, StatsScope.online, StatsScope.private, StatsScope.bots, StatsScope.lan],
      );
      expect(bundle.of(StatsScope.bots).gamesPlayed, 22);
      expect(bundle.of(StatsScope.lan).hasPlayed, isFalse);
    });

    test('a scope the server forgot reads as empty, not as a crash', () {
      final bundle = StatsBundle.fromJson(decode('{"scopes":[{"scope":"all"}]}'));
      expect(bundle.of(StatsScope.lan).scope, StatsScope.lan);
      expect(bundle.of(StatsScope.lan).hasPlayed, isFalse);
    });

    test('GET /v1/me/games pages on nextCursor', () {
      final page = GamePage.fromJson(
        decode('{"games":[{"id":"a","mode":"bots"}],"nextCursor":"eyJ0IjoxNzU"}'),
      );
      expect(page.games.single.id, 'a');
      expect(page.nextCursor, 'eyJ0IjoxNzU');
      expect(page.hasMore, isTrue);
    });

    test('the last page is signalled by an absent or empty cursor', () {
      // API.md allows both spellings; both have to stop the pager.
      expect(GamePage.fromJson(decode('{"games":[]}')).hasMore, isFalse);
      expect(GamePage.fromJson(decode('{"games":[],"nextCursor":""}')).hasMore, isFalse);
    });

    test('GET /v1/games/{id} carries the hand-by-hand scoreboard', () {
      // API.md § GET /v1/games/{id}
      final detail = GameDetail.fromJson(
        decode('''
{
  "game": { "id": "018f", "mode": "bots", "handsTotal": 5 },
  "hands": [
    { "handIndex": 0, "seat": 0, "bid": 3, "tricksWon": 3, "scoreDelta": 3.0, "runningTotal": 3.0 },
    { "handIndex": 0, "seat": 1, "bid": 4, "tricksWon": 2, "scoreDelta": -4.0, "runningTotal": -4.0 }
  ]
}
'''),
      );

      expect(detail.game.id, '018f');
      expect(detail.hands, hasLength(2));
      expect(detail.handIndices, [0]);

      final row = detail.cell(0, 1)!;
      expect(row.bid, 4);
      expect(row.tricksWon, 2);
      expect(row.scoreDelta, -4.0);
      expect(row.runningTotal, -4.0);

      // A seat with no row is a gap in the scorecard, not a zero somebody
      // played for.
      expect(detail.cell(0, 3), isNull);
    });

    test('POST /v1/games reports whether the idempotency key had been seen', () {
      expect(
        UploadResult.fromJson(decode('{"gameId":"018f","duplicate":false}')).duplicate,
        isFalse,
      );
      expect(
        UploadResult.fromJson(decode('{"gameId":"018f","duplicate":true}')).gameId,
        '018f',
      );
    });
  });

  group('error envelope', () {
    test('the documented shape becomes a typed exception', () {
      // API.md § Errors
      final error = ApiException.fromBody(401, <String, dynamic>{
        'error': {'code': 'unauthorized', 'message': 'Sign in again to continue.'},
      });

      expect(error.code, 'unauthorized');
      expect(error.message, 'Sign in again to continue.');
      expect(error.statusCode, 401);
      expect(error.isUnauthorized, isTrue);
      expect(error.displayMessage, 'Sign in again to continue.');
    });

    test('persistence_disabled is a state, not a fault', () {
      final error = ApiException.fromBody(503, <String, dynamic>{
        'error': {'code': 'persistence_disabled', 'message': 'No database configured.'},
      });

      expect(error.isPersistenceDisabled, isTrue);
      // Transient, so a queued upload is kept: the operator may well turn a
      // database on tomorrow.
      expect(error.isTransient, isTrue);
    });

    test('not_implemented is what auth/link answers today', () {
      final error = ApiException.fromBody(501, <String, dynamic>{
        'error': {
          'code': 'not_implemented',
          'message': 'Account upgrade is coming soon.',
        },
      });
      expect(error.isNotImplemented, isTrue);
      expect(error.displayMessage, 'Account upgrade is coming soon.');
    });

    test('a body with no envelope still produces a usable error', () {
      // A proxy in front of the server answering with HTML, or a truncated
      // response: the status code still has to decide the outcome.
      final error = ApiException.fromBody(502, const {});
      expect(error.code, 'http_502');
      expect(error.statusCode, 502);
      expect(error.displayMessage, isNotEmpty);
      expect(error.isTransient, isTrue);
    });

    test('a bare error body reads according to its status class', () {
      // Each fallback matches the app's voice for the failure it names — and,
      // critically, they differ, so a player is not told "input is wrong" when
      // the server is actually an older deployment missing the route.
      const serverDown = ApiException(code: 'http_502', message: '', statusCode: 502);
      const olderServer = ApiException(code: 'http_404', message: '', statusCode: 404);
      const throttled = ApiException(code: 'http_429', message: '', statusCode: 429);
      const badRequest = ApiException(code: 'http_400', message: '', statusCode: 400);

      expect(serverDown.displayMessage, contains('try again in a moment'));
      expect(olderServer.displayMessage, contains('older version'));
      expect(throttled.displayMessage, contains('moment'));
      expect(badRequest.displayMessage, contains('input'));
    });

    test('a fallback is never the same blank line whatever happened', () {
      const unexpected = ApiException(code: 'http_0', message: '', statusCode: 0);
      expect(unexpected.displayMessage, isNot(contains('Something went wrong')));
      expect(unexpected.displayMessage, isNotEmpty);
    });

    test('4xx is not worth retrying, 5xx and a dead network are', () {
      const bad = ApiException(code: 'bad_request', message: '', statusCode: 400);
      const rateLimited = ApiException(code: 'rate_limited', message: '', statusCode: 429);
      const offline = ApiException(code: ApiException.network, message: '');

      expect(bad.isTransient, isFalse);
      expect(rateLimited.isTransient, isTrue);
      expect(offline.isTransient, isTrue);
    });
  });

  group('websocket URL to HTTP origin', () {
    Uri origin(String url) => ApiClient.originFromSocketUrl(url);

    test('wss becomes https and the /ws path is dropped', () {
      expect(origin('wss://api.callbreak.example/ws').toString(),
          'https://api.callbreak.example');
    });

    test('ws becomes http and an explicit port is kept', () {
      expect(origin('ws://192.168.1.20:8080/ws').toString(), 'http://192.168.1.20:8080');
    });

    test('a non-default https port survives', () {
      expect(origin('wss://host:8443/ws').toString(), 'https://host:8443');
    });

    test('a URL with no /ws suffix is already an origin', () {
      expect(origin('ws://localhost:8080').toString(), 'http://localhost:8080');
      expect(origin('wss://host').toString(), 'https://host');
    });

    test('only the trailing ws segment goes, not a proxy subpath', () {
      // A reverse proxy mounting the app under /game serves /v1 under /game
      // too, so the prefix is part of the origin and must survive.
      expect(origin('wss://host/game/ws').toString(), 'https://host/game');
    });

    test('a trailing slash does not leave an empty segment behind', () {
      expect(origin('wss://host/ws/').toString(), 'https://host');
    });

    test('surrounding whitespace from a hand-typed override is tolerated', () {
      expect(origin('  ws://10.0.0.5:8080/ws  ').toString(), 'http://10.0.0.5:8080');
    });

    test('http and https pass through unchanged', () {
      expect(origin('https://host/ws').toString(), 'https://host');
      expect(origin('http://host:9000').toString(), 'http://host:9000');
    });

    test('an unrecognised scheme is assumed secure', () {
      // Guessing http for something unknown would silently downgrade a
      // production URL; guessing https only ever fails loudly.
      expect(origin('callbreak://host/ws').scheme, 'https');
    });

    test('endpoint paths hang off the origin, subpath and all', () {
      expect(
        origin('wss://host/game/ws').replace(path: '/game/v1/me/stats').toString(),
        'https://host/game/v1/me/stats',
      );
    });
  });

  group('derived figures are computed on the client', () {
    // API.md is explicit: the server sends counters only, so win rate,
    // average score and bid accuracy exist in exactly one place.
    const played = ScopeStats(
      scope: StatsScope.online,
      gamesPlayed: 42,
      gamesCompleted: 40,
      gamesWon: 17,
      gamesLost: 23,
      handsPlayed: 200,
      totalBid: 560,
      bidsMade: 141,
      bidsFailed: 59,
      totalScore: 318.4,
    );

    test('win rate is over finished games, not started ones', () {
      // 17/40, not 17/42: an abandoned game can never be won, so counting it
      // in the denominator would make quitting look like losing.
      expect(played.winRate, closeTo(0.425, 1e-9));
    });

    test('average score is the mean final score of a finished game', () {
      expect(played.averageScore, closeTo(318.4 / 40, 1e-9));
    });

    test('bid accuracy is made bids over bids placed', () {
      expect(played.bidAccuracy, closeTo(141 / 200, 1e-9));
      expect(played.averageBid, closeTo(560 / 200, 1e-9));
    });

    test('a player with zero games divides by zero exactly once: never', () {
      const fresh = ScopeStats(scope: StatsScope.lan);

      expect(fresh.hasPlayed, isFalse);
      expect(fresh.winRate, 0);
      expect(fresh.averageScore, 0);
      expect(fresh.bidAccuracy, 0);
      expect(fresh.averageBid, 0);
      // Not NaN — a tile reading "NaN%" is worse than one reading "0%".
      expect(fresh.winRate.isNaN, isFalse);
      expect(fresh.averageScore.isNaN, isFalse);
      expect(fresh.bidAccuracy.isNaN, isFalse);
    });

    test('games started but none finished still divides safely', () {
      const abandoned = ScopeStats(scope: StatsScope.bots, gamesPlayed: 3);
      expect(abandoned.hasPlayed, isTrue);
      expect(abandoned.winRate, 0);
      expect(abandoned.averageScore, 0);
    });

    test('a server that fills only the outcome counters still reads', () {
      const partial = ScopeStats(
        scope: StatsScope.bots,
        gamesPlayed: 4,
        gamesWon: 1,
        gamesLost: 3,
        handsPlayed: 20,
        bidsMade: 12,
        totalScore: 40,
      );
      expect(partial.winRate, closeTo(0.25, 1e-9));
      expect(partial.averageScore, closeTo(10, 1e-9));
      // bidsMade + bidsFailed is the denominator whenever either is present;
      // handsPlayed is only the fallback for a server that sends neither.
      expect(partial.bidAccuracy, closeTo(1.0, 1e-9));
    });
  });
}
