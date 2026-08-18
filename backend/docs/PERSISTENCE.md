# Persistence: accounts, match history and statistics

This document is the normative design for everything the server keeps in
Postgres. `PROTOCOL.md` stays the authority on the websocket wire format; this
covers the database, the REST surface next to the socket, and how a guest on one
phone becomes a signed-in player on another.

Three requirements drive it:

1. **Every player exists in the database**, including guests. A guest is a real
   `users` row from the first launch, keyed by a device id, and can later gain a
   Google/Facebook/Apple login *without losing anything*.
2. **Every game is recorded**, in every mode, with enough detail to replay the
   scoreboard hand by hand.
3. **Statistics are maintained per scope** — overall and per mode — so the
   profile can show "best in quickplay" separately from "best against bots".

Postgres stays **optional**. With no `DATABASE_URL` the server behaves exactly as
it does today: tables work, nothing is recorded, and the REST endpoints answer
`503 persistence_disabled`. That keeps `make run` and the whole existing test
suite dependency-free, and it means a database outage costs history rather than
gameplay.

---

## 1. Identity

### 1.1 The shape of the problem

The server today mints a `p_<random>` guest id and HMAC-signs it into a token
(`internal/auth`). Nothing is stored, so the identity dies with the token and a
reinstall makes you someone new. We need the same ergonomics — no signup wall in
front of a card game — backed by a row that survives, and a path to real logins
that does not require a second identity system later.

### 1.2 Two tables, not one

```
users                          user_identities
─────                          ───────────────
id            uuid pk   ◄──────  user_id     uuid fk
display_name  text               provider    text     'device'|'google'|'facebook'|'apple'
is_guest      bool               subject     text     device id, or Firebase uid
created_at                       UNIQUE (provider, subject)
last_seen_at
```

The critical decision is that **`users.id` is a surrogate key and nothing else
is**. The device id is not the primary key; it is one row in
`user_identities`. Everything downstream — games, seats, stats — references
`users.id` only.

That one indirection buys all three of the things asked for:

- **Guests are ordinary users.** First launch generates a device id, posts it,
  and gets back a `users` row with `is_guest = true` and a `('device', <id>)`
  identity. It is a full account from that moment; it just has no way to log in
  from anywhere else yet.
- **Upgrading is additive.** Linking Google adds a *second* row to
  `user_identities` pointing at the *same* `users.id`. No game, no seat and no
  stat row moves. `is_guest` flips to false. The upgrade is a one-line insert,
  which is exactly what makes it safe.
- **Cross-device login is a lookup, not a migration.** Signing in on a new phone
  resolves `('google', <uid>)` → an existing `users.id` and that player's whole
  history is already attached to it.

A single-table design where `device_id` were the primary key would force a
rewrite of every foreign key the day the first player logs in with Google. This
is the entire reason for the split.

### 1.3 Android → iPhone: what actually carries the account

Your instinct is right, with one caveat worth being precise about.

Firebase Auth UIDs are **per Firebase project, not per platform**. A player who
signs in with the *same Google account* on Android and on iOS gets the *same*
UID from the same project, so `('google', uid)` resolves to the same `users` row
and their history follows them across the platform boundary. That is the
mechanism, and it needs nothing from us beyond storing the provider identity.

The caveat: it is the *provider account* that carries the identity, not the
device or the OS. Someone who used Google on Android and then taps "Sign in with
Apple" on an iPhone arrives with a different UID and would land on a different
`users` row. Two things handle that:

- **Multiple identities per user.** Because `user_identities` is many-to-one, a
  player can link Google *and* Apple *and* Facebook to one `users` row. Firebase
  supports this directly via `linkWithCredential`; each linked provider lands as
  another row here. After linking once, either button signs them into the same
  account.
- **Firebase's own account linking**, when it detects the same verified email
  across providers, collapses them to one UID before we ever see it — in which
  case there is only ever one identity to store.

