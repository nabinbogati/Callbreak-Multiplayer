# Call Break game server

The authoritative backend for the Flutter client in `../frontend`. One binary
serves both networked modes:

- **Private tables** — invite-only rooms addressed by a 4-character code, empty
  seats filled with bots when the host starts.
- **vs Humans (quickplay)** — players are seated at a shared table as they
  arrive and can see each other while it fills. It deals once at least two real
  people are present, filling any empty seats with bots.

The wire format is documented in [PROTOCOL.md](PROTOCOL.md).

## Running it

No Go toolchain? `scripts/go.sh` falls back to the `golang:1.26` Docker image,
and every `make` target goes through it.

```bash
make run          # server on :8080, no external dependencies
make test         # full suite, including real-websocket integration tests
make race         # the same under the race detector
make test-db      # persistence tests against a throwaway Postgres container
make up           # server + Redis + Postgres via docker compose
```

`make test` needs no database — the persistence tests skip themselves without
`TEST_DATABASE_URL`, which keeps the default suite runnable on a laptop with
nothing installed. `make test-db` starts a container, runs them, and throws it
away.

Point the Flutter app at it through the debug server field in Settings:
`ws://<your-lan-ip>:8080/ws`. Use the LAN address, not `localhost`, or a phone
or emulator will look for the server on itself.

## How it is put together

```
cmd/server            wiring: config → dependencies → HTTP → graceful drain
internal/engine       the rules, ported from frontend/lib/engine/
internal/bot          the opponent, ported from frontend/lib/bots/bot.dart
internal/room         one goroutine per table, owning all of its state
internal/match        quickplay seating: open tables players join as they arrive
internal/ws           websocket edge: upgrade, auth, validate, route
internal/protocol     every frame that crosses the wire
internal/auth         guest identities and seat resume tokens
internal/store        optional Redis room registry
internal/obs          logging, metrics, health
```

**A table is an actor.** Each room is a single goroutine that exclusively owns
its engine, seats, timers and client handles. Nothing outside touches that
state — callers post messages to an inbox and the actor applies them in order.
That is what makes turn ordering correct by construction and keeps locks off the
hot path entirely. A room is a few kilobytes resident, so the ceiling on tables
per node is websocket fan-out, not the game logic.

**The engine is a pure state machine.** No timers, no I/O, no goroutines. It is
a faithful port of the Dart engine the client already runs offline, which is
what lets one implementation of the rules back both. `internal/engine`'s tests
are ported case-for-case from `frontend/test/engine_test.dart`; if they ever
disagree, the client and server disagree about the rules, and that is the one
bug class this port cannot afford.

**Redaction happens at the boundary.** `Game.ViewFor(seat)` is the only way
state leaves the engine, and it hands out a seat's own cards in full and
everyone else's as a count. A test asserts that no other seat's card ids appear
anywhere in a serialised view.

**A panic costs one table, not the process.** Every room goroutine recovers,
tells its players, and closes.

## Scaling out

The server is fully functional on one node with no external dependencies. Set
`REDIS_URL` and `PUBLIC_URL` and it becomes horizontally scalable: the hub
registers each table it holds, and a client that reaches the wrong node gets an
`error{code:"redirect", endpoint}` telling it where to go. Configuring the load
balancer to hash on the `?room=` query parameter avoids most redirects entirely.

Redis is advisory, not authoritative — an outage degrades routing, it does not
stop play.

### Measured

`cmd/loadtest` drives real websockets through the real protocol, playing only
cards the server said were legal, and reports the wall time from sending a move
to receiving the view that reflects it — the thing a player actually feels.

```bash
make build
./bin/loadtest -url ws://localhost:8080/ws -tables 200 -humans 4
```

200 tables × 4 human clients (800 concurrent players, 55,440 moves) on one
laptop core, with pacing compressed to 5ms so the games run flat out:

| p50 | p90 | p99 | max |
|---|---|---|---|
| 625µs | 5.3ms | 13.6ms | 38ms |

