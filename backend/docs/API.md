# REST API v1 — normative wire format

Companion to `docs/PERSISTENCE.md`, which explains *why*. This file is the
*what*: the exact JSON the Go server emits and the Godot client decodes. Both
sides are written against this document, so a field renamed here is a breaking
change on two codebases at once.

Conventions, matching the existing socket protocol:

- `lowerCamelCase` keys.
- Timestamps are RFC 3339 UTC strings (`2026-08-10T09:41:22Z`).
- Scores are JSON numbers with at most two decimals (`13.20`, `-4`).
- **Adding a field is safe**; the client's decoders ignore unknown keys. Renaming or
  removing one is a breaking change.
- Every response is an object, never a bare array — arrays are always under a
  named key so the envelope can grow.

Base path: `/v1`. Auth: `Authorization: Bearer <token>` on everything except
`POST /v1/auth/device`.

---

## Errors

Any non-2xx:

```json
{ "error": { "code": "unauthorized", "message": "Sign in again to continue." } }
```

| code | status | meaning |
|---|---|---|
| `bad_request` | 400 | malformed body or query |
| `unauthorized` | 401 | missing, expired or forged token |
| `not_found` | 404 | no such game, or not yours |
| `conflict` | 409 | identity already belongs to another account |
| `rate_limited` | 429 | too many requests |
| `persistence_disabled` | 503 | server has no database configured |
| `not_implemented` | 501 | endpoint reserved for a future release |
| `internal` | 500 | anything else |

---

## Shared objects

### `user`

```json
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
```

`provider` is one of `device`, `google`, `facebook`, `apple`. The `identities`
array drives the account tab: a user with only `device` is a guest who can be
upgraded.

### `gameSummary`

```json
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
```

`mode` is one of `bots`, `private`, `online`, `lan`. `place` is `1`–`4`, or `0`
when the game was abandoned before anyone was ranked.

### `stats` (one scope)

```json
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
```

`scope` is `all`, `online`, `private`, `bots` or `lan`. Win rate, average score
and bid accuracy are **derived on the client** from these figures — the server
does not send them, so the two can never disagree.

`lastPlayedAt` is **nullable** and is `null` for a scope the player has never
played. Every other field in this object is a number and is a meaningful zero
for an unplayed scope; a date is not, and `"0001-01-01T00:00:00Z"` would render
as a real date in a list. It is the only nullable timestamp in the API — the
ones on `gameSummary` are always concrete strings.

---

## Endpoints

### `POST /v1/auth/device`

The only unauthenticated endpoint. Creates the account on first sight; returns
the existing one afterwards. Idempotent.

```json
→ { "deviceId": "b1e9…", "displayName": "Nabin", "platform": "android" }
← 200 { "token": "eyJ…", "expiresAt": "2026-09-09T09:41:22Z", "user": { …user… } }
```

`deviceId` must be 8–128 characters of `[A-Za-z0-9_-]`. `displayName` is only
applied when the account is created; it never renames an existing one (use
`PATCH /v1/me`). `platform` is advisory and may be omitted.

### `POST /v1/auth/refresh`

```json
← 200 { "token": "eyJ…", "expiresAt": "…", "user": { …user… } }
```

### `POST /v1/auth/link` — reserved

```json
→ { "idToken": "<firebase id token>" }
← 501 { "error": { "code": "not_implemented", "message": "Account upgrade is coming soon." } }
```

Documented now so the client can build the button and the "coming soon" state
against its final shape. When implemented it returns the same body as
`/v1/auth/refresh`, with the linked provider present in `user.identities`, and
`409 conflict` with `{"error":{…,"existingUserId":"…"}}` when the provider
identity already belongs to another account.

### `POST /v1/auth/restore`

Moves **this install's** device identity onto another guest account by its
account id — the "wrote my account id down, got a new phone, typed it back in"
path (§1.6). Authenticated, and only ever between two guests.

