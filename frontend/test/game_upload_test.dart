import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:callbreak/engine/game.dart';
import 'package:callbreak/net/api_client.dart';
import 'package:callbreak/net/game_uploader.dart';
import 'package:callbreak/net/session.dart';
import 'package:callbreak/state/identity_store.dart';

/// `bots` and `lan` games are played entirely on the device, so the only thing
/// that can put them in a player's history is the device itself. That upload is
/// the one write this client must not lose — and, because the queue retries
/// blindly, the one write that must never be able to record the same game
/// twice. These tests pin both halves of that.
void main() {
  /// Answers every request with [status] and [body], and counts the uploads it
  /// saw so a retry can be told apart from a fresh delivery.
  ({ApiClient client, List<Map<String, dynamic>> uploads}) clientAnswering(
    int Function(int attempt) status, {
    String body = '{"gameId":"srv-1","duplicate":false}',
  }) {
    final uploads = <Map<String, dynamic>>[];
    final identity = IdentityStore.inMemory(deviceId: 'device-under-test');

    final http.Client transport = MockClient((request) async {
      if (request.url.path.endsWith('/v1/games')) {
        uploads.add(Map<String, dynamic>.from(jsonDecode(request.body) as Map));
        final code = status(uploads.length);
        return http.Response(
          code >= 400 ? '{"error":{"code":"bad_request","message":"nope"}}' : body,
          code,
        );
      }
      // The session handshake, so the upload path is exercised end to end.
      return http.Response(
        '{"token":"t","expiresAt":"2099-01-01T00:00:00Z",'
        '"user":{"id":"u1","displayName":"Nabin","isGuest":true}}',
        200,
      );
    });

    return (
      client: ApiClient(
        origin: Uri.parse('https://example.test'),
        identity: identity,
        httpClient: transport,
      ),
      uploads: uploads,
    );
  }

  /// A finished five-hand game, recorded the way a session records one.
  GameRecorder playedGame({GameMode mode = GameMode.bots, int youSeat = 0}) {
    final recorder = GameRecorder(mode: mode, youSeat: youSeat);
    for (var hand = 0; hand < 2; hand++) {
      recorder.recordHand(
        handIndex: hand,
        bids: const [3, 4, 2, 4],
        tricksWon: const [3, 2, 5, 3],
        deltas: const [3.0, -4.0, 2.3, -4.0],
      );
    }
    return recorder;
  }

  Map<String, dynamic> payloadOf(GameRecorder recorder) => recorder.build(
    players: const [
      PlayerInfo(seat: 0, name: 'Nabin', kind: PlayerKind.human),
      PlayerInfo(seat: 1, name: 'Amit', kind: PlayerKind.bot),
      PlayerInfo(seat: 2, name: 'Riya', kind: PlayerKind.bot),
      PlayerInfo(seat: 3, name: 'Sujan', kind: PlayerKind.bot),
    ],
    totals: const [6.0, -8.0, 4.6, -8.0],
    rankings: const [
      SeatRanking(0, 1, 6.0),
      SeatRanking(2, 2, 4.6),
      SeatRanking(1, 3, -8.0),
      SeatRanking(3, 4, -8.0),
    ],
    handsTotal: 5,
  )!;

  group('the recorded payload matches POST /v1/games', () {
    test('exactly one seat is the caller', () {
      final payload = payloadOf(playedGame());
      final seats = (payload['seats'] as List).cast<Map<String, dynamic>>();

      expect(seats, hasLength(4));
      expect(seats.where((s) => s['isYou'] == true), hasLength(1));
      expect(seats.firstWhere((s) => s['isYou'] == true)['seat'], 0);
      expect(seats.map((s) => s['seat']).toSet(), {0, 1, 2, 3});
    });

    test('seat totals are accumulated across hands, not re-read at the end', () {
      // The engine clears bids and tricks on every deal, so these can only be
      // right if each hand was snapshotted as it finished.
      final seats = (payloadOf(playedGame())['seats'] as List)
          .cast<Map<String, dynamic>>();
      final you = seats.firstWhere((s) => s['seat'] == 0);

      expect(you['totalBid'], 6); // 3 + 3
      expect(you['totalTricks'], 6); // 3 + 3
      expect(you['handsMade'], 2); // made the bid both times
      expect(you['finalScore'], 6.0);
      expect(you['place'], 1);

      final failed = seats.firstWhere((s) => s['seat'] == 1);
      expect(failed['totalBid'], 8);
      expect(failed['handsMade'], 0); // bid 4, took 2, both hands
      expect(failed['isBot'], isTrue);
      expect(failed['botDifficulty'], 'normal');
    });

    test('hand rows carry a running total rounded like the scoreboard', () {
      final hands = (payloadOf(playedGame())['hands'] as List)
          .cast<Map<String, dynamic>>();

      expect(hands, hasLength(8)); // 2 hands x 4 seats
      expect(hands.first.keys, containsAll(<String>[
        'handIndex', 'seat', 'bid', 'tricksWon', 'scoreDelta', 'runningTotal',
      ]));

      final seatTwo = hands.where((h) => h['seat'] == 2).toList();
      expect(seatTwo[0]['runningTotal'], 2.3);
      // 2.3 + 2.3 in binary floating point is 4.6000000000000005; the engine
      // rounds to one decimal and so must this, or the server stores a total
      // the player never saw.
      expect(seatTwo[1]['runningTotal'], 4.6);
    });

    test('the envelope names the mode and both timestamps', () {
      final payload = payloadOf(playedGame(mode: GameMode.lan, youSeat: 0));

      expect(payload['mode'], 'lan');
      expect(payload['completed'], isTrue);
      expect(payload['handsTotal'], 5);
      expect(DateTime.tryParse(payload['startedAt'] as String), isNotNull);
      expect(DateTime.tryParse(payload['finishedAt'] as String), isNotNull);
    });

    test('server-played modes are never uploaded', () {
      // API.md: `mode` must be `bots` or `lan`. Sending an online game would
      // be rejected, and the queue would carry it forever.
      for (final mode in const [GameMode.online, GameMode.private]) {
        final recorder = playedGame(mode: mode);
        expect(recorder.isUploadable, isFalse, reason: mode.name);
        expect(
          recorder.build(
            players: const [PlayerInfo(seat: 0, name: 'A', kind: PlayerKind.human)],
            totals: const [0],
            rankings: const [],
            handsTotal: 5,
          ),
          isNull,
        );
      }
    });

    test('a table abandoned before a single hand has nothing to upload', () {
      final recorder = GameRecorder(mode: GameMode.bots, youSeat: 0);
      expect(recorder.handsRecorded, 0);
      expect(
        recorder.build(
          players: const [PlayerInfo(seat: 0, name: 'A', kind: PlayerKind.human)],
          totals: const [0],
          rankings: const [],
          handsTotal: 5,
        ),
        isNull,
      );
    });
  });

  group('the queue retries without duplicating', () {
    test('the clientGameId is minted at kick-off and never changes', () {
      // This is the whole idempotency guarantee: the id exists before the
      // first attempt, so a retry names the game the server may already have.
      final recorder = GameRecorder(mode: GameMode.bots, youSeat: 0);
      final atStart = recorder.clientGameId;

      recorder.recordHand(
        handIndex: 0,
        bids: const [1, 1, 1, 1],
        tricksWon: const [1, 1, 1, 1],
        deltas: const [1, 1, 1, 1],
      );

      expect(payloadOf(recorder)['clientGameId'], atStart);
      expect(atStart, hasLength(36));
      expect(atStart, matches(RegExp(r'^[0-9a-f-]{36}$')));
    });

    test('two games get two ids', () {
      expect(
        GameRecorder(mode: GameMode.bots, youSeat: 0).clientGameId,
        isNot(GameRecorder(mode: GameMode.bots, youSeat: 0).clientGameId),
      );
    });

    test('enqueue then fail then retry sends the identical clientGameId', () async {
      // First attempt 500, second 200 — exactly the shape of a phone that lost
      // its connection mid-upload and came back.
      final harness = clientAnswering((attempt) => attempt == 1 ? 500 : 200);
      final uploader = GameUploader(client: harness.client);
      final payload = payloadOf(playedGame());
      final id = payload['clientGameId'] as String;

      await uploader.enqueue(payload);

      // Kept, because a 5xx is a reason to try again rather than to give up.
      expect(uploader.pending, 1);
      expect(uploader.pendingGameIds, [id]);
      expect(harness.uploads, hasLength(1));

      await uploader.drain();

      expect(uploader.pending, 0);
      expect(harness.uploads, hasLength(2));
      // The retry is byte-for-byte the same game, which is what lets the
      // server answer `duplicate: true` instead of recording it twice.
      expect(harness.uploads[1]['clientGameId'], id);
      expect(harness.uploads[0]['clientGameId'], harness.uploads[1]['clientGameId']);
    });

    test('a 4xx drops the entry — a retry cannot make a bad body good', () async {
      final harness = clientAnswering((_) => 400);
      final uploader = GameUploader(client: harness.client);

      await uploader.enqueue(payloadOf(playedGame()));

      expect(harness.uploads, hasLength(1));
      expect(uploader.pending, 0);

      // And it stays gone: nothing is re-sent on the next drain.
      await uploader.drain();
      expect(harness.uploads, hasLength(1));
    });

    test('a 5xx keeps the entry for the next launch', () async {
      final harness = clientAnswering((_) => 503);
      final uploader = GameUploader(client: harness.client);

      await uploader.enqueue(payloadOf(playedGame()));
      expect(uploader.pending, 1);

      await uploader.drain();
      expect(uploader.pending, 1);
      expect(harness.uploads, hasLength(2));
    });

    test('a queue left behind by the last run is drained on launch', () async {
      final first = clientAnswering((_) => 500);
      final uploader = GameUploader(client: first.client);
      await uploader.enqueue(payloadOf(playedGame()));
      final carried = uploader.pendingGameIds.single;

      // Next launch: same on-disk queue, a server that is answering again.
      final second = clientAnswering((_) => 200);
      final restarted = GameUploader(
        client: second.client,
        queued: [for (final id in uploader.pendingGameIds) jsonEncode({'clientGameId': id})],
      );
      await restarted.drain();

      expect(restarted.pending, 0);
      expect(second.uploads.single['clientGameId'], carried);
    });

    test('order is preserved and a stuck entry blocks the ones behind it',
        () async {
      // Stopping at the first retryable failure keeps history in the order it
      // was played, rather than in the order the network happened to recover.
      var online = false;
      final harness = clientAnswering((_) => online ? 200 : 500);
      final uploader = GameUploader(client: harness.client);

      final first = payloadOf(playedGame());
      final second = payloadOf(playedGame());
      await uploader.enqueue(first);
      await uploader.enqueue(second);

      // Neither got through, and the second never even got a turn.
      expect(uploader.pendingGameIds, [
        first['clientGameId'],
        second['clientGameId'],
      ]);
      expect(
        harness.uploads.map((u) => u['clientGameId']).toSet(),
        {first['clientGameId']},
      );

      online = true;
      await uploader.drain();

      expect(uploader.pending, 0);
      expect(
        harness.uploads.map((u) => u['clientGameId']).toList(),
        [
          first['clientGameId'],
          first['clientGameId'],
          first['clientGameId'],
          second['clientGameId'],
        ],
      );
    });

    test('an unreadable entry is dropped rather than retried forever', () async {
      final harness = clientAnswering((_) => 200);
      final uploader = GameUploader(client: harness.client, queued: const ['not json']);

      await uploader.drain();

      expect(uploader.pending, 0);
      expect(harness.uploads, isEmpty);
    });

    test('a dead network never throws at the caller', () async {
      // Gameplay calls this and walks away; an exception escaping here would
      // surface as a crash at exactly the wrong moment.
      final identity = IdentityStore.inMemory();
      final client = ApiClient(
        origin: Uri.parse('https://example.test'),
        identity: identity,
        httpClient: MockClient((_) => throw const SocketFailure()),
      );
      final uploader = GameUploader(client: client);

      await expectLater(uploader.enqueue(payloadOf(playedGame())), completes);
      expect(uploader.pending, 1);
    });
  });
}

/// Stands in for whatever `dart:io` throws when there is no network.
class SocketFailure implements Exception {
  const SocketFailure();
}
