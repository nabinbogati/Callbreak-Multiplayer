import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../engine/game.dart';
import '../state/identity_store.dart';
import 'api_client.dart';
import 'session.dart';

/// Accumulates the `POST /v1/games` body while an offline game is played.
///
/// `bots` and `lan` tables never touch the server (`docs/PERSISTENCE.md` §2.2),
/// so the device is the only thing that can put them in the player's history.
/// The engine cannot supply the payload on its own: [CallBreakGame.bids] and
/// [CallBreakGame.tricksWon] are cleared on every deal, so the per-hand rows
/// have to be snapshotted as each hand ends rather than reconstructed at the
/// end from state that no longer exists.
///
/// [clientGameId] is minted **here, at construction** — when the game starts,
/// not when it finishes. That is the whole of the idempotency guarantee: the
/// id is part of the payload before the first upload attempt, so every retry
/// of a failed upload carries the id the server may already have seen and gets
/// the original game back instead of creating a second one.
class GameRecorder {
  GameRecorder({
    required this.mode,
    required this.youSeat,
    String? clientGameId,
    DateTime? startedAt,
  }) : clientGameId = clientGameId ?? uuidV4(),
       startedAt = startedAt ?? DateTime.now().toUtc();

  final GameMode mode;

  /// The seat this device plays. Exactly one seat may be uploaded with
  /// `isYou: true`; the server binds that one to the caller's account and
  /// stores every other seat with a null user, so a client cannot write
  /// history onto somebody else.
  final int youSeat;
  final String clientGameId;
  final DateTime startedAt;

  final List<Map<String, dynamic>> _hands = [];
  final List<double> _running = List.filled(4, 0);
  final List<int> _totalBid = List.filled(4, 0);
  final List<int> _totalTricks = List.filled(4, 0);
  final List<int> _handsMade = List.filled(4, 0);
  int _handsRecorded = 0;

  /// Whether this game is one the server will accept. Only the two modes
  /// played entirely on the device may be uploaded.
  bool get isUploadable => mode == GameMode.bots || mode == GameMode.lan;

  /// Snapshots one finished hand. Call it while the engine still holds that
  /// hand's bids and tricks — from the [HandOver] event, before the next deal.
  void recordHand({
    required int handIndex,
    required List<int?> bids,
    required List<int> tricksWon,
    required List<double> deltas,
  }) {
    _handsRecorded += 1;
    for (var seat = 0; seat < 4; seat++) {
      final bid = seat < bids.length ? (bids[seat] ?? 0) : 0;
      final tricks = seat < tricksWon.length ? tricksWon[seat] : 0;
      final delta = seat < deltas.length ? deltas[seat] : 0.0;

      // Rounded exactly the way the engine rounds its own totals, so the
      // running column the server stores matches the scoreboard the player saw.
      _running[seat] = ((_running[seat] + delta) * 10).round() / 10;
      _totalBid[seat] += bid;
      _totalTricks[seat] += tricks;
      if (tricks >= bid) _handsMade[seat] += 1;

      _hands.add({
        'handIndex': handIndex,
        'seat': seat,
        'bid': bid,
        'tricksWon': tricks,
        'scoreDelta': delta,
        'runningTotal': _running[seat],
      });
    }
  }

  /// The finished payload, or null when there is nothing worth uploading — an
  /// unsupported mode, or a table abandoned before a single hand was scored.
  Map<String, dynamic>? build({
    required List<PlayerInfo> players,
    required List<double> totals,
    required List<SeatRanking> rankings,
    required int handsTotal,
    bool completed = true,
    DateTime? finishedAt,
  }) {
    if (!isUploadable || _hands.isEmpty) return null;

    final placeOf = {for (final ranking in rankings) ranking.seat: ranking.place};

    return {
      'clientGameId': clientGameId,
      'mode': mode.name,
      'completed': completed,
      'handsTotal': handsTotal,
      'startedAt': startedAt.toIso8601String(),
      'finishedAt': (finishedAt ?? DateTime.now().toUtc()).toIso8601String(),
      'seats': [
        for (final player in players)
          {
            'seat': player.seat,
            'isYou': player.seat == youSeat,
            'displayName': player.name,
            'isBot': player.isBot,
            if (player.isBot) 'botDifficulty': player.difficulty.name,
            'finalScore': player.seat < totals.length ? totals[player.seat] : 0.0,
            'place': placeOf[player.seat] ?? 0,
            'totalBid': _totalBid[player.seat],
            'totalTricks': _totalTricks[player.seat],
            'handsMade': _handsMade[player.seat],
          },
      ],
      'hands': _hands,
    };
  }