Apple's "Hide My Email" defeats email-based collapsing, so the explicit link
path is the one to rely on. The UI should therefore offer *link another sign-in
method* on the profile screen, not only *sign in*.

### 1.4 Flow

```
first launch
  client generates device_id (uuid v4) → persists it locally, forever
  POST /v1/auth/device {deviceId, displayName}
    ├─ identity ('device', deviceId) found → return that user
    └─ not found → INSERT users(is_guest=true) + identity, return it
  ← {token, user}          token = HMAC session, subject = users.id

later: upgrade (Firebase, not yet implemented — endpoint returns 501)
  client signs in with Google/Facebook/Apple via Firebase
  POST /v1/auth/link {idToken}  + Bearer <current guest token>
    server verifies idToken with Firebase Admin, extracts (provider, uid)
    ├─ ('google', uid) already linked to another user
    │     └─ that account wins; return its token, and offer to merge the
    │        guest's history into it (§1.5). Never silently discard either side.
    └─ unlinked → INSERT identity(user_id = caller, provider, uid)
                  UPDATE users SET is_guest = false
  ← {token, user}          same users.id, all history intact

later: same account, new device
  POST /v1/auth/firebase {idToken}
    ('google', uid) → existing users.id → full history on the new phone
```

The guest token and the session token are both minted by `internal/auth`, which
already does exactly one HMAC algorithm with no client-selectable negotiation.
A third token kind (`"u"`, subject = user uuid) is all this needs; there is no
reason to introduce a JWT library.

### 1.5 Merging

When a signed-in account and a guest account both exist and both have history,
the safe move is to keep both rows and re-point the guest's data at the survivor
inside one transaction, then mark the guest row `merged_into = <survivor>` rather
than deleting it. Deleting loses the audit trail and breaks any token still in
flight. Stats for the survivor are recomputed from `game_seats` afterwards rather
than added together, because maxima and streaks do not sum.

This path is schema-complete and implemented behind an explicit client
confirmation. It is never automatic — silently absorbing an account is the kind
of thing that turns into a support ticket.

### 1.6 Restoring a saved account on a new phone

Before any Google link exists, the *only* thing that carries a guest account is
its device id — and the device id lives on the phone. So the game keeps the
account's **id** (`users.id`) visible on its profile, and lets a fresh install
adopt an account by that id. This is the "I wrote my account id down, got a new
phone, typed it back in" path.

`POST /v1/auth/restore` (authenticated) moves **this install's** device identity
off its freshly-created guest account and onto the claimed `users.id`, in one
transaction. The client's own device id is the load-bearing value, so it is
*moved* rather than minted fresh — after the call, `ResolveIdentity('device', <this device id>)`
lands on the restored account with nothing client-side having changed beyond
the response it just received. The fresh guest account the new install started
as is simply left behind.

Two rules, both in the store, both for the same reason — a device id must never
be a skeleton key into an account it was not born with:

- The restoring install must still be a bare guest (`ErrNotGuest` otherwise).
- The claimed account must be a guest too. A **linked** account is not
  restorable by its id, and the endpoint answers 404 rather than letting a
  caller confirm it exists. A linked account restores by signing in.

The threat that motivates both is the account id leaking off a scoreboard: every
participant of a game can see `userId` in a `gameSummary`, so the id alone must
never be enough to take over a signed-in account. Restore only works between two
guests, where the id is exactly as secret as a device id — that is, the security
level the guest system already stands on.

---

## 2. Game history

### 2.1 Grain

Four tables, at descending grain:

| Table | One row per | Purpose |
|---|---|---|
| `games` | game | mode, room, when, whether it finished |
| `game_seats` | game × seat | who sat there, final score, placing |
| `game_hands` | game × hand × seat | the scoreboard, hand by hand |
| `game_tricks` | game × hand × trick | full card-level replay (optional) |

`game_seats` is the row that makes history queryable: "my last 20 games" is an
index scan there, joined to `games`. Putting the user on the seat rather than on
the game is what allows four players to each see the same game in their own
history with their own result.