```json
→ { "accountId": "018f3a2b-7c41-4c3e-9a10-4f2c8d5e6b71" }
← 200 { "token": "eyJ…", "expiresAt": "…", "user": { …user… } }
```

`accountId` is the `user.id` shown in the profile's Account tab; it must be a
uuid. The response is a session for the restored account, exactly like
`/v1/auth/device` — and the next device auth on this install resolves back to
the same account, because the server moved this device's identity onto it.

Errors: `400 bad_request` when the restoring account is already signed in
(restore is for a fresh install). `404 not_found` when no guest account has that
id — deliberately the same answer for an unknown account and a linked one, so a
caller cannot probe whether a linked account exists.

### `GET /v1/me`

```json
← 200 { "user": { …user… } }
```

### `PATCH /v1/me`

```json
→ { "displayName": "Nabin B" }
← 200 { "user": { …user… } }
```

Name is sanitised exactly like a socket display name: control characters
stripped, trimmed, max 24 runes, never empty.

### `GET /v1/me/stats`

Always returns all five scopes in this order — `all`, `online`, `private`,
`bots`, `lan` — with zeroed rows for modes never played, so the client renders
the tab without null checks.

```json
← 200 { "scopes": [ { …stats… }, … ] }
```

### `GET /v1/me/games?mode=&limit=&cursor=`

`mode` optional (one of the four); `limit` 1–50, default 20; `cursor` from the
previous page.

```json
← 200 { "games": [ { …gameSummary… }, … ], "nextCursor": "eyJ0IjoxNzU…" }
```

`nextCursor` is absent or `""` on the last page. It is a keyset cursor over
`(finishedAt, id)` — never an offset, which would skip rows when a new game
lands mid-scroll.

### `GET /v1/games/{id}`

The summary plus the hand-by-hand scoreboard. `404 not_found` if the caller did
not play in it.

```json
← 200 {
  "game": { …gameSummary… },
  "hands": [
    { "handIndex": 0, "seat": 0, "bid": 3, "tricksWon": 3, "scoreDelta": 3.0, "runningTotal": 3.0 },
    { "handIndex": 0, "seat": 1, "bid": 4, "tricksWon": 2, "scoreDelta": -4.0, "runningTotal": -4.0 }
  ]
}
```

`hands` is ordered by `handIndex`, then `seat`.

### `POST /v1/games` — offline game upload

How `bots` and `lan` games reach the database: they are played entirely on the
device, so the device uploads the result. **Idempotent on `clientGameId`** — a
repeat returns `200` with the original `gameId` and records nothing new, which
is what makes retrying a failed upload free.

```json
→ {
  "clientGameId": "5b0e…",          // uuid v4, minted when the game starts
  "mode": "bots",
  "completed": true,
  "handsTotal": 5,
  "startedAt": "2026-08-10T09:10:00Z",
  "finishedAt": "2026-08-10T09:34:11Z",
  "seats": [
    { "seat": 0, "isYou": false, "displayName": "Amit", "isBot": true,
      "botDifficulty": "normal", "finalScore": 6.1, "place": 3,
      "totalBid": 12, "totalTricks": 11, "handsMade": 3 },
    { "seat": 2, "isYou": true,  "displayName": "Nabin", "isBot": false,
      "finalScore": 13.2, "place": 1, "totalBid": 14, "totalTricks": 15, "handsMade": 5 }
  ],
  "hands": [
    { "handIndex": 0, "seat": 0, "bid": 3, "tricksWon": 3, "scoreDelta": 3.0, "runningTotal": 3.0 }
  ]
}
← 200 { "gameId": "018f…", "duplicate": false }
```

`duplicate` is `true` when this upload matched an already-recorded
`clientGameId`, meaning nothing was written. It is **advisory only** — the retry
policy below drops a queued upload on any `2xx`, so a client must not branch on
it. It exists for observability: a client that keeps re-uploading a game it has
already had a `2xx` for has a bug in its queue, and this response is the only
place that would ever surface.

