# Backend → Flutter/Dart Concept Map

> **Note — the app is now a Godot client.** The client in this repository was
> rewritten in Godot 4.5 and lives in `godot/` (see `godot/README.md`). This
> material teaches the *original* Flutter client, which is no longer in the
> working tree. Its code — the answer key the phases below point at — is still in
> git history: `git worktree add ../callbreak-flutter f5940e7` checks it out with
> `frontend/` intact. The Go backend sections still match the current code.

A translation dictionary for a backend developer learning Flutter by rebuilding
this project. Every concept you already know has a Flutter-shaped twin. When you
get lost, come back here.

The rule of thumb that explains 80% of Flutter: **the widget tree *is* your
render loop and your DI container at the same time.** Widgets are declarative
views that rebuild whenever the state they listen to changes. There is no manual
DOM updating, no `setState`-everywhere spaghetti, and no separate dependency
injection framework — you hand constructors what they need, exactly like you
would when wiring a service in `main.go`.

---

## The one-to-one table

| Backend (what you know) | Flutter/Dart (what you're learning) | Where it lives in this project |
|---|---|---|
| A service / controller class | `StatefulWidget` + a `ChangeNotifier` | `net/session.dart` (`GameSession`), `state/app_settings.dart` |
| Framework-agnostic domain logic | Pure Dart classes, no Flutter imports | `engine/` — `card.dart`, `rules.dart`, `game.dart` |
| Event-driven bus (Kafka, SQS) | `Stream<T>` / `StreamController<T>` | `GameSession.events`, `engine/game.dart`'s `GameEvent` sealed class |
| Message queues + handlers | `Stream` + `StreamSubscription` (subscribe in `initState`, cancel in `dispose`) | `table_screen.dart` listens to `session.events` for sounds/animations |
| JSON serialization by hand | Hand-written `toJson()` / `factory X.fromJson()` (deliberately no codegen here) | everywhere in `engine/`, `net/api_models.dart` |
| Dependency injection / wiring in `main()` | Constructor injection + `InheritedWidget` scope | `main.dart` builds `AppSettings` once, `SettingsScope` provides it down the tree |
| Config files / env vars | `--dart-define`, `pubspec.yaml`, typed settings objects | `state/app_settings.dart`, server URL in `state/app_settings.dart` |
| ORM models | Plain immutable model classes (often `const`-constructible) | `PlayingCard`, `PlayerInfo`, `GameView` |
| Enums + exhaustive switch | Enums + switch expressions / pattern matching | `Suit`, `GamePhase`, `switch (this)` extensions in `card.dart` |
| `Select`/`Projection` (what a seat may see) | Redacted view objects | `CallBreakGame.viewFor(seat)` → `GameView` |
| Cron / background timers | `Timer` from `dart:async` | bot pacing, turn clocks in `local_session.dart`, `remote_session.dart` |
| Scheduler/actor loop | `ChangeNotifier.notifyListeners()` + a `_publish()` that queues the next move | `LocalSession._publish()`, `_scheduleNextAutoAction()` |
| Async I/O, Futures | `Future`, `async`/`await`, `unawaited()` | `main.dart`, `identity_store.dart`, uploader |
| `goroutine` + channel | `Isolate` + `SendPort` (rarely needed; default is single-threaded event loop) | not used — the async model covers it |
| Unit tests | `flutter test` (same syntax as any Dart test) | `test/engine_test.dart` |
| Integration test against real stack | Widget tests (build a widget tree, tap, assert) | `test/profile_screen_test.dart`, `test/lan_host_clock_test.dart` |
| DB-backed sessions | `shared_preferences` (or sqflite/Hive) for tiny durable state | `state/identity_store.dart` |
| A hostname/IP + port | No such thing — you target **platform folders** | `android/`, `ios/`, `web/`, `linux/`, `windows/`, `macos/` |
| Deploy a binary | Build per platform (`flutter build apk`, `flutter build ios`, …) | build output, not source |

---

## Reading order if you only read one file per concept

| I want to understand… | Read first |
|---|---|
| The whole app's wiring | `lib/main.dart` (~90 lines) |
| The domain model | `lib/engine/card.dart`, `lib/engine/rules.dart` |
| The state machine | `lib/engine/game.dart` |
| How UI meets logic without a framework | `lib/net/session.dart` (the `GameSession` abstraction) |
| How a solo game drives itself | `lib/net/local_session.dart` |
| How state is provided to widgets | `lib/state/app_settings.dart` (`SettingsScope`) |
| How JSON crosses the wire | `lib/net/api_models.dart`, `backend/docs/API.md` |
| The network contract | `backend/PROTOCOL.md` |

---

## The three mental model shifts

1. **You don't push updates to the screen — you change state and the framework
   rebuilds.** `notifyListeners()` on a `ChangeNotifier` is the whole publish
   model. Widgets that depend on it re-run their `build()`. Compare:
   `GameSession` extends `ChangeNotifier`; the table screen rebuilds when it
   fires. There is no `setState` deep in the session layer, ever.

2. **Everything is a widget, including layout.** A column, a stack, a padding,
   a gesture handler — all widgets composing a tree. Think of it like JSX but
   for layout primitives too.

3. **The Flutter engine draws everything; there is no HTML/CSS.** Colors come
   from `Color(0xFF…)` literals, layout from `Row`/`Column`/`Stack`, styling
   from `ThemeData` and `TextStyle`. The "CSS" lives in Dart code. This
   project keeps it tidy with design tokens in `lib/design/tokens.dart` and
   metrics in `lib/design/metrics.dart`.

---

## Async cheat sheet (the part most backend devs trip on)

```dart
Future<void> open() async {           // like an async handler
  final id = await readFromDisk();    // await, like every language you know
}

// Fire-and-forget that the linter won't flag:
unawaited(uploader.enqueue(payload));

// A one-shot delayed action:
Timer(Duration(seconds: 5), () => doThing());

// A broadcast event bus:
final events = StreamController<GameEvent>.broadcast();
events.add(event);                    // publish
events.stream.listen((e) => handle(e)); // subscribe
```

That last one — `Stream` — is the workhorse of the whole app. The engine emits
`GameEvent`s (`CardPlayed`, `TrickWon`, `HandOver`, `GameOver`), the session
re-emits them, and widgets subscribe to animate and play sounds. It is the
closest thing this app has to a message bus, and it is stdlib — no package.

---

## What this project deliberately does NOT use (so don't feel pressured to)

- **No state-management library** (no provider, Riverpod, Bloc, GetX). Plain
  `ChangeNotifier` + `ListenableBuilder` + an `InheritedWidget` for settings.
  Rebuilding it yourself first is the better way to learn what those libraries
  do for you.
- **No JSON codegen** (`json_serializable`/`freezed`). Every model has a
  hand-written `toJson`/`fromJson`. Verbose, but zero build_runner magic and
  easy to debug.
- **No DI framework.** Constructors and `main.dart` wiring do it.
- **No `uuid` package.** `Random.secure()` in `state/identity_store.dart` is
  enough for a v4.