For that scan to avoid a sort, the `ORDER BY` key has to live on the same table
as the filter, so **`mode` and `finished_at` are denormalised onto
`game_seats`** — written once inside the recording transaction and never
updated, which is what makes the duplication safe. The indexes are
`(user_id, finished_at DESC, game_id DESC)` and a `(user_id, mode, …)` variant
for the `?mode=` filter, both partial on `user_id IS NOT NULL` because roughly
three seats in four are bots. Verified on a seeded 20k-game table: no Sort node,
and the keyset cursor becomes an index range seek rather than a scan-and-discard.

`game_tricks` is written only when `RECORD_TRICKS=true`. Card-level detail is
~260 rows per game and most products never read it; the per-hand scoreboard is
what a history screen actually renders. The table exists from day one so turning
it on later is a config change rather than a migration.

### 2.2 Modes and who writes the row

| Mode | Played where | Written by |
|---|---|---|
| `online` | server (quickplay) | room actor, at `GameOver` |
| `private` | server (room code) | room actor, at `GameOver` |
| `bots` | entirely on device | client, via `POST /v1/games` |
| `lan` | device acting as host | LAN host client, via `POST /v1/games` |

Offline modes never touch the server during play, so "every game in every mode"
requires the client to upload them. That upload is **idempotent on
`client_game_id`**, a uuid the client mints when the game starts: a phone that
loses connectivity mid-upload retries the same payload and gets the same game
back rather than a duplicate. Uploads queue on disk and drain whenever the app
next has a network.

Client-reported games are marked `source = 'client'` and are, by construction,
not trustworthy — the device computed them. They are fine for a personal history
and personal stats. They must never feed a public leaderboard, which is why
`source` is a column rather than an inference.

### 2.3 Abandoned games

A game that never reaches `GameOver` is still worth a row: `completed = false`,
`finished_at` set when the table closes. It counts toward `games_played` but not
toward wins or score records. Writing it means "games I started" and "games I
finished" are both answerable, and it stops a rage-quit from vanishing.

---

## 3. Statistics

### 3.1 Scopes

One row per `(user_id, scope)` where scope is `all`, `bots`, `private`,
`online`, or `lan`. Every finished game updates exactly two rows: the mode's and
`all`. Denormalised on purpose — the profile screen must not run a five-table
aggregate on every open, and these counters are only ever touched by one
transaction per game.

### 3.2 What is tracked

**Volume** — `games_played`, `games_completed`, `hands_played`
**Outcomes** — `games_won` (place 1), `games_lost`, `best_place`
**Bidding** — `total_bid`, `bids_made`, `bids_failed`, `highest_bid`
**Tricks** — `total_tricks`
**Scores** — `total_score`, `highest_game_score`, `lowest_game_score`,
`highest_hand_score`
**Streaks** — `current_win_streak`, `best_win_streak`
**Recency** — `last_played_at`

Derived values (win rate, average score, bid accuracy) are computed on read.
Storing them invites the two numbers to disagree.

### 3.3 Correctness

Counters are updated in the **same transaction** that inserts the game, via
`INSERT … ON CONFLICT (user_id, scope) DO UPDATE`, with maxima expressed as
`GREATEST(user_stats.highest_bid, EXCLUDED.highest_bid)`. Doing it in SQL rather
than read-modify-write in Go removes the lost-update race between two games
finishing at once, and the idempotent game insert means a retried upload cannot
double-count.

`highest_hand_score` in Call Break is bounded by the scoring rule (make your bid,
score `bid + 0.1` per overtrick), so scores carry one decimal place and are
stored as `numeric(6,2)` — never `float`, which would make `8.3` a value that
does not compare equal to itself across a round trip.

---

## 4. REST surface

The socket stays exactly as it is. History and profile are request/response and
belong on plain HTTP, mounted on the same mux as `/ws` and `/healthz`.