Rules the server enforces, because a client controls this payload entirely:

- `mode` must be `bots` or `lan`. Server-played modes cannot be uploaded.
- Exactly one seat may have `isYou: true`; it is bound to the caller's account
  and every other seat is stored with `userId = null`. A client cannot write
  history onto another player.
- `seats` has 1–4 entries with distinct `seat` in `0..3`.
- `hands` has at most `handsTotal × 4` entries; `handIndex` and `seat` in range.
- The record is stored with `source: "client"` and is never eligible for any
  public ranking.

---

## Client retry policy

`POST /v1/games` is the only write the client must not lose. Uploads are queued
on the device and drained on launch and on regaining connectivity. Because the
call is idempotent, the queue can retry blindly; an entry is dropped only after
a `2xx`, or after a `400`-class rejection that a retry cannot fix.

`GET` endpoints are not queued. A history screen with no network shows the last
successful response and a retry affordance.

---

## Admin endpoints

The operations dashboard lives at `GET /admin` (a single embedded HTML page).
Everything it shows or edits comes from the routes below, and all of them —
the page included — are gated by the `ADMIN_TOKEN` environment variable sent
as `Authorization: Bearer <token>`. With no `ADMIN_TOKEN` configured none of
these routes are mounted at all.

These routes are the one part of the API that does **not** answer 503 when
there is no database: tables live in memory and settings work in memory too,
and an operator needs the dashboard most exactly when something else is broken.
Settings changes are written to Postgres when one is configured (so a fleet
restarts onto them) and held in memory otherwise.

### `GET /v1/admin/rooms`

Every live table on this node with its full state, plus a summary for the
headline cards.

```json
← 200 {
  "serverTime": "2026-08-13T06:31:03Z",
  "summary": {
    "rooms": 1, "started": 1, "lobby": 0, "humans": 2, "bots": 2,
    "humansConnected": 2, "quickplayFilling": 0,
    "byMode": { "private": 1 }, "byPhase": { "bidding": 1 }
  },
  "rooms": [
    {
      "id": "K7Q2", "mode": "private", "closed": false, "accepting": false,
      "started": true, "startedAt": "2026-08-13T06:31:00Z",
      "lastActive": "2026-08-13T06:31:03Z", "totalHands": 5, "hostSeat": 0,
      "phase": "bidding", "handIndex": 0, "dealer": 0, "turn": 1,
      "trickNumber": 1, "awaitingTrickClear": false,
      "turnClock": { "at": "2026-08-13T06:31:08Z", "kind": "turnTimeout", "seat": 1 },
      "countdownAt": null, "handAdvanceAt": null, "idleCollectAt": null,
      "bids": [null, null, null, null],
      "tricksWon": [0, 0, 0, 0], "totals": [0, 0, 0, 0],
      "roundScores": [[], [], [], []],
      "handCounts": [13, 13, 13, 13],
      "hands": [["9S","QH",…], ["KS","7S",…], ["2H",…], […]],
      "trick": [], "lastTrickWinner": null,
      "rankings": [],
      "seats": [
        { "seat": 0, "occupied": true, "name": "Alice", "kind": "human",
          "difficulty": "normal", "connected": true, "autoplay": false,
          "playerId": "p_…", "userId": "", "isHost": true, "graceUntil": null,
          "hand": ["9S","QH",…], "bid": null, "tricksWon": 0, "totalScore": 0,
          "roundScores": [] }
      ],
      "pacing": {
        "botThinkMin": "550ms", "botThinkExtra": "450ms", "trickLinger": "1100ms",
        "bidTimeout": "5s", "playTimeouts": ["10s","8s","6s","5s"],
        "reconnectGrace": "2m0s", "handAdvanceWait": "5s", "idleTTL": "5m0s",
        "startCountdown": "3s", "dealGrace": "3500ms"
      },
      "fillWait": "3s", "minPlayers": 1, "humanSeats": 2, "connectedHumans": 2
    }
  ]
}
```

