import 'session.dart';

/// Wire models for the REST surface described by `backend/docs/API.md`.
///
/// Every decoder here is deliberately total: a missing key falls back to a
/// zero value and an unknown one is ignored, the same contract
/// [GameView.fromJson] holds on the socket. The document is explicit that
/// *adding* a field is a safe, unversioned change on the server — so a client
/// that throws on an unexpected shape would turn a routine backend deploy into
/// a crash on every phone that had not updated yet.
///
/// Nothing derived is decoded. Win rate, average score and bid accuracy are
/// computed from the raw counters on [ScopeStats], because API.md is explicit
/// that the server does not send them and two sources for one number always
/// end up disagreeing.

// --------------------------------------------------------------- primitives

int _int(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;

double _double(Object? value, [double fallback = 0]) =>
    value is num ? value.toDouble() : fallback;

String _string(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

bool _bool(Object? value, [bool fallback = false]) =>
    value is bool ? value : fallback;

/// RFC 3339 in, UTC [DateTime] out. Null for a missing or unparseable stamp,
/// which the UI renders as "—" rather than as the epoch.
DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

Map<String, dynamic> _object(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

List<Map<String, dynamic>> _objects(Object? value) => value is List
    ? [
        for (final entry in value)
          if (entry is Map) Map<String, dynamic>.from(entry),
      ]
    : const [];

// -------------------------------------------------------------------- users

/// One way a player can prove they are themselves. `device` is the guest
/// anchor every account starts with; the rest arrive by linking.
enum AuthProvider { device, google, facebook, apple, unknown }

extension AuthProviderInfo on AuthProvider {
  String get label => switch (this) {
    AuthProvider.device => 'This device',
    AuthProvider.google => 'Google',
    AuthProvider.facebook => 'Facebook',
    AuthProvider.apple => 'Apple',
    AuthProvider.unknown => 'Unknown',
  };

  static AuthProvider parse(String name) => AuthProvider.values.firstWhere(
    (provider) => provider.name == name,
    orElse: () => AuthProvider.unknown,
  );
}

class UserIdentity {
  const UserIdentity({required this.provider, this.linkedAt});

  final AuthProvider provider;
  final DateTime? linkedAt;

  Map<String, dynamic> toJson() => {
    'provider': provider.name,
    if (linkedAt != null) 'linkedAt': linkedAt!.toIso8601String(),
  };

  factory UserIdentity.fromJson(Map<String, dynamic> json) => UserIdentity(
    provider: AuthProviderInfo.parse(_string(json['provider'], 'unknown')),
    linkedAt: _time(json['linkedAt']),
  );
}

class UserProfile {
  const UserProfile({
    required this.id,
    required this.displayName,
    required this.isGuest,
    this.avatarId = '',
    this.country = '',
    this.createdAt,
    this.lastSeenAt,
    this.identities = const [],
  });

  final String id;
  final String displayName;
  final bool isGuest;
  final String avatarId;
  final String country;
  final DateTime? createdAt;
  final DateTime? lastSeenAt;
  final List<UserIdentity> identities;

  /// Sign-in methods that carry the account to another phone. A `device`
  /// identity does not: it names one install (`docs/PERSISTENCE.md` §1.3).
  List<UserIdentity> get portableIdentities =>
      identities.where((i) => i.provider != AuthProvider.device).toList();

  bool get isLinked => portableIdentities.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'isGuest': isGuest,
    'avatarId': avatarId,
    'country': country,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    if (lastSeenAt != null) 'lastSeenAt': lastSeenAt!.toIso8601String(),
    'identities': [for (final identity in identities) identity.toJson()],
  };

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: _string(json['id']),
    displayName: _string(json['displayName']),
    isGuest: _bool(json['isGuest'], true),
    avatarId: _string(json['avatarId']),
    country: _string(json['country']),
    createdAt: _time(json['createdAt']),
    lastSeenAt: _time(json['lastSeenAt']),
    identities: [
      for (final entry in _objects(json['identities'])) UserIdentity.fromJson(entry),
    ],
  );
}

/// The body `auth/device`, `auth/refresh` and (one day) `auth/link` all share.
class AuthResult {
  const AuthResult({required this.token, this.expiresAt, required this.user});

  final String token;
  final DateTime? expiresAt;
  final UserProfile user;

  factory AuthResult.fromJson(Map<String, dynamic> json) => AuthResult(
    token: _string(json['token']),
    expiresAt: _time(json['expiresAt']),
    user: UserProfile.fromJson(_object(json['user'])),
  );
}

/// The guest account a restore left behind, still carrying games nobody has
/// decided on yet. The id is only meaningful to this device until the player
/// chooses to merge it in or discard it, so it is a decision to resolve, not a
/// profile — hence it is offered separately from the restored [UserProfile].
class AbandonedAccount {
  const AbandonedAccount({required this.accountId, required this.games});

  final String accountId;

  /// How many games that install had when it was replaced.
  final int games;

  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'games': games,
  };

  factory AbandonedAccount.fromJson(Map<String, dynamic> json) => AbandonedAccount(
    accountId: _string(json['accountId']),
    games: _int(json['games']),
  );
}