Auth: `Authorization: Bearer <session token>` on everything except
`/v1/auth/device`.

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/auth/device` | device id → user + session token. Creates on first sight. |
| `POST` | `/v1/auth/refresh` | new token from a valid one |
| `POST` | `/v1/auth/link` | link a Firebase provider to the caller. **501 today.** |
| `GET` | `/v1/me` | profile |
| `PATCH` | `/v1/me` | change display name |
| `GET` | `/v1/me/stats` | every scope in one response |
| `GET` | `/v1/me/games` | history, `?mode=&limit=&cursor=` |
| `GET` | `/v1/games/{id}` | one game with its per-hand scoreboard |
| `POST` | `/v1/games` | upload an offline (`bots`/`lan`) result. Idempotent. |

Errors are `{"error": {"code": "...", "message": "..."}}` with the same code
vocabulary as the socket where they overlap (`unauthorized`, `bad_frame`,
`internal`), plus `not_found`, `persistence_disabled`, `not_implemented`.

Pagination is a keyset cursor (`finished_at`, `id`), not an offset. Offsets skip
rows when a new game lands mid-scroll.

### 4.1 Joining the socket to the account

The `join` frame gains an optional `deviceId`. When present and persistence is
on, the gateway resolves it to a `users.id` and the room records that id on the
seat. When absent — an old client, or persistence off — play is completely
unaffected and the game is recorded with `user_id = null` on that seat. Identity
is an enrichment of the session, never a precondition for it.

---

## 5. Failure behaviour

| Condition | Result |
|---|---|
| No `DATABASE_URL` | Server runs. No recording. REST answers `503 persistence_disabled`. |
| Postgres down at boot | Startup fails only if `DATABASE_REQUIRED=true`; otherwise logs and degrades. |
| Postgres drops mid-game | Play is unaffected. The write is retried, then dropped with a log and a metric. |
| Client upload fails | Queued on the device, retried on the next launch. Idempotent, so retries are free. |

The rule throughout: **a database problem must never stop a game.** Recording is
downstream of play, on its own goroutine with a bounded queue, and the room actor
never blocks on it.

---

## 6. Client (Flutter)

`ProfileScreen` with three tabs, reached from the avatar in the home screen top
bar:

- **Statistics** — scope selector (All / Quickplay / Private / Bots / LAN) over a
  grid of the §3.2 figures.
- **History** — reverse-chronological list of games, each expanding to the
  hand-by-hand scoreboard from `GET /v1/games/{id}`.
- **Account** — current identity, and the Google/Facebook/Apple buttons disabled
  behind a "Coming soon" state, with copy explaining that linking preserves the
  existing history.

The device id is generated once and persisted with `shared_preferences`; so is
the session token. Both survive an app restart, which is the thing today's
in-memory `guestToken` does not.

---

## 7. Migrations

Plain numbered SQL under `backend/migrations/`, embedded with `go:embed` and
applied at startup inside an advisory lock so concurrent replicas cannot race.
Forward-only. No ORM, no separate migration binary to keep in sync with the
deploy.

`go:embed` cannot reach outside its own package directory, so `migrations/`
carries a three-line `embed.go` exporting the `embed.FS` that `internal/db`
imports. The schema stays where a human would look for it rather than being
buried under `internal/` to suit the compiler.

Two implementation notes that constrain deployment:

- **Postgres 13 or newer is required.** `gen_random_uuid()` is in `pg_catalog`
  from 13 onward, which avoids `CREATE EXTENSION pgcrypto` and the
  extension-install privileges that managed Postgres often withholds.
- **`user_identities.user_id` is `DEFERRABLE INITIALLY DEFERRED`.** This is
  load-bearing, not decoration. `ResolveIdentity` inserts the identity first and
  creates the `users` row only in the branch that won the `ON CONFLICT`, which
  is what stops two devices racing on a cold id from leaving an orphan account.
  That ordering puts the identity row in front of the user it references, so the
  check has to wait until commit.