`phase` is `lobby`, `bidding`, `playing`, `handOver` or `gameOver`; it is
`""` for a table that has not dealt yet. `turnClock.kind` is `clearTrick`,
`serverMove` or `turnTimeout`, and `seat` is the seat it will act for (`-1`
when nothing is scheduled). `hands` is deliberately unredacted — this is an
admin view, and every player's hand is exactly what the dashboard is for.
Timestamps are null when they do not apply (the table has not started, the
clock is not running).

### `GET /v1/admin/rooms/{id}`

One table, same shape as the array entries above, in `{"room": {…}}`.
`404 not_found` for a code with no live table.

### `GET /v1/admin/settings`

The current runtime defaults — the pacing and quickplay knobs the server is
running on. They start from the environment and, when a database is
configured, a saved set from a previous session wins on boot.

```json
← 200 {
  "settings": {
    "botThinkMin": "550ms", "botThinkExtra": "450ms", "trickLinger": "1100ms",
    "startCountdown": "3s", "bidTimeout": "5s",
    "playTimeouts": ["10s", "8s", "6s", "5s"],
    "reconnectGrace": "2m0s", "handAdvanceWait": "5s", "roomIdleTTL": "5m0s",
    "dealGrace": "3500ms", "matchFillWait": "5s", "matchMinPlayers": 2
  },
  "source": "env",
  "updatedAt": null,
  "persistence": false
}
```

`source` is `env` (never saved), `database` (saved, and a restart will keep
it) or `runtime` (changed live, but no database to remember it). `updatedAt`
is the last change, or null when nothing has been changed. `persistence`
says whether a change would survive a restart.

### `PUT /v1/admin/settings`

Applies new defaults. Every field is optional; absent fields keep their
current value. Durations are Go strings (`5s`, `250ms`, `2m0s`).

```json
→ { "bidTimeout": "7s", "matchMinPlayers": 3 }
← 200 { "settings": { …the new full set… }, "source": "database", "updatedAt": "…", "persistence": true }
```

`400 bad_request` for a malformed duration or an out-of-range value (nothing
is applied). A persistence failure is `500 internal` and is likewise not
applied. Changes only affect tables created afterwards — a live table keeps
the pacing it was dealt.

### `GET /v1/admin/games?mode=&source=&limit=&cursor=`

Every recorded game across all accounts, newest first — the dashboard's match
history. `mode` (one of the four) and `source` (`server` or `client`) are
optional filters; `limit` and `cursor` behave exactly like `/v1/me/games`. A
game played on the server has `source: "server"`; an offline game a phone
uploaded is `source: "client"`. This is the one admin route that needs the
database — with none configured it answers `503 persistence_disabled`.

```json
← 200 {
  "games": [
    {
      "id": "6f59d8be-…", "mode": "bots", "source": "client",
      "roomCode": "", "completed": true,
      "startedAt": "2026-08-13T09:00:00Z", "finishedAt": "2026-08-13T09:20:00Z",
      "handsTotal": 2,
      "players": [
        { "seat": 0, "userId": "018f…", "displayName": "Nabin", "isBot": false, "finalScore": 13.2, "place": 1 },
        { "seat": 1, "userId": null, "displayName": "Amit", "isBot": true, "finalScore": 6.1, "place": 3 }
      ]
    }
  ],
  "nextCursor": "eyJ0IjoxNzU…",
  "serverTime": "2026-08-13T09:41:22Z"
}
```

`nextCursor` is absent or `""` on the last page. Unknown games answer `404`; a
`bad_request` for a mode or source that is not one of the allowed values.

### `GET /v1/admin/games/{id}`

One game with its full hand-by-hand scoreboard — `game` as above plus `hands`
in the same shape as `/v1/games/{id}`. No player scoping: unlike the client
endpoint it does not check that the caller played in the game.