/// `POST /v1/auth/restore` returns a session like any other auth call — which
/// is what [session] is — plus, when the install being replaced had games, the
/// abandoned guest it left behind. Omitted entirely when the replaced install
/// had no history (it was deleted outright) or the restore was a no-op.
class RestoreResult {
  const RestoreResult({required this.session, this.abandoned});

  final AuthResult session;
  final AbandonedAccount? abandoned;

  factory RestoreResult.fromJson(Map<String, dynamic> json) => RestoreResult(
    session: AuthResult.fromJson(json),
    abandoned: json['abandoned'] is Map
        ? AbandonedAccount.fromJson(_object(json['abandoned']))
        : null,
  );
}

// -------------------------------------------------------------------- games

/// One seat in a recorded game.
///
/// Covers both shapes API.md uses for a seat: the `players[]` entries, which
/// carry who sat there, and the `you` object, which carries the caller's own
/// bidding totals. Neither has every field, so both sides are optional-by-
/// default rather than modelled as two nearly identical classes.
class GamePlayer {
  const GamePlayer({
    required this.seat,
    this.userId,
    this.displayName = '',
    this.isBot = false,
    this.finalScore = 0,
    this.place = 0,
    this.totalBid = 0,
    this.totalTricks = 0,
  });

  final int seat;
  final String? userId;
  final String displayName;
  final bool isBot;
  final double finalScore;

  /// 1–4, or 0 when the game was abandoned before anyone was ranked.
  final int place;
  final int totalBid;
  final int totalTricks;

  bool get isRanked => place >= 1 && place <= 4;
  bool get isWinner => place == 1;

  factory GamePlayer.fromJson(Map<String, dynamic> json) => GamePlayer(
    seat: _int(json['seat']),
    userId: json['userId'] is String ? json['userId'] as String : null,
    displayName: _string(json['displayName']),
    isBot: _bool(json['isBot']),
    finalScore: _double(json['finalScore']),
    place: _int(json['place']),
    totalBid: _int(json['totalBid']),
    totalTricks: _int(json['totalTricks']),
  );
}

class GameSummary {
  const GameSummary({
    required this.id,
    required this.mode,
    this.roomCode = '',
    this.completed = false,
    this.startedAt,
    this.finishedAt,
    this.handsTotal = 0,
    this.you,
    this.players = const [],
  });

  final String id;

  /// The raw wire value (`bots`, `private`, `online`, `lan`). Kept as a string
  /// so a mode this build has never heard of still renders as itself rather
  /// than as whatever the enum's fallback happens to be.
  final String mode;
  final String roomCode;
  final bool completed;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final int handsTotal;

  /// The caller's own seat. Absent on a game the caller only spectated.
  final GamePlayer? you;
  final List<GamePlayer> players;

  /// The app's own mode enum, when the server's value maps onto one.
  GameMode? get gameMode {
    for (final value in GameMode.values) {
      if (value.name == mode) return value;
    }
    return null;
  }

  /// The play-mode name for a history row or scorecard. Online games split by
  /// length: a 3-hand match is Quickplay and a 5-hand one is Normal Play, the
  /// same vocabulary as the join sheet — "vs Humans" alone cannot tell the two
  /// apart.
  String get modeLabel {
    if (gameMode case GameMode.online) {
      return switch (handsTotal) {
        3 => 'Quickplay',
        5 => 'Normal Play',
        _ => GameMode.online.label,
      };
    }
    return gameMode?.label ?? mode;
  }

  /// Everyone but the caller, in seat order — the "opponents" line.
  List<GamePlayer> get opponents =>
      players.where((player) => player.seat != you?.seat).toList();

  /// When to sort and stamp this game by. A game that never finished still has
  /// a start, and showing it as undated would push it to the bottom of a
  /// reverse-chronological list where it is least likely to be understood.
  DateTime? get playedAt => finishedAt ?? startedAt;

