# Call Break wire protocol — v2

One websocket per player, JSON text frames in both directions, at `GET /ws`.
The server is the sole authority on game state; the client renders what it is
sent and asks for moves it would like to make.

Append `?room=<CODE>` to the URL when joining a private table. The server does
not require it — the room is named again in the `join` frame — but a load
balancer can hash on it to land everyone at a table on the same node.

## Compatibility rules

- **Adding a field is safe.** Dart's `fromJson` decoders read the keys they know
  and ignore the rest, so new server fields reach old clients harmlessly.
- **Renaming or removing a field is breaking** and needs a version bump.
- Clients send `"v": 2`. A client claiming a version newer than the server
  speaks is refused with `unsupported_version` rather than served something it
  might misread.
- Frames larger than 4096 bytes are rejected before parsing.

---

## Client → server

| type | fields | notes |
|---|---|---|
| `join` | `v`, `room`, `mode`, `name`, `difficulty?`, `handsPerGame?`, `resumeToken?`, `guestToken?` | first frame on every connection |
| `start` | — | private tables only, host only |
| `bid` | `bid` | clamped to 1–13 server-side |
| `play` | `card` | wire id, e.g. `"AS"`, `"10H"` |
| `next` | — | consent to leave the between-hands scoreboard |
| `restart` | — | private: host only. quickplay: needs every connected human |
| `leave` | — | forfeits the seat immediately, no grace window |
| `awake` | — | a sign of life; cancels autoplay on this seat, no-op otherwise |
| `ping` | `t` | echoed back in `pong`, for round-trip timing |

### `join`

```json
{"type":"join","v":2,"room":"7QF2","mode":"private","name":"Nabin",
 "difficulty":"normal","guestToken":"…","resumeToken":"…","deviceId":"…"}
```

- `mode` is `"private"` or `"online"`. If omitted it is inferred from the room
  code, so v1 clients still work.
- `room` is a 4-character code from the alphabet `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`
  (no `I`, `O`, `0` or `1` — they are misread when a code is read aloud).
- **Quickplay:** send `mode:"online"` with `room:"QUICKPLAY"`. The room is not a
  code in this case; it is a request to be matched.
- `guestToken` is whatever the last `joined` frame handed back. Omit it on a
  first run and the server mints a new identity.
- `resumeToken` reclaims a specific seat after a drop. It is only honoured when
  the seat still belongs to that player, so it cannot be used to take somebody
  else's place.
- `deviceId` optionally ties the seat to a stored account so the finished game
  lands in that player's history (see `docs/PERSISTENCE.md` §4.1). It is 8–128
  characters of `[A-Za-z0-9_-]`; anything else is treated as absent rather than
  rejected. **It never gates play.** The lookup runs alongside the join instead
  of in front of it, and a missing id, an old client or an unreachable database
  all seat the player identically — the game is simply recorded without an
  account. This is the only field here that is purely an enrichment.
- `handsPerGame` picks how long a *freshly created* table plays: `3` or `5`.
  Absent, or any other value, resolves to `5`, the same as a client that never
  sends the field at all — an invalid value degrades gracefully rather than
  rejecting the frame. It only matters on the join that creates the table (the
  first player into a fresh quickplay table, or the creator of a fresh private
  table); joining or resuming an existing table always plays whatever hand
  count that table was created with. The authoritative count for a table
  round-trips back to every client at that table via `view`'s `handsPerGame`
  field.

---

## Server → client

| type | purpose |
|---|---|
| `joined` | seat assignment and credentials |
| `lobby` | who is at the table before the deal |
| `view` | the authoritative, per-seat-redacted game state |
| `event` | discrete happenings, for animation and sound |
| `error` | a rejection, with a machine-readable code |
| `pong` | reply to `ping` |

### `joined`

```json
{"type":"joined","seat":2,"room":"7QF2","isHost":false,
 "playerId":"p_9f3c…","guestToken":"…","resumeToken":"…","reconnected":false}
```

Always the first frame after a successful join. **Store both tokens.** The
`guestToken` carries the player's identity across tables; the `resumeToken` is
what gets their seat back after a disconnect.