  /// How many hands have been snapshotted so far.
  int get handsRecorded => _handsRecorded;
}

/// The on-disk queue of offline games waiting to reach the server.
///
/// Everything here is fire-and-forget by construction: [enqueue] and [drain]
/// swallow every error, and nothing on the gameplay path ever awaits them. A
/// player who finishes a game on a train must not be shown a network error,
/// and must not wait on one either — the worst outcome of a failed upload is
/// that the game shows up in their history later.
///
/// Because `POST /v1/games` is idempotent on the `clientGameId` the recorder
/// minted at kick-off, the queue can retry blindly: a payload that reached the
/// server but whose response was lost comes back as `duplicate: true` on the
/// next attempt and is dropped, having recorded nothing twice.
class GameUploader {
  GameUploader({required this.client, SharedPreferences? prefs, List<String>? queued})
    : _prefs = prefs,
      _queue = [...?queued] {
    // A successful call of any kind is the cheapest possible proof that the
    // network is back, and costs nothing to listen for.
    client.onServerReachable = () => unawaited(drain());
  }

  static const _kQueue = 'upload.queue';

  /// A queue that has grown past this has stopped being a retry buffer and
  /// started being a leak — the oldest entries go first, since the newest
  /// games are the ones a player expects to see in their history.
  static const _maxQueued = 50;

  /// The process-wide uploader, null until [install] runs. Sessions reach it
  /// through here rather than being handed one, so a table constructed in a
  /// test simply records nothing instead of needing a stub.
  static GameUploader? instance;

  final ApiClient client;
  final SharedPreferences? _prefs;
  final List<String> _queue;
  bool _draining = false;

  /// Loads the queue left behind by the last run.
  static Future<GameUploader> open({required ApiClient client}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return GameUploader(
        client: client,
        prefs: prefs,
        queued: prefs.getStringList(_kQueue),
      );
    } catch (_) {
      // No storage: uploads still work while the app is running, they just do
      // not survive a restart. Strictly better than not uploading at all.
      return GameUploader(client: client);
    }
  }

  /// Installs [uploader] as the process-wide instance and drains whatever the
  /// last run could not deliver.
  static void install(GameUploader uploader) {
    instance = uploader;
    unawaited(uploader.drain());
  }

  /// Games still waiting to be delivered.
  int get pending => _queue.length;

  /// The `clientGameId`s currently queued, oldest first. Exposed so the
  /// idempotency property is testable without reaching into storage.
  List<String> get pendingGameIds => [
    for (final entry in _queue) ?_clientGameIdOf(entry),
  ];

  /// Queues a finished offline game and starts trying to deliver it. Never
  /// throws, never blocks the caller on the network.
  Future<void> enqueue(Map<String, dynamic> payload) async {
    try {
      _queue.add(jsonEncode(payload));
      while (_queue.length > _maxQueued) {
        _queue.removeAt(0);
      }
      await _persist();
    } catch (_) {
      return;
    }
    await drain();
  }

  /// Delivers everything queued, in order, stopping at the first entry that
  /// failed for a reason a retry could fix.
  ///
  /// Ordering matters less than not losing anything, but keeping it means a
  /// player's history reads in the order they played rather than in the order
  /// the network happened to recover.
  Future<void> drain() async {
    if (_draining || _queue.isEmpty) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final entry = _queue.first;
        final payload = _decode(entry);
        if (payload == null) {
          // Unreadable — written by a build whose payload shape is gone. It
          // can never be delivered, so it can only be dropped.
          _queue.removeAt(0);
          await _persist();
          continue;
        }

        try {
          // Any 2xx drops the entry, and the `duplicate` flag in the response
          // is deliberately not read: it is advisory, and a queue that only
          // dropped on `duplicate: false` would re-send forever the moment the
          // server started answering honestly.
          await client.uploadGame(payload);
        } on ApiException catch (error) {
          // Transient — no network, a timeout, a 5xx, a rate limit, or a
          // server with persistence switched off. Keep it and stop: the next
          // launch or the next successful call tries again.
          if (error.isTransient) return;
          // A 4xx says the payload itself is wrong. Retrying an identical
          // body cannot make it right, so drop it rather than retry forever.
        } catch (_) {
          return;
        }

        _queue.removeAt(0);
        await _persist();
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _persist() async {
    try {
      await _prefs?.setStringList(_kQueue, _queue);
    } catch (_) {
      // In-memory queue still stands; it just will not survive a restart.
    }
  }

  static Map<String, dynamic>? _decode(String entry) {
    try {
      final decoded = jsonDecode(entry);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static String? _clientGameIdOf(String entry) {
    final id = _decode(entry)?['clientGameId'];
    return id is String ? id : null;
  }
}