  factory GameSummary.fromJson(Map<String, dynamic> json) => GameSummary(
    id: _string(json['id']),
    mode: _string(json['mode']),
    roomCode: _string(json['roomCode']),
    completed: _bool(json['completed']),
    startedAt: _time(json['startedAt']),
    finishedAt: _time(json['finishedAt']),
    handsTotal: _int(json['handsTotal']),
    you: json['you'] is Map ? GamePlayer.fromJson(_object(json['you'])) : null,
    players: [for (final entry in _objects(json['players'])) GamePlayer.fromJson(entry)],
  );
}

/// One seat's line on one hand of the scoreboard.
class HandRecord {
  const HandRecord({
    required this.handIndex,
    required this.seat,
    this.bid = 0,
    this.tricksWon = 0,
    this.scoreDelta = 0,
    this.runningTotal = 0,
  });

  final int handIndex;
  final int seat;
  final int bid;
  final int tricksWon;
  final double scoreDelta;
  final double runningTotal;

  Map<String, dynamic> toJson() => {
    'handIndex': handIndex,
    'seat': seat,
    'bid': bid,
    'tricksWon': tricksWon,
    'scoreDelta': scoreDelta,
    'runningTotal': runningTotal,
  };

  factory HandRecord.fromJson(Map<String, dynamic> json) => HandRecord(
    handIndex: _int(json['handIndex']),
    seat: _int(json['seat']),
    bid: _int(json['bid']),
    tricksWon: _int(json['tricksWon']),
    scoreDelta: _double(json['scoreDelta']),
    runningTotal: _double(json['runningTotal']),
  );
}

/// `GET /v1/games/{id}`: the summary plus its hand-by-hand scoreboard.
class GameDetail {
  const GameDetail({required this.game, this.hands = const []});

  final GameSummary game;

  /// Ordered by `handIndex`, then `seat`.
  final List<HandRecord> hands;

  /// The distinct hand indices present, ascending — the rows of a scorecard.
  List<int> get handIndices {
    final seen = <int>{for (final hand in hands) hand.handIndex};
    return seen.toList()..sort();
  }

  /// `[handIndex][seat]`, for the scorecard grid. Missing cells stay null so a
  /// partial upload renders as a gap rather than as a zero somebody played for.
  HandRecord? cell(int handIndex, int seat) {
    for (final hand in hands) {
      if (hand.handIndex == handIndex && hand.seat == seat) return hand;
    }
    return null;
  }

  factory GameDetail.fromJson(Map<String, dynamic> json) => GameDetail(
    game: GameSummary.fromJson(_object(json['game'])),
    hands: [for (final entry in _objects(json['hands'])) HandRecord.fromJson(entry)],
  );
}

/// One page of `GET /v1/me/games`.
class GamePage {
  const GamePage({this.games = const [], this.nextCursor});

  final List<GameSummary> games;

  /// Keyset cursor for the next page, or null on the last one. API.md allows
  /// either an absent key or `""`; both mean the same thing, so both normalise
  /// to null here and the list stops asking.
  final String? nextCursor;

  bool get hasMore => nextCursor != null && nextCursor!.isNotEmpty;

  factory GamePage.fromJson(Map<String, dynamic> json) {
    final cursor = _string(json['nextCursor']);
    return GamePage(
      games: [for (final entry in _objects(json['games'])) GameSummary.fromJson(entry)],
      nextCursor: cursor.isEmpty ? null : cursor,
    );
  }
}

/// `POST /v1/games` — `duplicate` is true when the idempotency key matched an
/// upload the server already had, which is the normal outcome of a retry.
class UploadResult {
  const UploadResult({required this.gameId, this.duplicate = false});

  final String gameId;
  final bool duplicate;

  factory UploadResult.fromJson(Map<String, dynamic> json) => UploadResult(
    gameId: _string(json['gameId']),
    duplicate: _bool(json['duplicate']),
  );
}

// -------------------------------------------------------------------- stats

/// The five buckets `GET /v1/me/stats` always returns, in its own order.
enum StatsScope { all, online, private, bots, lan }

extension StatsScopeInfo on StatsScope {
  /// Matches the play-mode vocabulary on the home screen: the server calls
  /// quickplay `online`, but nowhere in this app does the player ever see that
  /// word.
  String get label => switch (this) {
    StatsScope.all => 'All',
    StatsScope.online => 'vs Humans',
    StatsScope.private => 'Private',
    StatsScope.bots => 'vs Bots',
    StatsScope.lan => 'LAN',
  };

  static StatsScope parse(String name) => StatsScope.values.firstWhere(
    (scope) => scope.name == name,
    orElse: () => StatsScope.all,
  );
}