`joined` is always followed by a `lobby`, and by a `view` if the game is already
under way — the server does not send either until it knows the client has been
told its seat number, because both are written from that seat's point of view.

### `lobby`

```json
{"type":"lobby","room":"7QF2","mode":"private","hostSeat":0,"isHost":true,
 "canStart":true,"started":false,"humansSeated":2,"minPlayers":1,
 "seats":[{"seat":0,"name":"Nabin","kind":"human","connected":true,
           "isYou":true,"isHost":true}]}
```

Sent to everyone at the table whenever its membership changes, and to a joining
player right after their `joined` frame.

`humansSeated` is how many people are present; `minPlayers` is how many the
table needs before it can deal at all. Quickplay sets it to 2 — one human
against three bots is the offline mode, not a match — so a client showing
`humansSeated < minPlayers` should say what it is still waiting for.

Quickplay tables are hostless: `hostSeat` is `-1`, `isHost` is false for
everyone, and `canStart` is false. They deal on a countdown instead.

### `view`

The redacted game state, with `GameView.toJson()`'s keys hoisted to the top
level next to `"type":"view"` — exactly what `GameView.fromJson` reads. A view
carries the receiving seat's own cards in full and every other seat's only as a
count. **A client is never sent another player's cards.**

Each seat in `players[]` also carries `autoplay` — true while the server is
playing that seat because its occupant stopped responding.

Three server-only additions:

| field | meaning |
|---|---|
| `turnDeadlineMs` | unix millis at which the current turn is auto-played. Only present when a *human* is on the clock; a bot's think delay, or a seat already on autoplay, is not something to show a countdown for. |
| `handAdvanceMs` | unix millis at which the between-hands scoreboard stops waiting and the next hand is dealt anyway. Present only during `handOver`, and sent to every seat rather than just the one on the clock — it is the table's deadline, not a player's. |
| `serverTimeMs` | the server's clock at send time, so the client can render the countdown without trusting its own clock to agree. |

### `event`

Engine events keep the names the client already decodes: `handStart`, `bid`,
`biddingComplete`, `play`, `trickWon`, `handOver`, `gameOver`.

Four are server-only. Unknown event names are ignored by the client, so these
are safe to receive on an older build:

| event | fields | meaning |
|---|---|---|
| `countdown` | `seconds`, `cancelled?` | a quickplay table deals in this long; `cancelled:true` retracts a countdown when a player leaves and takes the table back below `minPlayers` |
| `readyState` | `ready`, `total`, `waitingFor[]` | how many players have tapped "next hand" |
| `seatChanged` | `seat`, `kind`, `name`, `connected` | a player dropped and a bot took over, or came back |
| `autoplay` | `seat`, `name`, `autoplay` | the server started or stopped playing a seat for its occupant — see [Turn clocks and autoplay](#turn-clocks-and-autoplay) |

### `error`

```json
{"type":"error","code":"room_full","message":"That table is full.","fatal":true}
```

Switch on `code`; `message` is for display only. `fatal: true` means the socket
is closing — the server flushes the frame before hanging up, so the player
always learns why.

| code | meaning |
|---|---|
| `bad_frame` | unparseable or invalid message |
| `unsupported_version` | the client is newer than the server |
| `room_full` | four seats are already taken |
| `room_not_found` | the table is gone |
| `game_started` | too late to join, and no valid resume claim |
| `not_your_turn` | out-of-turn action; a corrected `view` follows |
| `illegal_move` | that card is not legal right now; a corrected `view` follows |
| `not_host` | only the host may do that |
| `rate_limited` | too many frames per second |
| `redirect` | the table lives on another node; reconnect to `endpoint` |
| `server_draining` | this node is shutting down; reconnect with the resume token |
| `unauthorized` | not seated, or the seat was taken over elsewhere |
| `at_capacity` | this node cannot take another table |
| `internal` | a bug; the table is being closed |

---

## Flows

### Private table

```
client                                server
  │── join {room:"7QF2", mode:"private"} ──▶
  ◀── joined {seat:0, isHost:true} ─────────
  ◀── lobby {canStart:true} ────────────────
       … other players join …
  ◀── lobby {seats:[…]} ────────────────────
  │── start ────────────────────────────────▶     (host only)
  ◀── view / event handStart ───────────────
```

The first player to name a room code creates it, takes seat 0, and becomes
host. On `start`, any empty seats are filled with bots (`Amit`, `Riya`,
`Sujan`) and the deal begins.

### Quickplay

```
client                                server
  │── join {room:"QUICKPLAY", mode:"online"} ─▶
  ◀── joined {seat:0, isHost:false} ──────────    seated immediately
  ◀── lobby {humansSeated:1, minPlayers:2} ───    waiting, and says so
       … another player arrives …
  ◀── lobby {humansSeated:2, seats:[…]} ──────    both names visible
  ◀── event countdown {seconds:20} ───────────    enough to play
       … a third arrives, or the wait expires …
  ◀── view / event handStart ─────────────────    bots fill any empty seats
```

There is no queue. A player asking for quickplay is seated at a real table
straight away, alongside whoever else is waiting, which is what lets them see
each other's names instead of a counter.

`room:"QUICKPLAY"` is really two independently-matched pools, keyed by
`handsPerGame`: a player asking for a 3-hand game is never seated with one
asking for a 5-hand game, even though both send the same room sentinel.

The table deals once `MATCH_MIN_PLAYERS` (2) humans are present, after holding
the door open for `MATCH_FILL_WAIT` (20s) in case more arrive; a full table of
four deals on the short `START_COUNTDOWN` instead. Any still-empty seats become
bots at that point.

**Leaving.** `leave` frees the seat immediately and rebroadcasts the lobby, so
the others carry on without a ghost. If that drops the table below
`minPlayers`, the pending countdown is retracted with
`event countdown {cancelled:true}` and the table goes back to waiting — a player
quitting at the last moment must not start a game that no longer has enough
people in it, and must not strand the ones who stayed either. A socket that
simply dies before the deal is treated the same way: unlike a mid-game
disconnect, there is no game to hold the seat for.

### Disconnect and reconnect

A dropped seat is marked `connected:false`, a bot plays it so the table keeps
moving, and the player has `RECONNECT_GRACE` (2 minutes by default) to come
back. Reconnecting means dialling again and sending `join` with the same
`guestToken` and `resumeToken`; the reply carries `reconnected:true` and the
original seat. After the grace window the seat becomes a bot permanently.

If every human leaves, the table closes rather than letting four bots play out
a game nobody is watching.

### Turn clocks and autoplay

Every turn has a deadline: 20s to bid, 15s to play. On expiry the server plays
for that seat using the same bot brain the AI opponents use — a timed-out player
gets a sensible move, never a random card.

Running the clock out does not just cost that one turn. The seat enters
**autoplay**: it keeps being played automatically, at bot pacing, so a table is
never held up turn after turn by someone who has put their phone down. The
server announces this with an `autoplay` event and sets `autoplay:true` on that
seat in every subsequent `view`.

Autoplay ends the moment the player shows any sign of life:

- an `awake` frame — what a client sends on a tap, without needing a legal move
- any `bid`, `play` or `next`, which prove presence on their own
- reconnecting to the seat
- a new game being dealt

An `awake` frame is always safe to send: on a seat that is not on autoplay it
changes nothing. Clients should still send it only when their own view says
`autoplay:true`, and not more than a few times a second, since the per-connection
frame budget (20/s) applies to it like anything else.

Autoplay is *not* a disconnect. `connected` stays true throughout, the seat is
never handed over, and the player takes it straight back — which is why it is a
separate flag rather than a reuse of `seatChanged`.

### Consent between hands

With more than one human at a table, `next` is a vote rather than a command: one
player must not wipe the scoreboard out from under the others. The hand advances
when every connected human has sent `next`, or after `HAND_ADVANCE_WAIT` (20s).
`restart` works the same way in quickplay; on a private table it is the host's
call alone.