Zero dropped connections, zero turn timeouts, 198/200 games played to the final
hand. (The two that did not are the harness colliding on random room codes — see
below — and the server correctly refused the second table's start.)

### Known limitations

- **Tables are in memory only.** A node restart ends the games it was hosting;
  players get `server_draining` and reconnect to a fresh table rather than
  resuming mid-hand. Snapshotting rooms to Redis so another node can rehydrate
  them is designed for but not implemented.
- **Room codes are 4 characters** to match what the client generates — about a
  million combinations. That is small enough that a determined stranger could
  find an open private room by guessing, and small enough that two rooms created
  at random will occasionally collide (~2% across 200 tables). Lengthening the
  code means changing `RoomCodeLength` here and `_newCode` in
  `frontend/lib/ui/screens/settings_sheet.dart` together.
- **Persistence is optional and degrades rather than fails.** With no
  `DATABASE_URL` the server runs exactly as it always has — tables work, nothing
  is recorded, and the `/v1` REST routes answer `503 persistence_disabled`. Set
  `DATABASE_REQUIRED=true` to make an unreachable database a startup failure
  instead. A database that dies mid-game never interrupts play: recording sits
  behind a bounded queue that drops records rather than stalling a table.
- **Client-uploaded results are not authoritative.** `bots` and `lan` games are
  played entirely on the device, so the device uploads them and they are stored
  with `source = 'client'`. Fine for a personal history; never eligible for a
  public leaderboard.
- **Account upgrade is designed but not implemented.** The schema and
  `POST /v1/auth/link` carry Google/Facebook/Apple; the endpoint answers `501`
  until Firebase token verification is wired up. See `docs/PERSISTENCE.md` §1.

## Configuration

Every setting has a working default; the server starts with an empty
environment. `JWT_SECRET` and `ALLOWED_ORIGINS` become mandatory when
`ENV=production`.

| variable | default | meaning |
|---|---|---|
| `ADDR` / `PORT` | `:8080` | listen address |
| `ENV` | `development` | `production` turns on strict validation and JSON logs |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `JWT_SECRET` | random per process | signs guest and resume tokens |
| `REDIS_URL` | — | enables the shared room registry |
| `PUBLIC_URL` | — | how clients reach this node; required with Redis |
| `DATABASE_URL` | — | enables accounts, match history and statistics (Postgres 13+) |
| `DATABASE_REQUIRED` | `false` | make an unreachable database a startup failure |
| `DB_MAX_CONNS` | `10` | Postgres pool size |
| `RECORD_TRICKS` | `false` | store card-level replay detail (~260 rows/game) |
| `API_RATE_PER_MINUTE` | `120` | REST requests per account |
| `BOT_THINK_MIN` / `BOT_THINK_EXTRA` | `550ms` / `450ms` | pause before a server-driven seat acts |
| `TRICK_LINGER` | `1100ms` | how long a finished trick stays on the table |
| `BID_TIMEOUT` | `5s` | turn clock for bidding |
| `PLAY_TIMEOUTS` | `10s,8s,6s,5s` | turn clock for playing a card, by trick position (leader first) |
| `RECONNECT_GRACE` | `2m` | how long a dropped player keeps their seat |
| `HAND_ADVANCE_WAIT` | `5s` | how long the table waits for stragglers between hands |
| `ROOM_IDLE_TTL` | `5m` | how long an empty table survives |
| `MATCH_FILL_WAIT` | `20s` | how long a quickplay table holds the door open once it can start |
| `MATCH_MIN_PLAYERS` | `2` | humans a quickplay table needs before it will deal |
| `START_COUNTDOWN` | `3s` | pause before a quickplay table deals |
| `MAX_ROOMS` | `50000` | tables per node |
| `MAX_CONNS_PER_IP` | `64` | sockets per address |
| `MSG_RATE_PER_SECOND` / `MSG_BURST` | `20` / `40` | per-connection frame budget |
| `SHUTDOWN_GRACE` | `20s` | drain window on SIGTERM |
| `ALLOWED_ORIGINS` | — | browser origins; native clients send no `Origin` |
| `ADMIN_TOKEN` | — | unlocks `/admin` and the `/v1/admin/*` API; empty disables the dashboard entirely |
| `ENABLE_PPROF` | `false` | mounts `/debug/pprof` — never expose publicly |

The pacing defaults deliberately match `TablePacing` in
`frontend/lib/net/local_session.dart`, so a networked table feels the same as
the offline one.

## Operating it

- `GET /healthz` — liveness. Up means up.
- `GET /readyz` — readiness. Goes 503 while draining, so the load balancer stops
  sending new players before the tables are torn down.
- `GET /metrics` — Prometheus. `callbreak_rooms_active`,
  `callbreak_players_connected`, `callbreak_matchmaking_open_tables`,
  `callbreak_turn_timeouts_total`, `callbreak_ws_send_drops_total`,
  `callbreak_room_step_seconds` are the ones worth alerting on.
- `GET /admin` — the operations dashboard, when `ADMIN_TOKEN` is set. Shows
  every live table (phase, seats, bids, tricks, every pending clock, and each
  player's hand), the recorded match history with per-hand scoreboards, and
  edits the runtime pacing and quickplay defaults from the browser. Changes
  apply to tables created afterwards and are stored in Postgres when one is
  configured, so a restart keeps them. The page and its `/v1/admin/*` API are
  both gated by the token.

On `SIGTERM` the server stops accepting connections, tells every table it is
going away, waits up to `SHUTDOWN_GRACE`, and exits.