class ScopeStats {
  const ScopeStats({
    required this.scope,
    this.gamesPlayed = 0,
    this.gamesCompleted = 0,
    this.gamesWon = 0,
    this.gamesLost = 0,
    this.bestPlace = 0,
    this.handsPlayed = 0,
    this.totalBid = 0,
    this.bidsMade = 0,
    this.bidsFailed = 0,
    this.highestBid = 0,
    this.totalTricks = 0,
    this.totalScore = 0,
    this.highestGameScore = 0,
    this.lowestGameScore = 0,
    this.highestHandScore = 0,
    this.currentWinStreak = 0,
    this.bestWinStreak = 0,
    this.lastPlayedAt,
  });

  final StatsScope scope;
  final int gamesPlayed;
  final int gamesCompleted;
  final int gamesWon;
  final int gamesLost;
  final int bestPlace;
  final int handsPlayed;
  final int totalBid;
  final int bidsMade;
  final int bidsFailed;
  final int highestBid;
  final int totalTricks;
  final double totalScore;
  final double highestGameScore;
  final double lowestGameScore;
  final double highestHandScore;
  final int currentWinStreak;
  final int bestWinStreak;

  /// The only nullable timestamp in the API: null for a scope never played.
  /// Every other field here is a number with a meaningful zero, which a date
  /// does not have — a zero-value stamp would render as a real date, and
  /// "last played 1 Jan 0001" is worse than no row at all.
  final DateTime? lastPlayedAt;

  /// Whether this scope has anything worth rendering. A scope with no games is
  /// shown as an invitation to play it, not as a wall of zeros.
  bool get hasPlayed => gamesPlayed > 0;

  /// Share of *finished* games won, 0–1.
  ///
  /// The denominator is `gamesCompleted`, not `gamesPlayed`: an abandoned game
  /// counts toward "games I started" but can never be won, so counting it here
  /// would make quitting look like losing (`docs/PERSISTENCE.md` §2.3). Falls
  /// back to won+lost for a server that only fills the outcome counters.
  double get winRate {
    final decided = gamesCompleted > 0 ? gamesCompleted : gamesWon + gamesLost;
    return decided > 0 ? gamesWon / decided : 0;
  }

  /// Mean final score across finished games.
  double get averageScore {
    final decided = gamesCompleted > 0 ? gamesCompleted : gamesWon + gamesLost;
    return decided > 0 ? totalScore / decided : 0;
  }

  /// Share of hands where the bid was made, 0–1. Falls back to `handsPlayed`
  /// when the made/failed split is absent — the two agree by construction.
  double get bidAccuracy {
    final bidded = bidsMade + bidsFailed > 0 ? bidsMade + bidsFailed : handsPlayed;
    return bidded > 0 ? bidsMade / bidded : 0;
  }

  /// Mean bid per hand, for reading bid accuracy in context: 80% on an average
  /// bid of 2 is a very different player from 80% on an average bid of 5.
  double get averageBid => handsPlayed > 0 ? totalBid / handsPlayed : 0;

  factory ScopeStats.fromJson(Map<String, dynamic> json) => ScopeStats(
    scope: StatsScopeInfo.parse(_string(json['scope'], 'all')),
    gamesPlayed: _int(json['gamesPlayed']),
    gamesCompleted: _int(json['gamesCompleted']),
    gamesWon: _int(json['gamesWon']),
    gamesLost: _int(json['gamesLost']),
    bestPlace: _int(json['bestPlace']),
    handsPlayed: _int(json['handsPlayed']),
    totalBid: _int(json['totalBid']),
    bidsMade: _int(json['bidsMade']),
    bidsFailed: _int(json['bidsFailed']),
    highestBid: _int(json['highestBid']),
    totalTricks: _int(json['totalTricks']),
    totalScore: _double(json['totalScore']),
    highestGameScore: _double(json['highestGameScore']),
    lowestGameScore: _double(json['lowestGameScore']),
    highestHandScore: _double(json['highestHandScore']),
    currentWinStreak: _int(json['currentWinStreak']),
    bestWinStreak: _int(json['bestWinStreak']),
    lastPlayedAt: _time(json['lastPlayedAt']),
  );
}

/// `GET /v1/me/stats`, keyed by scope.
///
/// API.md promises all five scopes with zeroed rows for modes never played, so
/// [of] can be total. It is written to survive a server that forgets one
/// anyway, because a missing bucket should show an empty scope, not throw.
class StatsBundle {
  const StatsBundle(this.scopes);

  final List<ScopeStats> scopes;

  ScopeStats of(StatsScope scope) => scopes.firstWhere(
    (stats) => stats.scope == scope,
    orElse: () => ScopeStats(scope: scope),
  );

  factory StatsBundle.fromJson(Map<String, dynamic> json) => StatsBundle([
    for (final entry in _objects(json['scopes'])) ScopeStats.fromJson(entry),
  ]);
}
