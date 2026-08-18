# Build Call Break From Scratch — Step-by-Step Roadmap

> **Prefer hands-on?** The same curriculum exists as an interactive, step-by-step
> web course — quizzes, write-it-yourself code checks, tracked progress, and
> in-app markdown docs. Open `docs/course/index.html` in any browser (no install
> needed) and read this file in the **Reference docs** section of the sidebar.
> This written roadmap is the same material in prose form.

A guided rebuild of this repository, aimed at a 7+ year backend developer with
zero Flutter/mobile experience. Each phase has a **goal**, the **concepts** you
must learn first, a **backend analogy** to anchor them, concrete **tasks**, the
**reference files** in this repo to compare against (your answer key), and a
**definition of done** you can verify.

> **How to use the answer key.** This repo is the finished product. Do not read
> the reference files first. Do the task from your own head, get it working,
> *then* open the reference and steal what you missed. Rebuilding from memory
> is what makes it stick; reading first is just skimming.

The whole app is built in a deliberate order so every milestone runs and is
testable on its own. Estimated total: **4–8 focused weekends**, frontend first,
backend last (your strong suit — it'll feel like a holiday).

---

## The end state: architecture map

What you are building toward, folder by folder (the frontend tree, pruned):

```
frontend/lib/
  main.dart                  app wiring: init storage → runApp → theme
  engine/                    PURE LOGIC — no Flutter imports at all
    card.dart                PlayingCard, Suit, deal, TrickPlay + JSON
    rules.dart               legal moves, trick winner, scoring, bid estimate
    game.dart                CallBreakGame state machine + redacted GameView + GameEvent stream
  bots/bot.dart              heuristic opponent (bid estimate + card picker)
  state/                     persistent-ish app state, provided via InheritedWidget
    app_settings.dart        AppSettings (ChangeNotifier) + SettingsScope
    identity_store.dart      device id + REST token on shared_preferences
    active_game_binding.dart persists "I'm mid-game, resume me"
  net/                       three interchangeable session implementations + HTTP + upload
    session.dart             GameSession/NetworkSession abstracts (the UI's only contract)
    local_session.dart       solo-vs-bots: engine + bot pacing timers on this device
    remote_session.dart      server-backed: WebSocket, lobby, reconnect, autoplay
    lan_host_session.dart    this device hosts a table for nearby devices
    lan_discovery.dart       UDP broadcast so LAN guests find the host
    api_client.dart          REST client (auth, profile, history, stats)
    api_models.dart          REST wire models (hand-written JSON)
    game_uploader.dart       offline queue: upload finished games when online
  audio/audio_controller.dart  music + SFX via audioplayers
  design/                    tokens.dart (colors/fonts), metrics.dart (sizes)
  ui/
    screens/                 home, table, profile, settings_sheet, lan
    widgets/                 felt_table, hand_fan, seat_view, bid_panel,
                             scoreboard, turn_clock, playing_card_view, …
frontend/test/               unit + widget tests; engine_test is the heart
backend/                     Go server (see backend/README.md) — build LAST
docs/course/                 this roadmap as an interactive course
docs/                        this roadmap + the concept map + the API specs
```

---

## Phase 0 — Toolchain + Flutter mental model (½ day)

**Goal:** `flutter run` shows the counter app on a device/emulator.

**Learn:**
- Install Flutter SDK, Android Studio + emulator (or a physical phone via USB),
  VS Code + Flutter extension.
- `flutter doctor` green. `flutter create my_app` — inspect what it generates:
  `pubspec.yaml` (the `package.json`/`go.mod`), `lib/main.dart` (the entry),
  the platform folders you mostly never touch.
- The two hot buttons: **hot reload** (`R`) and hot restart (`Shift+R`). This
  is your old "rebuild + redeploy" loop compressed to a second.
- `flutter run`, `flutter test`, `flutter analyze`.

**Backend analogy:** Flutter is a runtime + renderer + package manager in one.
`pubspec.yaml` is your manifest; `flutter pub get` is `go mod download`; the
widget tree is your view layer.

**Task:** create a throwaway app, run it, hot-reload a string change, write one
test, run it. Keep this app for scribbling during later phases.

**Definition of done:** counter app runs on emulator; `flutter test` green on
the template.

---

## Phase 1 — Dart from a backend's eyes (1–2 days)

**Goal:** read and write idiomatic Dart confidently.

**Learn** (in this order, each one an hour):
1. **Null safety** — `String?` vs `String`, `!`, `?.`, `??`. Feels like
   TypeScript/Kotlin. This is the biggest culture shift; the compiler enforces
   it everywhere.
2. **Classes + `const` constructors.** `const PlayingCard(14, Suit.spades)`
   means "this is immutable and can be shared/frozen" — a big perf and
   correctness idea. Most models here are const-able.
3. **Enums + extensions.** `enum Suit { spades, ... }` then
   `extension SuitInfo on Suit { String get symbol => ... }`. An extension is
   "methods on a type without owning the type" — the cleanest feature you'll
   learn.
4. **Switch expressions + sealed classes.** `int get value => switch (this) { ... }`.
   Read `engine/game.dart`'s `sealed class GameEvent` and its subclasses — a
   sealed hierarchy forces every `switch` to be exhaustive, like an exhaustive
   `select` over a tagged union. Compile-time exhaustiveness is your friend.
5. **Collections:** `List`, `Map`, spread `...`, collection-`if`/`for`,
   `where`/`map`/`reduce`. Reads like Java streams.
6. **Async:** `Future`/`async`/`await` (you know this already), and
   **`Stream<T>`** — a push-based sequence. See the cheat sheet in
   `docs/CONCEPT_MAP.md`.

**Backend analogy:** Dart ≈ Kotlin's ergonomics with Java's rigidity, plus
`async`/`await` first-class, plus compile-time null safety.

**Task:** write a small pure-Dart file that models a deck: an enum, a class with
`==`/`hashCode` overrides, a switch expression, and a `Stream` that emits dealt
cards. This is `engine/card.dart` in miniature — you'll rewrite it properly next
phase.

**Reference:** `frontend/lib/engine/card.dart`, `frontend/lib/engine/rules.dart`.

**Definition of done:** your scratch file runs (`dart run` or a `flutter test`)
and you can explain each of the six features above from memory.

---

## Phase 2 — The game engine: pure Dart state machine (2–3 days)

**Goal:** a complete, testable Call Break engine with zero Flutter imports.

This is the phase where your backend experience pays for itself — it's plain
domain logic, exactly what you write all day. It is also the heart of the whole
project: both the offline game and the Go server later port this exact code.

**Learn:**
- A **pure state machine**: `enum GamePhase { lobby, bidding, playing, handOver,
  gameOver }`, one class owns all state, every mutation is a method that
  returns whether it changed anything.
- **Redaction**: a `viewFor(seat)` method that returns only what that seat may
  see — your hand's cards in full, everyone else's as a *count*. (Test: no
  other seat's card ids may appear in a serialized view. This is a
  security/correctness invariant, like a `SELECT` that never leaks a column.)
- **Events as a sealed hierarchy**: `sealed class GameEvent` with
  `CardPlayed`, `TrickWon`, `HandOver`, `GameOver`, … emitted into a list the
  host drains. This is your "outbox"/event log — the UI and the uploader both
  consume it.
- **Deterministic seeding**: `Random(seed)` so tests can reproduce a deal.
- Hand-written `toJson`/`fromJson` for every model that must cross a wire.

**Build in this order** (each with tests as you go):
1. `card.dart` — `Suit`, `PlayingCard`, `fullDeck`, `dealHands`, `sortForDisplay`,
   `TrickPlay`.
2. `rules.dart` — `legalMoves` (the follow-suit / must-beat / trump rules),
   `trickWinner`, `scoreHand`, `estimateTricks` + `suggestBid` (the heuristic
   the bots use).
3. `game.dart` — `CallBreakGame`: seats, start, `_startHand`, bidding phase,
   playing phase, `playCard`, trick resolution, hand scoring, game over with
   rankings, the `viewFor` redaction, the event outbox.

**Backend analogy:** the engine is your domain service + aggregate. `viewFor`
is your API-projection boundary. The event list is your domain events. The
tests are your contract tests.

**Reference:** `frontend/lib/engine/*`, and `frontend/test/engine_test.dart`
(17 test cases covering bidding, legality, scoring, redaction, and game flow —
read them *after* you've written your own).

**Definition of done:** `flutter test test/engine_test.dart` green. Bonus: write
a tiny `bin/` or test that plays a full 5-hand game against random cards and
asserts the totals sum correctly.

---

## Phase 3 — Static UI: theme, home screen, card art (2–3 days)

**Goal:** a beautiful, static home screen that renders playing cards. No game
logic yet — this is where you learn the Flutter view layer.

**Learn:**
- **`StatelessWidget` vs `StatefulWidget`** — when state belongs to a widget vs
  when it's pure.
- **Layout:** `MaterialApp`, `Scaffold`, `Column`/`Row`, `Stack` (the felt table
  is one big `Stack`), `Padding`, `Spacer`, `FittedBox`.
- **`ThemeData`** — dark theme, `ColorScheme.fromSeed`, custom fonts declared in
  `pubspec.yaml` and applied via `fontFamily`.
- **Design tokens:** colors/sizes in one place (`design/tokens.dart`,
  `design/metrics.dart`) instead of inline literals — like a CSS custom
  property file. Notice the deliberate "nothing hard-codes a colour" rule.
- **`InkWell`/`GestureDetector`** for taps.
- **`const` everything** — a build that reuses `const` widgets is the idiomatic
  perf pattern.

**Build:**
1. `design/tokens.dart` + `design/metrics.dart` — steal the palette feel:
   dark felt-green background, gold accent (the Call Break brand).
2. `main.dart` — `MaterialApp` with `ThemeData`, dark, custom font.
3. `ui/screens/home_screen.dart` — the four play-mode cards (vs Bots, Online,
   Private, LAN) as tappable cards. Use `StatefulWidget`; wire the taps to a
   `debugPrint` for now.
4. `ui/widgets/playing_card_view.dart` — render one card: rounded rect,
   corner pips, suit symbol, red for hearts/diamonds, gold edge for trump.
5. `ui/widgets/hand_fan.dart` — lay your hand in a fan: trumps first, slightly
   fanned/overlapped, using the engine's `sortForDisplay`.

**Backend analogy:** widgets are your templates/views; `ThemeData` is your
design system; tokens are your CSS variables. `const` widgets are cached
sub-expressions — the renderer skips rebuilding them.

**Reference:** `frontend/lib/design/*`, `frontend/lib/ui/screens/home_screen.dart`,
`frontend/lib/ui/widgets/playing_card_view.dart`, `frontend/lib/ui/widgets/hand_fan.dart`.

**Definition of done:** home screen shows four styled cards; tapping prints; a
fanned hand of cards renders in the correct order. This is the first moment the
app *looks* like a card game.

---

## Phase 4 — The table: render a live solo game vs bots (4–5 days)

**Goal:** a fully playable game against three bots on one device. The biggest
phase — you'll finish it feeling like a Flutter dev.

**Learn:**
- **`ChangeNotifier` + `ListenableBuilder`** — the state-management pattern.
  A session object holds state and calls `notifyListeners()`; widgets subscribe.
  This is *the* idea of the whole UI layer, so get it solid.
- **`StreamSubscription` lifecycle:** subscribe in `initState`, cancel in
  `dispose`. Never leak a subscription.
- **`Timer` for pacing** — bot think time, trick linger, turn clocks.
- **Layering with `Stack`** — the felt, seat views around the edges, your hand
  at the bottom, overlays (bid panel, scoreboard) on top.
- **The abstraction that makes it all work:** `GameSession` (`net/session.dart`).
  The table screen only ever talks to this interface — a redacted `GameView`,
  an event stream, and three intents (`placeBid`, `play`, `continueToNextHand`).
  When you later swap in a network-backed session, the table screen doesn't
  change at all. **This is your single most important design decision.** It's
  like defining a `Service` interface and letting both a local and a remote
  implementation satisfy it.

**Build:**
1. `bots/bot.dart` — `BotBrain`: choose a bid from `suggestBid` + noise, pick a
   card from `legalMoves`. Difficulty = how much noise/blunder. (Port
   `internal/bot/brain.go`'s twin later.)
2. `net/local_session.dart` — a `GameSession` that owns the engine, three bot
   brains, and the pacing timers. `_publish()` = take the redacted view → drain
   engine events → `notifyListeners()` → schedule the next bot move. This
   method is the rhythm of the whole app.
3. `ui/screens/table_screen.dart` — the table: seat views (yours is gold), the
   trick area, your hand, a bid panel when bidding, a scoreboard between hands.
   Listen to the session's events for a card-lift flash and trick-won cue.
4. `ui/widgets/*` — `felt_table.dart`, `seat_view.dart`, `bid_panel.dart`,
   `scoreboard.dart`, `turn_clock.dart`. Build them as you need them.

**Backend analogy:** `GameSession` is your service interface; `LocalSession` is
the implementation behind a fake transport. The `Timer`-driven bot turns are a
scheduler. `notifyListeners()` is your pub/sub.

**Reference:** `frontend/lib/net/session.dart`, `frontend/lib/net/local_session.dart`,
`frontend/lib/bots/bot.dart`, `frontend/lib/ui/screens/table_screen.dart`,
`frontend/lib/ui/widgets/*`.

**Definition of done:** you can play a full 5-hand game against bots with
turn clocks, scoring, and a winner screen. `flutter test` on `auto_play_test.dart`
and `turn_clock_test.dart` passes.

---

## Phase 5 — Offline state: settings, identity, audio (1–2 days)

**Goal:** settings persist across restarts, the app remembers who you are, and
music/SFX play.

**Learn:**
- **`shared_preferences`** — the simplest durable store (key-value JSON on disk).
- **`InheritedWidget`** — a scope that provides one object to the whole subtree
  (`SettingsScope`). The Flutter-native alternative to a DI container.
- **Async one-time init in `main`** — open storage *before* `runApp`, so widgets
  read plain values, not futures.
- **The `clock` package** — injectable time so tests can wind clocks forward
  instead of waiting. (`test/fake_async` does similar for timers.)
- **`audioplayers`** for sound.

**Build:**
1. `state/identity_store.dart` — persist device id + REST token; `Random.secure()`
   for the id (no uuid package needed).
2. `state/app_settings.dart` — `AppSettings extends ChangeNotifier` with a
   `SettingsScope` InheritedWidget; theme/card-style/difficulty/server-url/
   animation-speed toggles.
3. `audio/audio_controller.dart` — background music + card/thump SFX, gated by
   the settings.
4. `ui/screens/settings_sheet.dart` + `profile_screen.dart` — the sheets that
   edit all of it.

**Backend analogy:** `shared_preferences` is a tiny KV store; `IdentityStore`
is your auth/session storage; the `clock` injection is exactly what you'd do to
make a time-dependent service testable.

**Reference:** `frontend/lib/state/*`, `frontend/lib/audio/*`.

**Definition of done:** change a setting, kill the app, relaunch — it persists.
`test/profile_screen_test.dart` green.

---

## Phase 6 — REST layer: API client + models (2 days)

**Goal:** the app talks to a server over HTTP: guest login, profile, history,
statistics. Pure backend work — a comfort phase.

**Learn:**
- The `http` package (or `dio` if you prefer).
- Hand-written JSON models (`api_models.dart`) that decode **leniently** — read
  the keys you know, ignore the rest, so old clients survive new server fields
  (see `backend/docs/API.md` "Adding a field is safe").
- **Injectability for tests** — the client takes a base URL / transport, so
  tests can feed it literal JSON without a live server.

**Build:**
1. `net/api_models.dart` — `user`, `gameSummary`, `statistics`, `historyPage`
   models with `fromJson`.
2. `net/api_client.dart` — guest device login (`POST /v1/auth/device`), bearer
   token storage, profile/history/statistics endpoints, error mapping
   (`error{code,message}` → typed exceptions).
3. Wire the profile screen and home-screen stats to it.

**Backend analogy:** this is a typed HTTP client + DTOs, the thing you've built
a hundred times. The interesting part is the *conventions* both sides agree on —
read `backend/docs/API.md` closely; it's the contract doc you'd normally write.

**Reference:** `frontend/lib/net/api_client.dart`, `frontend/lib/net/api_models.dart`,
`frontend/test/api_contract_test.dart` (it verifies the client against the
literal JSON from `backend/docs/API.md` — a contract test without a server).

**Definition of done:** with the Go server running, the app logs in as a guest,
shows a profile, and lists match history. `test/api_contract_test.dart` green.

---

## Phase 7 — WebSockets: online play + reconnection (4–6 days)

**Goal:** play a real networked table against other humans through the Go
server — lobby, bidding, playing, reconnect-after-drop.

This is where the app becomes a *multiplayer* game, and where the session
abstraction from Phase 4 pays off.

**Learn:**
- **WebSocket client** in Dart (`WebSocket.connect`, JSON text frames).
- The **wire protocol** — read `backend/PROTOCOL.md` cover to cover: `join`,
  `lobby`, `view`, `bid`, `play`, `next`, `restart`, `ping`/`pong`. Note the
  compatibility rules (additive fields are safe; the version handshake).
- **Redaction you already trust** — the server only sends `view` (per-seat
  redacted), exactly like your engine's `viewFor`. Same invariant, other side.
- **Reconnection:** a dropped socket must resume the *seat*, not just reconnect.
  That's `resumeToken` (reclaims the seat, only if it's still yours, within the
  grace window) + device id. The `active_game_binding` remembers "I'm mid-game"
  across app restarts so the app can offer "Rejoin your game?".
- **Autoplay:** when a human stops responding the server plays for them; any tap
  (`wakeUp`) takes the seat back.
- **Clock skew handling** — the server sends deadlines in its own time; the
  client converts to *durations* because two clocks disagree. Read the comment
  on `turnDeadline` in `session.dart`; it's a genuinely subtle bug you'd ship.

**Build:**
1. `net/remote_session.dart` — a `NetworkSession` (extends `GameSession`):
   connect, send `join`, handle `lobby`/`view`, forward intents as frames,
   backoff + reconnect, resume-token reclaim, autoplay awareness, `ping`/`pong`.
2. `net/active_game_binding.dart` — persist "in a game, seat N, resumeToken T"
   so a cold start can offer the rejoin path.
3. Extend `table_screen.dart` with lobby rendering (seats + start button /
   countdown) — the `NetworkSession.lobby` surface.
4. Private room creation with 4-char codes; quickplay (matches into a table).

**Backend analogy:** this is a stateful WebSocket client with re-authentication
on resume, heartbeat, and dead-mans-switch (autoplay). The reconnect policy is
the same retry/backoff logic you'd write for a flaky upstream.

**Reference:** `frontend/lib/net/remote_session.dart`, `frontend/lib/net/session.dart`,
`backend/PROTOCOL.md`, `frontend/test/wire_contract_test.dart`,
`frontend/test/join_sheet_test.dart`.

**Definition of done:** two emulators (or phone + emulator) join the same
private table and play each other through the Go server; kill one app, restart
it, and it offers to rejoin the seat. `test/wire_contract_test.dart` green.

---

## Phase 8 — LAN host mode (2–3 days)

**Goal:** one device *hosts* the table (engine + bots) for friends on the same
Wi-Fi — no internet needed. Phone-to-phone play without a server.

**Learn:**
- `dart:io` `ServerSocket`/`HttpServer` + a minimal WebSocket server inside the
  app — your phone becomes the "Go server" for the table.
- **UDP broadcast discovery** (`lan_discovery.dart`) so guests find the host
  without typing an IP.
- The `LanHostSession` runs the same engine + bot pacing as `LocalSession`, but
  drives *remote* human seats too.
- **Multi-instance testing:** `scripts/launch_multi_instance.sh` launches
  several copies of the app on one machine so you can play four seats yourself.

**Backend analogy:** this is you embedding a mini game server in the client —
same engine, same protocol, now hosted on-device. The host is an actor owning
the whole table.

**Reference:** `frontend/lib/net/lan_host_session.dart`,
`frontend/lib/net/lan_discovery.dart`, `scripts/launch_multi_instance.sh`,
`frontend/test/lan_host_deal_test.dart`, `frontend/test/lan_guest_restart_test.dart`.

**Definition of done:** two phones on the same network, one hosts, both play.
`test/lan_host_clock_test.dart` green.

---

## Phase 9 — Offline upload queue (1 day)

**Goal:** games finished while offline are queued and uploaded when the app next
starts online.

**Learn:**
- **Idempotency keys** — each game gets an id at deal time, so a retried upload
  resolves to the same game and can't double-record.
- **Bounded/queued upload** with `GameUploader.install(...)` kicked off in
  `main` *before* the home screen shows, deliberately not awaited.
- `local_session.dart` records events as it plays and enqueues at `GameOver`.

**Reference:** `frontend/lib/net/game_uploader.dart`, `frontend/test/game_upload_test.dart`.

**Backend analogy:** an offline-first write-behind queue with idempotency — the
classic distributed-systems pattern you know as "outbox". Cheap win.

**Definition of done:** play a game with the server unreachable, restart the app
online, and the game appears in server history exactly once.

---

## Phase 10 — The Go backend (map; your strong suit, 3–5 days)

**Goal:** rebuild the server that the app talks to. You know this world; the
roadmap here is just the build order. Read `backend/README.md` first — it is
the best architecture note in the repo.

**Build order:**
1. **Protocol + engine port** — port `engine/card.dart`/`rules.dart`/`game.dart`
   to Go (`internal/engine`). The rule: the Go engine's tests are ported
   case-for-case from `frontend/test/engine_test.dart`. If they disagree, the
   client and server disagree about the rules — the one bug class this project
   cannot afford.
2. **`internal/bot`** — port `BotBrain` (it's already written in Dart).
3. **`internal/room`** — the actor: one goroutine per table owning engine, seats,
   timers, and client handles. Everything else posts messages to its inbox.
   Locks off the hot path; a panic costs one table, not the process.
4. **`internal/ws`** — WebSocket edge: upgrade, auth, validation, routing.
5. **`internal/auth`** — guest identities + `resumeToken`s.
6. **`internal/match`** — quickplay seating.
7. **`cmd/server`** — config → deps → HTTP → graceful drain; observability
   (`internal/obs`), metrics, `/healthz` `/readyz`.
8. **Persistence** (`internal/db`, `migrations/`) — optional Postgres: accounts,
   match history, stats. Read `docs/PERSISTENCE.md` for the design.
9. **`internal/store`** — optional Redis room registry for horizontal scaling
   (advisory, not authoritative).
10. **`cmd/loadtest`** — real-websocket load test (the p50/90/99 table in
    `backend/README.md`).

**Backend analogy:** this is a Go service you'd write at work. The novel bits
are the actor-per-table model and the redaction-at-the-boundary rule.

**Reference:** `backend/README.md`, `backend/PROTOCOL.md`, `backend/docs/API.md`,
`backend/docs/PERSISTENCE.md`. `make test`, `make test-db`, `make race`, and
`make build` + `./bin/loadtest` are your verification gates.

**Definition of done:** `make test` green, `make race` clean, loadtest shows
single-digit-millisecond p99, two phones play through it, restart-mid-game →
rejoin works.

---

## Phase 11 — Polish + ship (1–2 days)

**Goal:** feel and distribution.

- **Animations** — the card flight when you throw a card, dealing flourish,
  drag-to-play. Study `table_screen.dart`'s `_flights` and
  `ui/widgets/pulse_ripple.dart` last; animation is the deepest Flutter rabbit
  hole, so it's the final garnish.
- **App icon, splash, asset audio** (`assets/`, `music_to_use/`).
- **Build per platform** — `flutter build apk`, `flutter build appbundle`,
  `flutter build ios`, TestFlight/Play Console.

---

## The learning loop (rules that make this stick)

1. **Type it, don't paste it.** Every snippet in these docs is meant to be
   written by hand.
2. **Read the answer key after, not before.** Struggling for an hour then
   reading `local_session.dart` teaches more than reading it upfront.
3. **Keep the loop short:** one engine method → its test → run. Never two hours
   of writing without a compile.
4. **Use the project's own invariants as your specs.** "No other seat's card ids
   in a view", "hand-written JSON, additive-only fields", "the table screen only
   talks to `GameSession`" — these are the tests you're building toward.
5. **`flutter analyze` and `flutter test` are your `go vet` + `go test`.**
   Run them every phase. The lints (`analysis_options.yaml`) are opinionated;
   that's a feature — they teach the idiom.

## Order cheat-sheet (the short version)

```
setup → Dart → engine (+tests) → static UI → table vs bots → state/audio
→ REST → WebSocket online play → LAN host → upload queue → Go backend → polish
```

Build the engine and the UI *before* you build the backend: by the time you
reach Go, every rule, bot, and protocol choice is already locked in Dart and
tested, and porting is mechanical.
