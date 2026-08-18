/* Build Call Break — modules 0-3: setup, Dart, engine, static UI.
   Each step: learn (concept) + do (ordered build actions) + explain
   (code walkthrough) + alternatives + improve + activity + done + refs. */

REGISTER(C.module("m0", "🛠", "Setup & Mental Model", "toolchain, project skeleton, the 3 commands", [
  C.step("m0s1", "Install the toolchain", {
    learn: [
      C.h("The mental model"),
      C.p("Flutter is a compiler + virtual display + package manager in one binary. Your old build-and-redeploy loop becomes hot reload — edit, press R, the running app updates in under a second. Today you configure that loop."),
      C.b("flutter run — launch the app on a device/emulator."),
      C.b("flutter pub get — resolve dependencies (your `go mod download`)."),
      C.b("flutter analyze + flutter test — your `go vet` + `go test` quality gate."),
    ],
    do: [
      C.p("Download the stable Flutter SDK, unpack it, add <code>bin/</code> to your PATH. On Linux/macOS that's an export in your shell rc file."),
      C.p("Install Android Studio (emulator + Android SDK) OR plug in a physical phone with USB debugging. A phone is faster and more honest; the emulator is fine to start."),
      C.p("Install VS Code + the Flutter and Dart extensions."),
      C.p("Run <code>flutter doctor</code> and clear every warning it lists — treat it as a preflight check. The usual culprits: missing Android licenses, no device, SDK path."),
      C.p("Memorize the loop — you will type it hundreds of times:"),
      C.code("flutter pub get    # resolve deps\nflutter analyze   # static checks + lints\nflutter test      # run the test suite\nflutter run       # launch on device", "shell"),
    ],
    explain: [
      C.p("Nothing here is Flutter logic yet — it's environment. But get it right because every later phase assumes it. <code>flutter doctor</code> is your only friend when the toolchain silently misbehaves: it prints exactly which part is broken."),
      C.p("The three commands map onto what you already run daily: <code>pub get</code> is dependency resolution, <code>analyze</code> is the linter that also understands Dart's type system, and <code>test</code> runs your unit and widget tests. If a step's 'definition of done' says 'analyze is clean', you are expected to run it and fix what it flags."),
    ],
    alternatives: [
      { title: "FVM (Flutter Version Management)", text: "Pin the exact Flutter version per project with FVM. Useful once you maintain multiple apps on different SDK majors — like using a container for your Go toolchain. Overkill on day one; add it when a `flutter upgrade` breaks a project." },
      { title: "Fleet / IntelliJ instead of VS Code", text: "JetBrains' Flutter support is excellent if you already live in their IDEs. VS Code is lighter and the Flutter extension is first-class; either works." },
      { title: "Web as a first target", text: "`flutter run -d chrome` runs the app in a browser with no emulator at all — the fastest possible way to iterate on UI before touching a device. Good trick for Phase 3+." },
    ],
    improve: [
      { title: "CI from day one", text: "GitHub Actions: on every push run flutter pub get, analyze, test, and fail the job on any warning. You already practice this for backend deploys — extend the habit here." },
      { title: "Script the setup", text: "A setup.sh that installs the SDK, runs flutter doctor, and prints a checklist means a fresh laptop is an hour, not an afternoon." },
      { title: "Team-wide lint contract", text: "Commit analysis_options.yaml (this repo already has a tuned one) so every machine and CI agrees on what 'clean' means." },
    ],
    activity: {
      type: "code",
      starter: "",
      checks: [
        CHK.has("ran flutter doctor", "flutter\\s+doctor", "Run `flutter doctor` first — output belongs in the box too, that's fine."),
        CHK.has("knows pub get", "pub\\s+get", "Type the dependency command you'll run after changing pubspec.yaml."),
        CHK.has("knows analyze", "analyze", "The static-analysis command."),
        CHK.has("knows test", "flutter\\s+test", "The test command."),
      ],
    },
    done: [
      "flutter doctor reports no blocking issues.",
      "You can explain what pub get, analyze and test do without looking.",
    ],
    refs: ["backend/README.md (Running it)", "frontend/pubspec.yaml"],
  }),
  C.step("m0s2", "Scaffold a project", {
    learn: [
      C.h("What the template gives you"),
      C.p("flutter create makes a runnable counter app: lib/main.dart (entry point), pubspec.yaml (manifest), platform folders (native shells you almost never touch), and test/ (your go test). The counter app is your scratch canvas for the next few phases."),
    ],
    do: [
      C.p("Create a scratch app you will experiment in for the whole course (you'll rebuild the real Call Break structure later):"),
      C.code("flutter create callbreak_scratch\ncd callbreak_scratch\nflutter run", "shell"),
      C.p("Open <code>lib/main.dart</code> and read it top to bottom. It's ~90 lines and does three things: <code>runApp</code>, a <code>MaterialApp</code> with a theme, and a counter with <code>setState</code>."),
      C.p("Break it on purpose: change the counter to start at 42, hot-reload (R), watch it update instantly. Then add a typo and watch <code>flutter analyze</code> flag it."),
      C.p("Open <code>pubspec.yaml</code> and compare it to the real one in <code>frontend/pubspec.yaml</code>. Note the difference: the real app declares real dependencies."),
      C.p("Run the template test and make it pass/fail on purpose to see the test runner's output."),
    ],
    explain: [
      C.p("The template's <code>main()</code> is your <code>main.go</code>: <code>void main() { runApp(...) }</code> boots the widget tree. The critical idea to absorb now — a Flutter app is a tree of widgets, and the framework calls each widget's <code>build()</code> whenever something it depends on changes, diffing the result against the last frame. You never manually repaint; you change data and the tree reacts."),
      C.p("The <code>_counter</code> + <code>setState</code> example is the app's idea of state in its smallest form. The Call Break app deliberately goes bigger — a <code>ChangeNotifier</code> session object (module 4) — but the reflex is identical: mutate, notify, rebuild."),
    ],
    alternatives: [
      { title: "flutter create with --platforms", text: "Restrict generation to the platforms you ship (e.g. `--platforms=android,ios`) to keep the repo clean. The real repo generates all desktop targets so you can dev on Linux — a reasonable trade." },
      { title: "Scaffold from a template", text: "very_good_cli or a private starter template ships your team's defaults (folder layout, lint set, CI) in every new app. Worth it once your conventions are stable." },
    ],
    improve: [
      { title: "Make the counter a test", text: "Rewrite widget_test.dart to pump the real app and tap the button twice, asserting the count. This is your first widget test — the pattern you'll use constantly in module 4." },
      { title: "Delete the template cruft", text: "The template's comments and example tests are training wheels. Once the scratch app has served its purpose, delete it entirely — the real project starts fresh in later phases." },
    ],
    activity: {
      type: "quiz",
      q: "Which file is the entry point of a Flutter app, equivalent to main() in a Go program?",
      opts: ["main.go", "lib/main.dart", "pubspec.yaml", "AndroidManifest.xml"],
      correct: 1,
      explain: "lib/main.dart holds the runApp() call that boots the widget tree.",
    },
    done: ["The counter app runs on a device or emulator.", "You can name each folder the template generated and its job."],
    refs: ["frontend/lib/main.dart"],
  }),
  C.step("m0s3", "Read pubspec.yaml like a go.mod", {
    learn: [
      C.h("The manifest"),
      C.p("Everything your app depends on and bundles lives in pubspec.yaml. The real Call Break app is deliberately minimal — four runtime deps, nothing for state management or JSON. Study that choice; it's the course's philosophy in one file."),
    ],
    do: [
      C.p("Read the real manifest and tick off each dependency against its job:"),
      C.code("name: callbreak\ndescription: \"Call Break — multiplayer trick-taking card game.\"\npublish_to: 'none'\nversion: 1.0.0+1\n\nenvironment:\n  sdk: ^3.11.5\n\ndependencies:\n  flutter:\n    sdk: flutter\n  audioplayers: ^5.2.1   # music + SFX\n  clock: ^1.1.1          # injectable time, for testable turn clocks\n  http: ^1.6.0           # REST client\n  shared_preferences: ^2.5.5  # tiny key-value storage\n\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n  flutter_lints: ^6.0.0\n  fake_async: ^1.3.1\n", "yaml"),
      C.p("Add a dummy dependency to your scratch app, run <code>flutter pub get</code>, then remove it. Watch pubspec.lock appear — that's your go.sum."),
      C.p("Add a font to the scratch app: drop a .ttf into an assets/fonts folder, declare it under <code>flutter: fonts:</code>, set it in the theme, hot-reload. You just learned assets and fonts — the same mechanism bundles audio and images later."),
    ],
    explain: [
      C.p("<code>^3.11.5</code> is a caret range: 3.11.5 or later, below 4.0. Same contract as Go's minimal version selection, but with an upper cap — Flutter treats the first non-zero component as the breaking boundary. <code>dependencies</code> vs <code>dev_dependencies</code> is your regular vs test-only split."),
      C.p("The assets/fonts sections are the interesting part: Flutter does not auto-discover files. Anything the app must reference at runtime — audio, images, fonts — is registered here by path, and the framework bundles only what's listed. Forget a file and it fails at runtime with a silent 'asset not found', never at build time. That gotcha will cost you exactly one debugging session before you internalize it."),
      C.p("The dependency philosophy worth copying: <code>clock</code> is there so turn-clock code calls an injectable now() instead of DateTime.now() — you'll see why in module 4. Every dependency in this list exists because a test needed to control something."),
    ],
    alternatives: [
      { title: "json_serializable / freezed codegen", text: "Most Flutter teams generate JSON models instead of hand-writing them. This project deliberately skips it so you can read every decoder and control leniency. Later, when models multiply, codegen is the 'better way' the course keeps pointing at." },
      { title: "Provider / Riverpod / Bloc", text: "The app manages state with plain ChangeNotifier + InheritedWidget. The popular packages are conveniences on top of exactly those primitives — the roadmap suggestion is to build this project's way once, then adopt a package when the pain appears." },
    ],
    improve: [
      { title: "Lock your toolchain", text: "Commit pubspec.lock (it's already committed here). Reproducible builds on every machine and in CI are worth more than the theoretical flexibility of not locking." },
      { title: "Read the changelogs", text: "The only four runtime deps are auditable in an afternoon. Revisit them each quarter: drop what you no longer need. Minimal deps is a feature, not a default." },
    ],
    activity: {
      type: "quiz",
      q: "What does the ^ in `sdk: ^3.11.5` mean?",
      opts: ["Exactly version 3.11.5 and nothing else", "3.11.5 or later, below 4.0", "At least 3.11.5 with no upper bound", "A deprecated version pin"],
      correct: 1,
      explain: "Caret ranges mean 'compatible with this version', capped below the next major.",
    },
    done: ["You can name each of the 4 runtime dependencies in the real pubspec and what it is for."],
    refs: ["frontend/pubspec.yaml"],
  }),
  C.step("m0s4", "Hot reload & the dev loop", {
    learn: [
      C.h("Your new superpower"),
      C.p("Backend dev: edit → recompile → redeploy → wait. Flutter: edit → press R → the running app updates in under a second. Hot reload keeps state; hot restart rebuilds from scratch. This loop is why you can polish a UI in an afternoon instead of a week."),
    ],
    do: [
      C.p("Launch your scratch app with <code>flutter run</code>."),
      C.p("Change a Text widget, press R, watch it swap instantly. Your session state (a typed name, an incremented counter) survives."),
      C.p("Add a <code>final</code> field with an initializer, press R — note it may not apply (state changed). Press Shift+R (hot restart) and it does. This is the mental split: R for widget code, Shift+R for state-level changes."),
      C.p("Introduce an exception in build(), watch the red error screen, fix it, press R. You've just learned to read a Flutter stack trace."),
      C.p("Run <code>flutter analyze</code> and fix every lint the scratch app trips. Read each rule it cites — the lints teach the idiom."),
    ],
    explain: [
      C.p("Hot reload works by recompiling the widget layer and diffing the new widget tree against the running one. Fields and <code>late</code> state that live in a State object are preserved — which is why R feels instant. When you change something the framework can't diff (a <code>static</code>, an <code>enum</code>, a <code>final</code> with a value), it tells you to hot restart instead."),
      C.p("The stack trace habit: Flutter errors print the whole widget chain — 'The following assertion was thrown building TableScreen...' then the ancestor chain. Read from the bottom widget upward; that's where the bug usually is. Same discipline as unwinding a Go panic, different stack format."),
    ],
    alternatives: [
      { title: "flutter run --release", text: "Debug builds are slower and check assertions; release builds are what ships. If something behaves differently in release (timers, timing, plugin channels), that's the mode to debug in." },
      { title: "devtools / debugger", text: "`flutter run` supports full debugging: breakpoints, watches, and the widget inspector (press 'D' in the console). When a 40-line build method misbehaves, the inspector shows the actual widget tree and lets you tweak values live." },
    ],
    improve: [
      { title: "Golden test your screens", text: "Flutter can snapshot a widget to an image and diff it — golden tests. Add one for the table screen once it's stable to catch visual regressions nobody notices." },
      { title: "Profile on real hardware", text: "Emulators lie about performance. When animations start to jank, profile on a physical phone and read the frame chart before optimizing anything." },
    ],
    activity: {
      type: "quiz",
      q: "You change the colour of a button and want to see it immediately without losing the app's current state. What do you press?",
      opts: ["Shift+R", "R", "q", "Ctrl+C"],
      correct: 1,
      explain: "R is hot reload — it keeps state. Shift+R (hot restart) resets to a fresh state.",
    },
    done: ["You hot-reloaded a UI change and saw it apply in seconds.", "flutter analyze is clean on your scratch app."],
    refs: [],
  }),
]));

REGISTER(C.module("m1", "♢", "Dart from a Backend's Eyes", "the language, in build order", [
  C.step("m1s1", "Null safety", {
    learn: [
      C.h("The one big culture shift"),
      C.p("In Dart, null is a type-level fact. A variable is either <code>String</code> (never null, compiler-guaranteed) or <code>String?</code> (can be null). The compiler refuses to let you use a nullable value without handling the null — Kotlin/TypeScript energy, enforced harder."),
      C.b("<code>??</code> — 'use the left, or the right if null' (your COALESCE)."),
      C.b("<code>?.</code> — 'call, but only if not null' (safe navigation)."),
      C.b("<code>!</code> — 'I swear this isn't null'. Use sparingly; every ! is a potential crash."),
      C.b("Type promotion — after a null check the compiler narrows the type for you. No casts."),
    ],
    do: [
      C.p("Open your scratch app's main.dart and write these four constructs in a scratch function, hot-reloading each time to see them compile:"),
      C.code("String name = 'Nabin';          // never null, guaranteed\nString? nickname;                  // may be null\n\nvoid greet(String? who) {\n  final display = who ?? 'friend';  // ?? = default when null\n  print('Hi, \$display!');\n\n  if (who != null) {\n    print(who.toUpperCase());       // who PROMOTED to String here\n  }\n}\n\nint? parse(String s) => int.tryParse(s);\n// caller must handle the null:\nfinal n = parse('12') ?? 0;", "dart"),
      C.p("Now make it fail: use <code>who.toUpperCase()</code> without the null check and read the compiler error. Internalize that error message — you'll see it constantly."),
      C.p("Find three nullable fields in the real engine (they're there — <code>dealer</code>, <code>turn</code>) and trace how every read is guarded."),
    ],
    explain: [
      C.p("The promotion rule is the subtle one. After <code>if (who != null)</code>, the compiler treats <code>who</code> as non-null INSIDE that block — no reassignment between check and use, or promotion is cancelled. If you reassign <code>who</code> in a loop, promotion dies and you're back to <code>who?</code>. This is why the engine keeps 'is this seat up?' as a nullable <code>int?</code> and guards it once — the guard IS the type check."),
      C.p("<code>!</code> is how you assert what you've already proven, but it bypasses the check entirely. Every <code>!</code> is a bet against a null that type promotion couldn't prove. In this codebase <code>!.</code> appears only where a value was set earlier in the same flow (e.g. after <code>phase = playing</code>). If a <code>!</code> ever crashes in production, that's the line you interrogate first."),
    ],
    alternatives: [
      { title: "Design out nulls entirely", text: "The strongest null-safety move is to never have nullable state: model 'no dealer yet' as a phase (lobby) instead of a nullable dealer field, or use sealed result types. The engine does exactly this — <code>dealer</code> is <code>int?</code> but most decisions hang off the enum phase." },
      { title: "Result/Either types", text: "For return values that can fail, return a sealed Ok/Err instead of a nullable or throwing — exhaustive handling by the compiler (module 1.4). This is your Rust Result, and it beats try/catch for expected failures." },
    ],
    improve: [
      { title: "Enable strict lints", text: "The repo's analysis_options.yaml already enables the extra set. Consider also `strict-casts` / `strict-inference` for even more compiler enforcement — a config-only upgrade." },
      { title: "Aim for zero `!`", text: "Every time you write `!`, ask whether a guard or a phase change could make it unnecessary. Zero-force-unwraps is a realistic, auditable goal for a small app." },
    ],
    activity: {
      type: "code",
      starter: "// Write a function that takes a String? and returns\n// its length, or 0 when it's null.\nint safeLength(String? s) {\n  // your code here\n  return 0;\n}",
      checks: [
        CHK.has("handles null", "\\?\\?|\\s==\\s*null|\\s!=\\s*null", "Use ?? or a null check to handle the null case."),
        CHK.has("returns length", "safeLength|\\\.length", "Reference the parameter's .length somewhere."),
        CHK.has("uses nullable param", "String\\?\\s+\\w+", "The parameter must be typed nullable."),
      ],
    },
    done: ["You can explain ??, ?., !, and type promotion without looking."],
    refs: ["frontend/lib/engine/card.dart"],
  }),
  C.step("m1s2", "Classes, const, immutability", {
    learn: [
      C.h("const is the secret weapon"),
      C.p("A const constructor means 'this object is immutable and compile-time'. Flutter can share it across the whole tree — one instance, never rebuilt. Models in this project are immutable value objects, exactly like an unmodifiable DTO."),
      C.b("<code>final</code> vs <code>const</code> — final = 'set once at runtime'; const = 'compile-time constant'. A const constructor needs only final fields."),
      C.b("Value equality — override <code>==</code> and <code>hashCode</code> together, or equality compares by pointer and your checks silently break. The #1 beginner bug in Dart."),
      C.b("<code>copyWith</code> — the immutable-update pattern: a method returning a copy with some fields changed."),
    ],
    do: [
      C.p("In your scratch app, model the card the way the real engine does — an immutable value object:"),
      C.code("class PlayingCard {\n  const PlayingCard(this.rank, this.suit);  // const ctor\n\n  final int rank;\n  final Suit suit;\n\n  @override\n  bool operator ==(Object other) =>\n      other is PlayingCard && other.rank == rank && other.suit == suit;\n\n  @override\n  int get hashCode => Object.hash(rank, suit);\n\n  @override\n  String toString() => id;\n}", "dart"),
      C.p("Write two test cases: two cards with the same rank+suit are <code>==</code>, two different ones are not. Run them."),
      C.p("Now delete the <code>==</code> override and watch the same test fail — you've just felt why value equality matters. Restore it."),
      C.p("Add a <code>copyWith</code> to a small model with two fields and use it to 'change' one field."),
    ],
    explain: [
      C.p("The const constructor's contract: every field is <code>final</code> and initialized from the constructor, and callers can write <code>const PlayingCard(14, Suit.spades)</code>. The compiler is then allowed to canonicalize — all identical const instances are literally the same object. That's why <code>==</code> and <code>hashCode</code> matter more here than in Go: two 'different' const cards that are equal should compare equal, and putting them in a Set/HashMap must not collide."),
      C.p("<code>hashCode</code> must stay consistent with <code>==</code>: equal objects MUST have equal hashes. <code>Object.hash(a, b)</code> gives you a stable combiner without writing your own — the engine uses exactly this."),
      C.p("<code>copyWith</code> is the immutable-update idiom: <code>player.copyWith(name: 'New')</code> returns a fresh PlayerInfo with one field changed, never mutating the original. The engine's <code>PlayerInfo.copyWith</code> (module 2) uses it to track a seat's connection/autoplay status as it flips."),
    ],
    alternatives: [
      { title: "Records instead of small classes", text: "Dart records give structural equality for free: `(int, String)` or `({int rank, Suit suit})` tuples compare by value, no == override. Perfect for one-off return values (like the engine's pair of counts) — use them before reaching for a class." },
      { title: "freezed", text: "The codegen package generates ==, hashCode, copyWith, and JSON for you. This repo hand-writes them to teach the mechanics; freezed is the 'better way' when models multiply and the boilerplate stops paying for itself." },
    ],
    improve: [
      { title: "Make models immutable by default", text: "Write every new model with final fields + const constructor + ==/hashCode up front. Retro-fitting equality is a mechanical bore and easy to miss." },
      { title: "Test equality", text: "One tiny test per model asserting ==/hashCode consistency (equal cards, same hash) pays for itself when a Set or Map starts misbehaving." },
    ],
    activity: {
      type: "both",
      quiz: {
        q: "A class with only final fields and a const constructor is best described as:",
        opts: ["A mutable state holder", "An immutable value object", "A singleton service", "A factory"],
        correct: 1,
        explain: "const + final = immutable value object, shared freely, safe to pass around.",
      },
      code: {
        starter: "// Declare an immutable Point class with a const constructor,\n// x and y final ints, and operator ==.\nclass Point {\n  // your code\n}",
        checks: [
          CHK.has("const constructor", "const\\s+\\w+\\s*\\(", "Add a const constructor: const Point(this.x, this.y);"),
          CHK.has("final fields", "final\\s+int\\s+\\w+", "x and y must be final."),
          CHK.has("operator ==", "operator\\s*==", "Override equality."),
          CHK.has("hashCode", "hashCode", "Override hashCode to match."),
        ],
      },
    },
    done: ["You can explain the difference between final and const, and why == needs hashCode."],
    refs: ["frontend/lib/engine/card.dart", "frontend/lib/engine/game.dart (PlayerInfo.copyWith)"],
  }),
  C.step("m1s3", "Enums + extensions", {
    learn: [
      C.h("Enums with superpowers"),
      C.p("Dart enums are real types with switch support. Extensions attach behavior to a type you don't own — like adding helper methods to a type without touching it. The suit enum is the perfect example: the enum is data, the extension is the behavior."),
    ],
    do: [
      C.p("Write the suit enum and its extension in your scratch app — note how <code>get</code> reads like a field but runs like a method:"),
      C.code("enum Suit { spades, hearts, diamonds, clubs }\n\nextension SuitInfo on Suit {\n  String get code => switch (this) {\n    Suit.spades => 'S', Suit.hearts => 'H',\n    Suit.diamonds => 'D', Suit.clubs => 'C',\n  };\n\n  String get symbol => switch (this) {\n    Suit.spades => '♠', Suit.hearts => '♥',\n    Suit.diamonds => '♦', Suit.clubs => '♣',\n  };\n\n  bool get isRed => this == Suit.hearts || this == Suit.diamonds;\n  bool get isTrump => this == trumpSuit;\n}\n\n// usage reads like a native member:\nSuit.spades.symbol;  // '♠'\nSuit.hearts.isRed;   // true", "dart"),
      C.p("Add a <code>label</code> getter that returns 'Spades', 'Hearts', etc., and use it in a Text widget."),
      C.p("Now add a convenience extension on <code>List&lt;PlayingCard&gt;</code> — the engine does exactly this: <code>hand.ofSuit(suit)</code>, <code>hand.lowest</code>."),
    ],
    explain: [
      C.p("The switch expression is worth a hard look: <code>switch (this) { Suit.spades => 'S', ... }</code> evaluates to a value, has no break statements, and — because Suit is an enum — the compiler checks exhaustiveness. Add a fifth suit and this won't compile until you handle it. That's a static guarantee your backend switch statements never gave you."),
      C.p("The <code>get</code> syntax is computed-property sugar: <code>Suit.spades.symbol</code> looks like a field, runs like a method, and is cached per-call (cheap here, so no concern). The whole codebase leans on gets — <code>isBot</code>, <code>stillNeeded</code>, <code>isWaitingForPlayers</code> — precisely because they make predicates read like properties."),
      C.p("Extensions are the key unlock: you cannot add a method to an enum you don't own, but an extension means you don't have to. The engine adds <code>ofSuit</code> and <code>lowest</code> to <code>List&lt;PlayingCard&gt;</code> without touching the standard library — the same move you'd make with a helper type in Go, minus the ceremony."),
    ],
    alternatives: [
      { title: "Extension methods on your own classes", text: "Extensions work on any type, including your own. The pattern 'data class + behavior extension' keeps models small — the trade is behavior lives in a second file. Fine for utilities; keep real methods on the class." },
      { title: "enums with fields", text: "Dart enums can carry fields: `enum S { a('A'); const S(this.c); final String c; }`. For constant metadata that never varies, that's cleaner than an extension's switch. The engine uses extensions instead so all Suit behavior stays in one place." },
    ],
    improve: [
      { title: "Document the wire contract on the enum", text: "Add a doc comment to `code` noting it must never change — it's the on-wire format the Go server parses. Contract-bound getters deserve their own docs." },
      { title: "Unit-test each extension", text: "A table-driven test over every suit's symbol/code/isRed is 10 lines and catches future edits to the mapping." },
    ],
    activity: {
      type: "both",
      quiz: {
        q: "You cannot modify a sealed/third-party enum's source. How do you add a `symbol` property to it in Dart?",
        opts: ["Subclass the enum", "An extension on the enum type", "A static helper class", "Mirrors/reflection"],
        correct: 1,
        explain: "Extensions add members to an existing type without modifying it — the idiomatic Dart answer.",
      },
      code: {
        starter: "// Define an enum Direction {north, south} and an extension\n// giving each a String get label.\nenum Direction { north, south }\n\nextension DirectionLabel on Direction {\n  // your code\n}",
        checks: [
          CHK.has("extension", "extension\\s+\\w+\\s+on\\s+Direction", "Declare: extension X on Direction { ... }"),
          CHK.has("get label", "get\\s+label", "Add a get label returning a String."),
          CHK.has("switch or map", "switch\\s*\\(|=>", "Return per-value strings (switch expression or map)."),
        ],
      },
    },
    done: ["You can add behavior to a type you don't own using an extension."],
    refs: ["frontend/lib/engine/card.dart"],
  }),
  C.step("m1s4", "Switch expressions & sealed classes", {
    learn: [
      C.h("Exhaustive pattern matching"),
      C.p("A sealed class is a base class whose subclasses are finite and known. Switch expressions over sealed types are exhaustive BY THE COMPILER — no default case, no missed subclass. This is the engine's event model and the most valuable type-safety feature here."),
    ],
    do: [
      C.p("Model the engine's events in miniature — a sealed base and three subclasses:"),
      C.code("sealed class GameEvent {}\n\nclass CardPlayed extends GameEvent { final int seat; CardPlayed(this.seat); }\nclass TrickWon    extends GameEvent { final int winner; TrickWon(this.winner); }\nclass GameOver    extends GameEvent { final int place;  GameOver(this.place); }\n\n// This compiles ONLY because every subclass is handled:\nString describe(GameEvent e) => switch (e) {\n  CardPlayed p => 'Card from seat \${p.seat}',\n  TrickWon t   => 'Seat \${t.winner} took the trick',\n  GameOver g   => 'Finished \${g.place}',\n};", "dart"),
      C.p("Now add a fourth subclass <code>HandOver</code> WITHOUT handling it in the switch. The analyzer (and compiler) refuse to build. That error is the feature — read it, then add the case."),
      C.p("Use pattern binding: switch on the value and extract fields directly (<code>CardPlayed p</code> gives you <code>p.seat</code>) — no manual casts."),
    ],
    explain: [
      C.p("The sealed keyword does two jobs. First, it restricts subclassing to the same library — nobody outside can add a subclass, so 'the set of events is exactly these'. Second, it tells the compiler the set is closed, which is what makes exhaustive switches possible. When you later add an event to the real engine (e.g. <code>PresenceChanged</code>), the compiler walks you to every switch that must learn about it — the UI, the sound controller, the uploader. That guided refactor is the payoff."),
      C.p("Pattern binding is the sugar on top: <code>CardPlayed p => p.seat</code> destructures the value directly in the case arm. The equivalent in Go is a type switch with a type assertion inside each case — Dart collapses it into one expression."),
    ],
    alternatives: [
      { title: "Abstract base + visitor", text: "The pre-sealed way to get exhaustive dispatch was the visitor pattern — a method per subclass. Sealed + switch makes the visitor obsolete; the compiler does the bookkeeping." },
      { title: "Discriminated union via records", text: "Dart's sealed classes ARE the idiomatic union type. If you only need a value (not a class hierarchy), a record with a tag field works but loses exhaustiveness — prefer sealed." },
    ],
    improve: [
      { title: "Never add a default case", text: "If a switch over a sealed type has a `default`, you've given up the guarantee. Let the compiler force you to name every case — that's the point." },
      { title: "Extend, don't patch", text: "When a new server event arrives (e.g. a 'presence' change), add a new subclass and let the compile errors show you every consumer. The type system is the checklist." },
    ],
    activity: {
      type: "both",
      quiz: {
        q: "A sealed class forces what at compile time?",
        opts: ["A default case", "Every subclass handled in a switch", "A singleton", "Null checks"],
        correct: 1,
        explain: "Sealed hierarchies make switches exhaustive — the compiler refuses to compile if you miss a subclass.",
      },
      code: {
        starter: "// Declare a sealed class Result with two subclasses\n// Ok(value) and Err(message), then a function that\n// switches on it exhaustively.\nsealed class Result {}\nclass Ok<T> extends Result { final T value; Ok(this.value); }\nclass Err extends Result { final String message; Err(this.message); }\n\nString report(Result r) => switch (r) {\n  // your code\n};",
        checks: [
          CHK.has("sealed", "sealed\\s+class", "The base must be sealed."),
          CHK.has("switch expression", "switch\\s*\\(\\s*r\\s*\\)", "A switch expression on the Result."),
          CHK.has("handles Ok", "Ok\\s*<|Ok\\s+\\w+|Ok\\(", "Handle the Ok case."),
          CHK.has("handles Err", "Err", "Handle the Err case."),
        ],
      },
    },
    done: ["You can explain why the engine models events as a sealed class."],
    refs: ["frontend/lib/engine/game.dart (sealed class GameEvent)"],
  }),
  C.step("m1s5", "Collections", {
    learn: [
      C.h("Everything you already know, but ergonomic"),
      C.p("Dart collections read like Java streams but are built in. The engine's card logic is a tour: where/map/reduce for legality, spread for dealing, collection-if/for for building lists inline, cascade <code>..</code> for sort-a-copy."),
    ],
    do: [
      C.p("Write a chain that mirrors what legalMoves does — filter, map, reduce over a card list:"),
      C.code("final hand = <PlayingCard>[ ... ];\n\n// where = filter (SQL WHERE)\nfinal spades = hand.where((c) => c.suit == Suit.spades);\n\n// map = transform\nfinal ids = hand.map((c) => c.id);\n\n// reduce = fold to one value\nfinal bestRank = hand.map((c) => c.rank).reduce((a, b) => a > b ? a : b);\n\n// spread ... = splice\nfinal deck = [...spades, ...hearts, ...diamonds, ...clubs];\n\n// collection-if / collection-for inline:\nfinal highOnly = [\n  for (final c in hand)\n    if (c.rank > 10) c,\n];\n\n// cascade .. = operate on a COPY and return it\nfinal sorted = [...hand]..sort((a, b) => a.rank.compareTo(b.rank));", "dart"),
      C.p("Build a deck with a nested collection-for (the real fullDeck does this — suits outer, ranks inner)."),
      C.p("Add <code>ofSuit</code> and <code>lowest</code> as an extension on <code>List&lt;PlayingCard&gt;</code> and use them in a one-liner."),
    ],
    explain: [
      C.p("The cascade is the syntax to notice: <code>[...hand]..sort(...)</code> spreads a COPY then sorts the copy and yields it — the spread plus cascade gives you immutable update in one line. In Go you'd write <code>copy</code> then <code>sort.Slice</code> then return; here it's an expression."),
      C.p("Chains like <code>trick.where(...).map(...).reduce(...)</code> are eager — each step materializes a new list. For 4-card tricks that's irrelevant; for a million records you'd switch to lazy <code>Iterable</code> chains or <code>sync*</code>. Know the cost model: fine here, look elsewhere when hot."),
      C.p("Collection-<code>for</code>/<code>if</code> read as a mini-DSL for building lists — the deck, the hand fan, and the sidebar all use them. They're compile-time sugar for a for-loop with adds."),
    ],
    alternatives: [
      { title: "Sort with a comparator helper", text: "You can sort by a sort key: `..sortBy((c) => c.rank)` if you add a small extension, or write the comparator once and reuse it. The engine inlines comparators because there are only two orderings (suit+rank)." },
      { title: "Records for pair results", text: "Where a function returns two values (like 'higher or all in-suit'), a record `(List<PlayingCard>, bool)` avoids a tiny class." },
    ],
    improve: [
      { title: "Name your predicates", text: "`hand.where((c) => c.isTrump)` is readable; anything longer deserves a named getter or local function. The real codebase pushes conditions into named helpers (`isMaster`, `wouldWin`)." },
      { title: "Prefer immutable list ops", text: "Use spread-copy + cascade over mutating a shared list. When the engine hands a seat its hand, it copies — never expose the internal list." },
    ],
    activity: {
      type: "code",
      starter: "// Given a list of ints, return only the even ones, doubled,\n// sorted descending. Use where/map/sort.\nList<int> doubleEvensDesc(List<int> nums) {\n  // your code\n  return [];\n}",
      checks: [
        CHK.has("filters", "\\.where\\(", "Filter with .where() for even numbers."),
        CHK.has("maps", "\\.map\\(", "Transform with .map()."),
        CHK.has("sorts", "\\.sort|sort\\(", "Sort the result."),
      ],
    },
    done: ["You can read a where/map/reduce chain fluently."],
    refs: ["frontend/lib/engine/rules.dart"],
  }),
  C.step("m1s6", "Async: Future, Stream, Timer", {
    learn: [
      C.h("The concurrency model"),
      C.p("Dart is single-threaded with an event loop — like Node, not Go. Future = one-shot async; Stream = push-based sequence; Timer = delayed work. Your backend reflexes translate cleanly: await = await, Stream = an event channel."),
      C.b("<code>StreamController.broadcast()</code> — multi-listener event bus; how the session's events reach every widget."),
      C.b("<code>unawaited()</code> — deliberate fire-and-forget that silences the 'dropped future' lint."),
      C.b("Every <code>listen()</code> returns a StreamSubscription you MUST cancel in <code>dispose()</code>, or the widget leaks."),
    ],
    do: [
      C.p("Write a fetch-then-render pair to internalize the async flow:"),
      C.code("Future<String> fetchName() async {\n  await Future.delayed(Duration(milliseconds: 300));\n  return 'Nabin';\n}\n\nFuture<void> main() async {\n  final name = await fetchName();       // your normal await\n  print(name);\n}\n\n// fire-and-forget, linter-approved:\nunawaited(sendAnalytics());", "dart"),
      C.p("Build a mini event bus and subscribe twice — prove broadcast() reaches every listener:"),
      C.code("final events = StreamController<GameEvent>.broadcast();\nevents.add(CardPlayed(2));               // publish\nevents.stream.listen((e) => print('A: \$e'));\nevents.stream.listen((e) => print('B: \$e'));", "dart"),
      C.p("Write a widget-free timer demo: a Timer that fires once after 2s and a periodic Timer. Cancel the periodic one after 3 fires."),
    ],
    explain: [
      C.p("The engine emits GameEvents into an internal list; LocalSession drains it and fans out to a broadcast StreamController. Widgets subscribe in <code>initState</code>, react (play a sound, animate), and MUST unsubscribe in <code>dispose</code>. Skipping the cancel means the subscription — and the widget — stays alive forever, still receiving events for a table that's gone. It's a classic handle leak, exactly the kind you hunt in Go with pprof."),
      C.p("<code>unawaited()</code> exists because Dart's linter flags any Future you ignore — 'dropped_futures' — on the sound principle that ignoring an async failure hides bugs. The app legitimately wants to fire-and-forget game uploads (a dead network must never stall the table), so it wraps the call in <code>unawaited</code> to say 'this is intentional'. That's the linter conversation you'll have a lot."),
      C.p("Timer is your scheduler: bot think delays, trick linger, turn clocks, reconnect backoff are all Timers owned by a session that cancels them on dispose. One timer at a time per session — the pattern in LocalSession._scheduleNextAutoAction."),
    ],
    alternatives: [
      { title: "await for over a stream", text: "`await for (final e in events) { ... }` consumes a stream with a loop instead of listen + cancel — the async generator style. Great inside a service's run loop; heavier for one-shot widgets, which prefer listen." },
      { title: "FutureBuilder", text: "Widgets that await one Future can use FutureBuilder to rebuild when it completes. The app reads identity synchronously up front instead, so it never needs it — but it's the standard tool when you can't hoist the await." },
    ],
    improve: [
      { title: "Centralize your timers", text: "Every delay in the game lives in one TablePacing constants class (module 4), so pacing is a config change, not archaeology. Do the same for any timing you add." },
      { title: "Watch for await-in-build", text: "Never await in build(). Hoist async work to main() or initState and expose plain values — the app opens IdentityStore in main() for exactly this reason." },
    ],
    activity: {
      type: "both",
      quiz: {
        q: "A widget subscribes to a session's event stream in initState. Where must it cancel the subscription?",
        opts: ["In the constructor", "In dispose()", "Never — GC handles it", "In build()"],
        correct: 1,
        explain: "dispose() is where every subscription, timer, and controller must be released. Skipping it leaks the widget.",
      },
      code: {
        starter: "// Subscribe to the given Stream<int>, collecting values\n// into a List<int> until it closes, then return the list.\nFuture<List<int>> collect(Stream<int> source) async {\n  final out = <int>[];\n  // your code\n  return out;\n}",
        checks: [
          CHK.has("listen", "\\.listen|await for", "Subscribe with .listen or `await for`."),
          CHK.has("appends", "out\\.add|out\\.addAll", "Append each value to the list."),
          CHK.has("returns", "return\\s+out", "Return the collected list."),
        ],
      },
    },
    done: ["You can explain the lifecycle: subscribe → react → cancel in dispose."],
    refs: ["frontend/lib/ui/screens/table_screen.dart (the events subscription)"],
  }),
]));

REGISTER(C.module("m2", "♠", "The Game Engine", "pure Dart, zero Flutter — your phase", [
  C.step("m2s1", "Cards, suits, the deck", {
    learn: [
      C.h("The data layer"),
      C.p("This is your natural habitat: plain domain logic with no framework. The rule for this whole module: <code>engine/</code> must never import Flutter — it has to be usable by a headless test, a UI, and (later) a Go port."),
    ],
    do: [
      C.p("In the scratch app, create a file <code>lib/engine/card.dart</code> and start the hierarchy bottom-up: the suit enum + extension first, then the card class."),
      C.p("Add the constants — trump suit, min/max rank — and the rank label function:"),
      C.code("const Suit trumpSuit = Suit.spades;  // Call Break: spades are permanent trump\nconst int minRank = 2;\nconst int maxRank = 14;              // ace is high\n\nString rankLabel(int value) => switch (value) {\n  14 => 'A', 13 => 'K', 12 => 'Q', 11 => 'J', _ => '\$value',\n};", "dart"),
      C.p("Add the PlayingCard class with the wire id getter — this id is the on-wire format, so keep it stable forever:"),
      C.code("class PlayingCard {\n  const PlayingCard(this.rank, this.suit);\n  final int rank;\n  final Suit suit;\n  bool get isTrump => suit == trumpSuit;\n  String get label => rankLabel(rank);\n  String get id => '\$label\${suit.code}';   // 'AS', '10H' — the wire format\n}", "dart"),
      C.p("Add <code>fullDeck()</code> and <code>dealHands(Random)</code> using nested collection-for and shuffle. Test with a seed and assert you get 4 hands × 13 unique cards."),
      C.p("Add <code>sortForDisplay</code> (trumps first, then suits, high-to-low) and the list extension (<code>ofSuit</code>, <code>lowest</code>, <code>highest</code>)."),
    ],
    explain: [
      C.p("The wire id — <code>'AS'</code>, <code>'10H'</code> — is the project's interop contract. It's compact enough for a socket frame, readable in logs, and parseable by both Dart and Go. The counterpart <code>PlayingCard.fromId</code> (parse the trailing suit char, then the rank) is the other half. Once the Go server depends on this format, changing it is a two-codebase breaking change — so it's documented on the getter and frozen."),
      C.p("The rank representation is deliberate too: 2..14 so the ace is HIGH by simple integer comparison. If you modeled ranks as 1..13 with ace low, every comparison and the trick winner would need a special case. Encoding the game's convention into the representation removes an entire bug class."),
      C.p("<code>dealHands</code> takes a <code>Random</code> instead of calling <code>Random()</code> internally. That single parameter is what makes tests reproducible — <code>Random(42)</code> always deals the same hands, so a failing test reproduces forever. You know this pattern as dependency injection for determinism; it's the same instinct you'd bring to a flaky integration test."),
    ],
    alternatives: [
      { title: "One class, many enums", text: "Suit could be strings ('S') or ints (0-3). Enums win on exhaustiveness and switch support; the extension layer keeps the mapping tidy. Strings would couple the UI to wire-format magic values." },
      { title: "Rank as enum", text: "Ranks could be an enum (two..ace). The int 2..14 with a label function is lighter and keeps arithmetic (comparison, sorting) trivial. Enums buy exhaustiveness; ranks have no operations that need it." },
    ],
    improve: [
      { title: "Freeze the wire format with a test", text: "Add a test asserting the exact ids for known cards ('AS' == ace of spades). When the Go port breaks the contract, this test — on the Dart side — is the first to complain." },
      { title: "Round-trip fromId/id", text: "A property test that every card survives id→fromId→id unchanged catches encoding typos before they reach the network." },
    ],
    activity: {
      type: "code",
      starter: "// Define Suit, the trumpSuit constant, and a PlayingCard\n// class with rank, suit, isTrump and an id getter.\nenum Suit { spades, hearts, diamonds, clubs }\nconst Suit trumpSuit = Suit.spades;\n\nclass PlayingCard {\n  // your code\n}",
      checks: [
        CHK.has("const constructor", "const\\s+PlayingCard", "PlayingCard needs a const constructor."),
        CHK.has("final fields", "final\\s+int\\s+rank", "rank is a final int."),
        CHK.has("final suit", "final\\s+Suit\\s+suit", "suit is a final Suit."),
        CHK.has("isTrump", "isTrump", "Add the isTrump getter."),
      ],
    },
    done: ["You can deal a shuffled 4×13 deck deterministically given a seed."],
    refs: ["frontend/lib/engine/card.dart"],
  }),
  C.step("m2s2", "Rules: legality, winner, scoring", {
    learn: [
      C.h("The heart of Call Break"),
      C.p("Three pure functions decide the whole game. Get these exactly right — they are the contract between your client, your bots, and your server. The Go backend ports them verbatim later."),
    ],
    do: [
      C.p("Create <code>lib/engine/rules.dart</code>. Write <code>trickWinner</code> first (simplest): highest trump, else highest card of the led suit."),
      C.p("Write <code>scoreHand</code>: make the bid → bid + 0.1 per overtrick; fall short → the whole bid as a negative."),
      C.p("Write <code>legalMoves</code> in order — the four cases, each returning a fresh list:"),
      C.code("List<PlayingCard> legalMoves(List<PlayingCard> hand, List<TrickPlay> trick) {\n  if (trick.isEmpty) return [...hand];            // leading is free\n\n  final led = trick.first.card.suit;\n  final inSuit = hand.ofSuit(led);\n\n  if (inSuit.isNotEmpty) {\n    // Must follow suit, AND must beat the best of the suit\n    // already down if you can (the 'heading' rule).\n    final bestLed = trick\n        .where((p) => p.card.suit == led)\n        .map((p) => p.card.rank)\n        .reduce((a, b) => a > b ? a : b);\n    final higher = inSuit.where((c) => c.rank > bestLed).toList();\n    return higher.isNotEmpty ? higher : inSuit;\n  }\n\n  // Void in the led suit -> must trump, and overtrump if forced.\n  final trumps = hand.ofSuit(trumpSuit);\n  if (trumps.isEmpty) return [...hand];           // no trumps: anything goes\n  final trumpsPlayed = trick.where((p) => p.card.isTrump).toList();\n  if (trumpsPlayed.isEmpty) return trumps;\n  final bestTrump = trumpsPlayed.map((p) => p.card.rank).reduce((a, b) => a > b ? a : b);\n  final higher = trumps.where((c) => c.rank > bestTrump).toList();\n  return higher.isNotEmpty ? higher : [...hand];\n}", "dart"),
      C.p("Test each of the four cases by hand — a void hand that must trump, a hand that must overtrump, a forced-follow, a free lead."),
    ],
    explain: [
      C.p("legalMoves encodes Call Break's nastiest rule — 'heading': not only must you follow suit, you must beat the best card of that suit already on the table IF you can. That's why the follow-suit branch computes <code>bestLed</code> and prefers <code>higher</code>: the rule punishes a player who has a winning card and ducks with a loser. Miss this and your game is secretly a different (much duller) card game."),
      C.p("The trump branch mirrors it: void in the led suit means you MUST trump if you have trumps, and if the trick is already trumped you must OVERTRUMP when able. The <code>trumpsPlayed.isEmpty</code> check is the case where no trump has been played yet — then any trump wins the trick. Both branches collapse to the same shape: 'have a winning play? it's mandatory; otherwise everything is legal'."),
      C.p("The defensive copy (<code>[...hand]</code>, <code>.toList()</code>) matters more than it looks: the caller gets a list it can mutate without corrupting the hand the engine still owns. The Go port uses <code>append([]Card(nil), hand...)</code> for the same reason."),
      C.p("scoreHand's asymmetry is the whole strategic game: +0.1 for an overtrick versus losing the full bid for an under. The bots (module 4) and the bid estimator are built around exactly this skew."),
    ],
    alternatives: [
      { title: "Return a Move validity enum", text: "legalMoves could return a list of (card, reason) pairs, letting the UI grey out illegal cards with a tooltip. Slightly more machinery; the current contract (list of legal cards) is all the app consumes." },
      { title: "Merge winner+scoring into the game class", text: "These three functions could be methods on CallBreakGame. They're free functions because they have no state — pure, testable, portable to Go verbatim. That's the argument for keeping them separate." },
    ],
    improve: [
      { title: "Property-test legality", text: "For every possible trick/board, isLegalPlay must accept exactly legalMoves' output. A fuzz-style loop (random hands, random tricks) will find a rules bug no hand-written test will." },
      { title: "Document the 'heading' rule", text: "It's the rule outsiders get wrong. The doc comment in rules.dart explains it in three lines — keep that comment alive when you port to Go." },
    ],
    activity: {
      type: "both",
      quiz: {
        q: "Seat bids 4 and wins 5 tricks. Their hand score is:",
        opts: ["4.0", "5.0", "4.1", "-4.0"],
        correct: 2,
        explain: "Bid made: bid + overtricks × 0.1 = 4 + 1×0.1 = 4.1.",
      },
      code: {
        starter: "// Write legalMoves' simplest case: if the trick is empty,\n// every card is legal. Then a trickWinner that returns the\n// seat of the highest card of the led suit (no trumps yet).\nList<PlayingCard> legalMoves(List<PlayingCard> hand, List<TrickPlay> trick) {\n  // your code\n  return hand;\n}",
        checks: [
          CHK.has("empty trick check", "trick\\.isEmpty", "Return the whole hand when the trick is empty."),
          CHK.has("spread/copy", "\\.\\.\\.hand|toList|List\\.of", "Return a copy, not the mutable hand."),
        ],
      },
    },
    done: ["You can compute legal moves and a trick winner by hand for any board."],
    refs: ["frontend/lib/engine/rules.dart"],
  }),
  C.step("m2s3", "Bid estimate: the shared heuristic", {
    learn: [
      C.h("How to guess your tricks"),
      C.p("estimateTricks scores a hand's expected trick count deterministically. It feeds the bots' bids AND the human's bid suggestion — one heuristic, three consumers. No randomness, no ML: a card-counting formula you can port to Go for free."),
    ],
    do: [
      C.p("Write the trump half of the heuristic first: top trumps (A/K/Q/J) are near-certain, but each needs spare trumps behind it to survive."),
      C.code("var tricks = 0.0;\nif (hasTrump(14)) tricks += 1.0;\nif (hasTrump(13)) tricks += trumpCount >= 2 ? 0.9 : 0.5;\nif (hasTrump(12)) tricks += trumpCount >= 3 ? 0.7 : 0.3;\nif (hasTrump(11)) tricks += trumpCount >= 4 ? 0.45 : 0.15;\ntricks += max(0, trumpCount - 4) * 0.5;   // spare length wins by exhaustion", "dart"),
      C.p("Write the side-suit half: masters win unless a short suit gives you ruffing value, and you can only ruff as often as you hold spare trumps."),
      C.p("Add the clamping wrapper — <code>suggestBid(hand)</code> rounds the estimate and clamps to 1..13."),
      C.p("Sanity-test it: a hand with four top trumps should suggest a high bid; a hand with no trumps and low cards should suggest ~1."),
    ],
    explain: [
      C.p("The scaling on the trump honours is the insight: a bare king is worth half a trick because the ace will eat it, but a king with a spare trump behind it is worth 0.9 — the spare wins by exhaustion or takes an opponent's ace. Same card, two values, depending on <code>trumpCount</code>. That single idea is why the estimate feels human instead of robotic."),
      C.p("Ruff value is capped by spare trumps — <code>min(ruffValue, max(0, trumpCount - 1))</code>. You can't ruff more tricks than you have trumps to spare; double-counting is the classic bug in hand-scoring heuristics. The cap is what keeps the total under 13."),
      C.p("Determinism is the feature: identical hands → identical bids, every time. That makes the bots (and your tests) predictable, and it's the reason the exact same function can run on the server."),
    ],
    alternatives: [
      { title: "Expected-value simulation", text: "A Monte Carlo estimate — deal random hidden cards, play out the hand, average — would beat the formula on strength. It's hundreds of evaluations per turn and you'd burn the phone's battery. The formula is the right cost/quality trade for bots." },
      { title: "Tune per difficulty", text: "The formula is fixed; difficulty comes from jitter + blunder around it (module 4.2). You could instead tweak the weights per difficulty — more invasive, same effect." },
    ],
    improve: [
      { title: "Add a test against a known-good table", text: "Hand-pick 5 hands, assert their estimates match the reference. When you port to Go, the SAME table is your cross-language contract test." },
      { title: "Calibrate against play", text: "Log estimate vs actual tricks won, and adjust weights with real data. The app doesn't gather telemetry today — that's a future improvement, not a bug." },
    ],
    activity: {
      type: "quiz",
      q: "What does estimateTricks share between the bots and the human player?",
      opts: ["Nothing", "The bid suggestion and the bots' bid choice", "The card-playing strategy", "The trick winner"],
      correct: 1,
      explain: "Both the human's suggested bid and each bot's bid come from the same deterministic estimate.",
    },
    done: ["You can explain why a bare king is worth less than a king with a spare behind it."],
    refs: ["frontend/lib/engine/rules.dart", "frontend/lib/bots/bot.dart"],
  }),
  C.step("m2s4", "The state machine", {
    learn: [
      C.h("One class, all the state"),
      C.p("CallBreakGame is a pure state machine: an enum phase, methods that mutate and return bool, and a redacted view on the way out. No timers, no I/O — a host drives it with Timers and reads views. That split is the whole architecture in one sentence."),
    ],
    do: [
      C.p("Create <code>lib/engine/game.dart</code>. Declare the phase and player-kind enums, then the game's public state — seats, dealer, hand index, per-seat bids/tricks/totals, the current trick, completed tricks, hands:"),
      C.code("enum GamePhase { lobby, bidding, playing, handOver, gameOver }\nenum PlayerKind { human, bot }\n\nclass CallBreakGame {\n  final List<PlayerInfo> players;   // 4 seats\n  GamePhase phase = GamePhase.lobby;\n  int? dealer;                      // null until the first hand\n  int handIndex = 0;\n  final int totalHands;             // 3 (quickplay) or 5 (full)\n\n  final List<int?> bids = List.filled(4, null);\n  final List<int> tricksWon = List.filled(4, 0);\n  final List<double> totals = List.filled(4, 0);\n  final List<CompletedTrick> completedTricks = [];\n  List<List<PlayingCard>> hands = [];\n  List<TrickPlay> trick = [];\n\n  bool start() {\n    if (phase != GamePhase.lobby) return false;\n    phase = GamePhase.bidding;\n    _startHand(0);\n    return true;\n  }\n}", "dart"),
      C.p("Implement <code>start()</code> → <code>_startHand</code>: deal, set dealer, pick the first bidder, set the turn, phase = bidding."),
      C.p("Implement <code>nextHand()</code> and <code>_finish()</code> — the end-of-game path that computes rankings."),
      C.p("Write a mini test: start(), assert phase == bidding, dealer non-null, each hand has 13 cards."),
    ],
    explain: [
      C.p("Every mutator returns bool — 'did this actually change anything?'. The host checks it before republishing; invalid calls (wrong phase, wrong seat, illegal card) are simply <code>false</code> and harmless. That contract is what makes the engine impossible to drive into an invalid state, and it's the same 'return the result of your state change' instinct you'd use for a compare-and-swap."),
      C.p("<code>int? dealer</code> is null until the first deal — a deliberately nullable piece of state whose reads are all guarded by 'have we started?' checks. Notice most decisions hang off <code>phase</code> rather than <code>dealer</code>; that's the design-out-nulls habit from module 1 paying off."),
      C.p("The <code>PlayerInfo</code> list is the roster — name, kind, difficulty, connected, autoplay. It's serialized into every view, so it carries presence state (is this human still here?) as well as identity. That's how the UI renders 'Playing for you' on an autoplayed seat."),
    ],
    alternatives: [
      { title: "Finite-state-machine library", text: "Packages (state_machine, xstate-style) formalize transitions as a table. For 5 phases and a handful of guards, a plain enum + guards is clearer and dependency-free. Reach for a library when the guard logic multiplies." },
      { title: "Put the engine in an isolate", text: "A background isolate could run the engine so a UI stall can't delay the game. Overkill here (single-threaded Flutter handles this fine); the Go server's actor is the real concurrency home." },
    ],
    improve: [
      { title: "Enforce transitions in tests", text: "A test that every phase only advances through legal transitions (lobby→bidding→playing→handOver→lobby...) is your state machine's spec. Cheap to write, catches regressions forever." },
      { title: "Log phase changes for the admin UI", text: "The server's admin dashboard shows every live table's phase — emit a PresenceChanged-style event whenever it flips so debugging a stuck table is a one-glance operation." },
    ],
    activity: {
      type: "code",
      starter: "// Declare a GamePhase enum with the 5 phases and a\n// CallBreakGame field set, plus a guard: start() only\n// proceeds from lobby.\nenum GamePhase { lobby, bidding, playing, handOver, gameOver }\n\nclass MiniGame {\n  GamePhase phase = GamePhase.lobby;\n\n  bool start() {\n    // your code\n    return false;\n  }\n}",
      checks: [
        CHK.has("enum", "enum\\s+GamePhase", "Declare the phase enum."),
        CHK.has("guard", "lobby", "Only proceed when phase == lobby."),
        CHK.has("returns bool", "return\\s+true", "Return true on success."),
        CHK.has("changes phase", "phase\\s*=|phase\\s*:", "Advance the phase somewhere."),
      ],
    },
    done: ["You can name the five phases and explain why mutators return bool."],
    refs: ["frontend/lib/engine/game.dart (CallBreakGame)"],
  }),
  C.step("m2s5", "Play, tricks, and hand scoring", {
    learn: [
      C.h("The turn loop"),
      C.p("Bidding: seats in turn choose a bid, clamped and recorded. Playing: the current turn seat plays a legal card; at 4 cards the winner takes the trick and leads next; after 13 tricks the hand is scored and the next deals."),
    ],
    do: [
      C.p("Implement <code>placeBid(seat, bid)</code> — guard phase, guard turn, clamp, record, emit, advance phase when all four have bid:"),
      C.code("bool placeBid(int seat, int bid) {\n  if (phase != GamePhase.bidding) return false;\n  if (!isSeatTurn(seat)) return false;\n  bids[seat] = clampBid(bid);\n  _emit(BidPlaced(seat, clampBid(bid)));\n  if (bids.every((b) => b != null)) phase = GamePhase.playing;\n  return true;\n}", "dart"),
      C.p("Implement <code>playCard(seat, card)</code> — the guarded heart of the game: validate, remove from hand, add to trick, and at 4 cards resolve the winner, record, clear, and hand off the lead:"),
      C.code("bool playCard(int seat, PlayingCard card) {\n  if (phase != GamePhase.playing) return false;\n  if (turn != seat) return false;\n  if (!isLegalPlay(hands[seat], trick, card)) return false;\n\n  hands[seat].remove(card);\n  trick.add(TrickPlay(seat, card));\n  _emit(CardPlayed(TrickPlay(seat, card)));\n\n  if (trick.length == 4) {\n    final winner = trickWinner(trick);\n    tricksWon[winner]++;\n    completedTricks.add(CompletedTrick([...trick], winner));\n    _emit(TrickWon(winner));\n    trick.clear();\n    turn = winner;                       // winner leads next\n    if (hands[winner].isEmpty) _endHand();\n  } else {\n    turn = nextSeatAfter(seat);\n  }\n  return true;\n}", "dart"),
      C.p("Implement <code>_endHand</code> — score every seat with <code>scoreHand</code>, apply the deltas to totals, emit HandOver, phase = handOver (or gameOver if the last hand)."),
    ],
    explain: [
      C.p("Every guard is a line you can point at when a bug report says 'the game did something illegal': wrong phase → false, wrong seat → false, illegal card → false. There is no path from an invalid intent to a state change. This is the same discipline as validating every field of an incoming request before touching your database."),
      C.p("The trick-resolution order matters: compute the winner from the 4-card trick, count it, SNAPSHOT it into completedTricks (the UI renders the last won trick), emit the event for animation/sound, clear the working trick, then hand the lead to the winner. If <code>hands[winner].isEmpty</code> the hand is over — the final trick just ended it."),
      C.p("<code>_endHand</code> is where the event snapshot discipline from module 2.8 becomes real: the per-hand bids/tricks are about to be cleared for the next deal, so the HandOver event carries the deltas (per-seat score change) and the uploader (module 9) records them at that moment. Sequence is the contract."),
    ],
    alternatives: [
      { title: "Command objects instead of method calls", text: "Model moves as sealed command classes (PlayCard(seat, card), Bid(seat, n)) and give the engine a single apply(cmd). That's one switch instead of many methods — the pattern the Go room actor uses for its inbox messages. The Dart engine keeps methods because there are only four intents and the guards differ per move." },
      { title: "Auto-advance via the host", text: "The engine could own a Timer and advance itself. It deliberately doesn't — purity keeps it portable (Go server) and testable (no real time). The host (LocalSession/room) owns pacing." },
    ],
    improve: [
      { title: "Snapshots for the replays", text: "The server has RECORD_TRICKS for card-level replays. The engine's completedTricks already holds everything needed — a future 'watch a past game' feature needs only the export." },
      { title: "Undo for offline practice", text: "Because the engine is a pure state machine, an undo stack (clone state before each move) is straightforward for the solo-vs-bots mode. Guard it off in multiplayer." },
    ],
    activity: {
      type: "quiz",
      q: "After the 4th card lands in a trick, what happens in order?",
      opts: ["Turn passes to next seat", "Trick is scored, winner found, trick cleared, winner leads", "Hand ends immediately", "Nothing until someone acts"],
      correct: 1,
      explain: "4 cards → trickWinner → tricksWon++ → record → clear → winner leads (or hand ends if their hand is empty).",
    },
    done: ["You can trace one full trick from lead to winner in code."],
    refs: ["frontend/lib/engine/game.dart"],
  }),
  C.step("m2s6", "The redacted view", {
    learn: [
      C.h("What one seat may see"),
      C.p("This is the security boundary of the whole game. <code>viewFor(seat)</code> hands back only what that seat is entitled to: their own 13 cards in full, everyone else's as a COUNT. A test asserts no other seat's card ids appear anywhere in the view. When the Go server serializes over the socket, it calls the same idea."),
    ],
    do: [
      C.p("Define the GameView value object — everything a seat needs to render a table, and nothing it mustn't see:"),
      C.code("class GameView {\n  final GamePhase phase;\n  final int handIndex, handsPerGame, dealer, turn;\n  final List<PlayerInfo> players;\n  final int you;                    // this view's seat\n  final List<PlayingCard> hand;     // YOUR cards, full\n  final List<int> handSizes;        // everyone else: just a count\n  final List<int?> bids, tricksWon;\n  final List<double> totals;\n  final List<TrickPlay> trick;\n  final List<CompletedTrick> completedTricks;\n  final bool awaitingTrickClear;\n  final int? serverTimeMs;          // clock-skew anchor (module 4)\n}", "dart"),
      C.p("Implement <code>viewFor(seat)</code>: copy your own hand in full, everyone else as a length:"),
      C.code("GameView viewFor(int seat) {\n  return GameView(\n    phase: phase,\n    you: seat,\n    hand: [...hands[seat]],                              // full\n    handSizes: [for (var s = 0; s < 4; s++) s == seat ? 0 : hands[s].length],\n    // ...everything else is public: bids, scores, table cards\n  );\n}", "dart"),
      C.p("Write the golden invariant test: serialize the view, assert no card id belongs to a different seat. This test is non-negotiable — it's your anti-cheat guarantee."),
    ],
    explain: [
      C.p("<code>viewFor</code> is the ONLY way game state leaves the engine. There is no getter exposing raw hands, no toJson on the engine itself — the redaction is enforced structurally, not by convention. Any code that wants to show a player something must go through this door, so a leak has one place to happen and one test to catch it."),
      C.p("The copy semantics do double duty: <code>[...hands[seat]]</code> gives the player a list they can freely mutate (e.g. sorting for display) without corrupting the engine's hand. The engine and the view are decoupled by value."),
      C.p("<code>serverTimeMs</code> looks like a rounding error but it's the clock-skew fix (module 4.6): the server's deadline is on the server's clock, useless to compare against a phone's clock that's minutes off. The client uses serverTimeMs as 'now' to convert deadlines into durations. That's why the view carries a timestamp at all."),
    ],
    alternatives: [
      { title: "Serialization at the edge", text: "The engine could serialize to JSON directly and let the wire redact. The project keeps GameView as a typed object so the client gets compile-time safety, then serializes the view. Server does the same — ViewFor is both languages' boundary." },
      { title: "Per-field permissions", text: "A heavier scheme could annotate fields as private per seat. For a 2-4 seat game with one redaction rule (your cards vs everyone else's count), a hand-written view is clearer than a permission framework." },
    ],
    improve: [
      { title: "Snapshot for spectators", text: "A spectator mode is one more view flavor: everyone's handSizes, no hand. Because views are data, adding a flavor is adding a constructor — cheap future feature." },
      { title: "Audit via test doubles", text: "The wire-contract test on the server asserts no leaked ids across the socket. Mirror that test on the Dart side for the local engine — defense in depth." },
    ],
    activity: {
      type: "both",
      quiz: {
        q: "In a viewFor(2) result, how many cards does seat 3 appear to hold?",
        opts: ["All 13", "A count only (e.g. 13)", "None — hidden", "It varies by phase"],
        correct: 1,
        explain: "Other seats appear only as handSizes — a count, never card ids.",
      },
      code: {
        starter: "// Implement viewFor(seat): copy of the seat's own hand in\n// full, and a handSizes list of counts for the others.\nclass MiniGame {\n  final List<List<String>> hands = [\n    ['AS', '2H'], ['3S', '4D'], ['5C', '6S'], ['7H', '8D'],\n  ];\n\n  Map<String, Object> viewFor(int seat) {\n    // your code\n    return {};\n  }\n}",
        checks: [
          CHK.has("own hand full", "hands\\[seat\\]", "Read hands[seat] for your own cards."),
          CHK.has("counts others", "handSizes", "Build a handSizes field."),
          CHK.has("no full others", "\\.length", "Others appear as .length counts."),
        ],
      },
    },
    done: ["You can explain why the server serializes viewFor() output over the wire, not the raw game."],
    refs: ["frontend/lib/engine/game.dart (GameView, viewFor)"],
  }),
  C.step("m2s7", "Events: the sealed outbox", {
    learn: [
      C.h("Side effects without side effects"),
      C.p("The engine is pure: it doesn't play sounds, animate, or touch the network. It records what happened into an event list, and the HOST decides what to do — republish views, trigger timers, play a card-land thud. Your domain-event/outbox pattern in 30 lines."),
    ],
    do: [
      C.p("Declare the sealed event hierarchy — the compiler will force every consumer to handle each one:"),
      C.code("sealed class GameEvent {}\nclass HandStarted extends GameEvent { final int handIndex; HandStarted(this.handIndex); }\nclass BidPlaced extends GameEvent { final int seat, bid; BidPlaced(this.seat, this.bid); }\nclass CardPlayed extends GameEvent { final TrickPlay play; CardPlayed(this.play); }\nclass TrickWon extends GameEvent { final int winner; TrickWon(this.winner); }\nclass HandOver extends GameEvent {\n  final int handIndex;\n  final List<double> deltas;   // per-seat score change this hand\n  HandOver(this.handIndex, this.deltas);\n}\nclass GameOver extends GameEvent {\n  final List<SeatRanking> rankings;\n  GameOver(this.rankings);\n}", "dart"),
      C.p("Add the outbox to the engine — emit appends, takeEvents drains:"),
      C.code("final List<GameEvent> _events = [];\nvoid _emit(GameEvent e) => _events.add(e);\n\nList<GameEvent> takeEvents() {\n  final out = List.of(_events);\n  _events.clear();\n  return out;\n}", "dart"),
      C.p("Wire <code>_emit</code> into every mutator you wrote in step m2s5 (bid placed, card played, trick won, hand over, game over)."),
      C.p("Write a test: after a full hand, takeEvents() contains exactly the expected sequence — bids, cards, tricks, and a HandOver with the right deltas."),
    ],
    explain: [
      C.p("The outbox pattern you know from backend work — an aggregate records domain events and a consumer publishes them — is exactly this. The engine appends to a list instead of calling out; <code>takeEvents()</code> is the drain. Because emission and consumption are decoupled, the same events drive three different consumers: the UI (animate + sound), the uploader (record bids/tricks at HandOver), and the tests (assert the sequence)."),
      C.p("The sealed hierarchy is what makes the fan-out safe: every consumer's switch is exhaustive, so adding <code>PresenceChanged</code> or <code>AutoplayChanged</code> later is a guided walk through every listener, not a hunt."),
      C.p("Events are value objects carrying the minimum — a winner's seat, a hand's deltas — never whole views. If a consumer needs more context it reads the current view at the time of the event, which is exactly what the sound controller and animation layer do."),
    ],
    alternatives: [
      { title: "Streams inside the engine", text: "The engine could expose a Stream directly. It uses a list so the HOST controls delivery timing (drain between publishes) and tests can inspect deterministically. A broadcast stream would blur 'engine' and 'transport'." },
      { title: "Callback on every mutation", text: "emitEvent(onCardPlayed, onTrickWon, ...) — a dozen callbacks per move. The event list is one parameter and one drain; callbacks would couple the engine to every listener's signature." },
    ],
    improve: [
      { title: "Add an event for presence", text: "The real engine has PresenceChanged and AutoplayChanged for the network layers. Add your own when you hit module 7 — the sealed switch will show you every place to wire it." },
      { title: "Replay from events", text: "Because events are a total log of the game, you could re-derive state by replaying them. That's the seed of a future spectator/replay feature and it fell out of this design for free." },
    ],
    activity: {
      type: "quiz",
      q: "Why does the engine emit events into a list instead of calling UI code directly?",
      opts: ["It's slower but safer", "Keeps the engine pure and reusable — any host can consume the events", "The UI requires it", "Events need a network"],
      correct: 1,
      explain: "Purity + decoupling: the same events drive animation, sound, and the offline uploader.",
    },
    done: ["You can name every event type and what consumes it (UI + uploader)."],
    refs: ["frontend/lib/engine/game.dart (sealed class GameEvent)"],
  }),
  C.step("m2s8", "Test the engine first", {
    learn: [
      C.h("Contract tests before UI"),
      C.p("The engine test suite is the project's constitution. It runs headless — no device, no emulator, just <code>flutter test</code>. Dealing, bid legality, follow-suit, heading, trumping, scoring, redaction, full game flow — all locked here first."),
    ],
    do: [
      C.p("Create <code>test/engine_test.dart</code> and set up the seeded-game harness — Random(seed) so deals are reproducible forever:"),
      C.code("import 'package:flutter_test/flutter_test.dart';\nimport 'package:callbreak/engine/card.dart';\nimport 'package:callbreak/engine/game.dart';\nimport 'package:callbreak/engine/rules.dart';\n\ngroup('legal moves', () {\n  test('leading is free', () {\n    final hand = [const PlayingCard(2, Suit.spades)];\n    expect(legalMoves(hand, []), contains(const PlayingCard(2, Suit.spades)));\n  });\n\n  test('must follow suit', () {\n    final hand = [const PlayingCard(5, Suit.hearts), const PlayingCard(14, Suit.spades)];\n    final trick = [TrickPlay(1, const PlayingCard(3, Suit.hearts))];\n    final moves = legalMoves(hand, trick);\n    expect(moves, isNot(contains(const PlayingCard(14, Suit.spades))));\n    expect(moves, contains(const PlayingCard(5, Suit.hearts)));\n  });\n})", "dart"),
      C.p("Add the redaction invariant test — the security guarantee:"),
      C.code("test('redaction: no other seat\\'s cards leak', () {\n  final game = CallBreakGame(players: fourHumans, seed: 42);\n  game.start();\n  final view = game.viewFor(0);\n  for (var seat = 1; seat < 4; seat++) {\n    for (final c in game.handOf(seat)) {\n      expect(view.hand.any((mine) => mine.id == c.id), isFalse,\n          reason: 'leaked \${c.id}');\n    }\n  }\n});", "dart"),
      C.p("Add one end-to-end test: drive a full hand with legal moves only, assert totals, trick counts sum to 13, and a GameOver appears at the end."),
      C.p("Run <code>flutter test</code> and get it green before writing a single widget."),
    ],
    explain: [
      C.p("Why tests FIRST here and not in the UI phases? Because the engine is the contract both other languages and modes build on. If it's wrong, every bot, every socket frame, every scoreboard is wrong — and the bug is cheapest when it's one pure function deep. This is the same argument as contract-testing your API before building the client."),
      C.p("expect(actual, matcher) is the fluent assertion API: <code>contains</code>, <code>isNot</code>, <code>isTrue</code>, <code>throwsA</code>. The seeded Random is the reproducibility trick — a failing test reproduces forever, and a flaky suite is impossible by construction."),
      C.p("The cross-language rule: the Go engine's tests are ported case-for-case from this file. If the two suites ever disagree, the client and server disagree about the rules — the one bug class this project cannot afford. Your porting discipline (module 10.2) is what keeps that true."),
    ],
    alternatives: [
      { title: "Property-based testing", text: "test package's property/fuzz helpers can throw random legal boards at legalMoves. Powerful for rules that must never crash; keep the hand-written cases for the 'must follow suit' semantics property testing can't express." },
      { title: "Golden replay tests", text: "Serialize a seeded game's event log to a golden file and diff on every run. Catches subtle sequencing drift that individual assertions miss — a great addition once the engine stabilizes." },
    ],
    improve: [
      { title: "Cover the heading rule explicitly", text: "The 'must beat the best on the table' case is the easiest to regress — give it its own test with a hand that has both a losing and a winning follow." },
      { title: "Test against the Go port", text: "Once module 10 exists, a CI job runs both suites against the same fixture file. Two languages, one truth, zero drift." },
    ],
    activity: {
      type: "code",
      starter: "// Write one test group with two tests:\n// 1. a void hand must trump when it must\n// 2. dealer starts null then becomes non-null after start()\nimport 'package:flutter_test/flutter_test.dart';\n\nvoid main() {\n  group('my engine', () {\n    test('example', () {\n      expect(1 + 1, 2);\n    });\n  });\n}",
      checks: [
        CHK.has("group", "group\\s*\\(", "Wrap tests in a group."),
        CHK.has("two tests", "test\\s*\\(", "Write at least two test() cases."),
        CHK.count("expects", "expect\\s*\\(", 2, "Each test should assert with expect()."),
      ],
    },
    done: ["flutter test test/engine_test.dart is green.", "You can reproduce a deal by seeding."],
    refs: ["frontend/test/engine_test.dart", "frontend/test/deal_repro_test.dart"],
  }),
]));

REGISTER(C.module("m3", "♥", "Static UI", "theme, tokens, home screen, card art", [
  C.step("m3s1", "Widgets 101", {
    learn: [
      C.h("Everything is a widget"),
      C.p("A widget is a piece of UI — text, button, box, layout. They nest into a tree. StatelessWidget = pure; StatefulWidget = owns mutable state that triggers rebuilds. You describe WHAT, Flutter figures out HOW."),
      C.b("The BIG state (a whole game) is NOT held in widgets — it lives in a ChangeNotifier session (module 4). Widgets stay thin."),
      C.b("<code>build(context)</code> runs on every rebuild — keep it cheap and pure."),
      C.b("<code>super.key</code> — every widget takes a key; used later to track seat/table positions for animations."),
    ],
    do: [
      C.p("In the scratch app, replace the counter body with two widgets side by side — a pure Greeting and a stateful CounterButton — to feel the Stateless/Stateful split:"),
      C.code("class Greeting extends StatelessWidget {\n  const Greeting({super.key, required this.name});\n  final String name;\n  @override\n  Widget build(BuildContext context) {\n    return Text('Hi, \$name!', style: const TextStyle(fontSize: 20));\n  }\n}\n\nclass CounterButton extends StatefulWidget {\n  const CounterButton({super.key});\n  @override\n  State<CounterButton> createState() => _CounterButtonState();\n}\n\nclass _CounterButtonState extends State<CounterButton> {\n  int _n = 0;\n  @override\n  Widget build(BuildContext context) {\n    return ElevatedButton(\n      onPressed: () => setState(() => _n++),\n      child: Text('Pressed \$_n times'),\n    );\n  }\n}", "dart"),
      C.p("Add a third widget: a Greeting that takes a <code>bool</code> and swaps its text — then make it rebuild by passing a changing value down. Feel how rebuilding is declarative, not imperative."),
      C.p("Break the <code>const</code> keyword off a Text child and run flutter analyze — it suggests adding const back. That lint is teaching you the shared-instance optimization."),
    ],
    explain: [
      C.p("The Stateful/Stateless split maps to your instinct about ownership: Stateless widgets are pure functions of their inputs; Stateful widgets own a <code>State</code> object that outlives rebuilds and lives for the widget's lifetime. <code>setState</code> marks it dirty and schedules a rebuild — you never manually repaint."),
      C.p("The subtle point for a backend dev: <code>setState</code> is NOT the whole story. The engine's state lives in a session object that calls <code>notifyListeners()</code> (module 4) — widgets subscribe and rebuild without anyone calling setState. setState is for widget-local state; ChangeNotifier is for shared game state. Get that split right and the whole app stays readable."),
      C.p("The const lint is worth internalizing: a <code>const</code> widget subtree is built once and shared — the framework skips rebuilding it entirely. That's why you see const everywhere in idiomatic Flutter, and why the analyzer nags you to add it."),
    ],
    alternatives: [
      { title: "One StatefulWidget for the whole screen", text: "You could hold the session reference in the screen's State — and the real TableScreen does. The point is what you DON'T hold: the game itself." },
      { title: "Flutter Hooks", text: "The hooks package (React-style) shrinks StatefulWidget boilerplate. This project deliberately doesn't use it — plain State is enough at this scale — but it's the 'better way' when widget state multiplies." },
    ],
    improve: [
      { title: "Extract and test a leaf widget", text: "Any pure widget with a callback is instantly testable: pump it, tap, assert the callback fired. Write one such test now and you've learned the widget-testing pattern module 4 depends on." },
      { title: "Prefer const by reflex", text: "Make const the default you type, not the exception. `flutter analyze` will train you within a day." },
    ],
    activity: {
      type: "quiz",
      q: "What is the difference between StatelessWidget and StatefulWidget?",
      opts: ["Stateless is faster", "Stateful owns mutable state that triggers rebuilds; Stateless is pure", "Stateful needs a server", "No difference"],
      correct: 1,
      explain: "StatefulWidget holds a State object with setState; StatelessWidget is pure render.",
    },
    done: ["You can write both widget kinds from memory."],
    refs: ["frontend/lib/ui/screens/home_screen.dart", "frontend/lib/main.dart"],
  }),
  C.step("m3s2", "Theme: dark felt + gold", {
    learn: [
      C.h("ThemeData is your design system"),
      C.p("One ThemeData configures colors, fonts, and component styles app-wide. The app is a dark card table: near-black green background, gold accent, Material 3. Custom fonts are registered in pubspec.yaml and referenced by family."),
    ],
    do: [
      C.p("Rewrite the scratch app's MaterialApp with a dark, gold-seeded theme:"),
      C.code("MaterialApp(\n  title: 'Call Break',\n  debugShowCheckedModeBanner: false,\n  theme: ThemeData(\n    useMaterial3: true,\n    brightness: Brightness.dark,\n    scaffoldBackgroundColor: const Color(0xFF04140F),\n    fontFamily: 'PlusJakartaSans',\n    colorScheme: ColorScheme.fromSeed(\n      seedColor: AppColors.gold,\n      brightness: Brightness.dark,\n    ),\n  ),\n  home: const HomeScreen(),\n)", "dart"),
      C.p("Add a font: drop PlusJakartaSans ttf files into <code>assets/fonts/</code>, register them in pubspec.yaml, hot-reload, and watch the whole UI re-skin:"),
      C.code("flutter:\n  uses-material-design: true\n  fonts:\n    - family: PlusJakartaSans\n      fonts:\n        - asset: assets/fonts/PlusJakartaSans-Medium.ttf\n          weight: 500\n        - asset: assets/fonts/PlusJakartaSans-SemiBold.ttf\n          weight: 600\n        - asset: assets/fonts/PlusJakartaSans-Bold.ttf\n          weight: 700", "yaml"),
      C.p("Switch the seed color to red and watch every accent shift. That's ColorScheme.fromSeed working — one value drives the palette."),
    ],
    explain: [
      C.p("<code>ColorScheme.fromSeed(seedColor: AppColors.gold)</code> generates a full dark palette from one brand color — surfaces, accents, disabled states — with correct contrast ratios. Your design system becomes a parameter, not a theme file of 50 hand-tuned colors."),
      C.p("The 0xFF04140F is ARGB: FF opaque, then R G B — near-black green, the felt. Every color in the app flows from tokens like this (module 3.3) so the brand gold appears in exactly one place."),
      C.p("Fonts and assets share the pubspec's flutter section: register a family once, use it by name anywhere via <code>fontFamily</code> or <code>TextStyle(fontFamily: ...)</code>. Two families run this app — Cinzel for the wordmark, PlusJakartaSans for everything else."),
    ],
    alternatives: [
      { title: "ThemeExtension for brand tokens", text: "Flutter's ThemeExtension is the framework-native way to carry custom tokens (like goldBorder, felt colors) inside ThemeData instead of a hand-rolled tokens class. The app keeps its own AppColors — simpler to read — but ThemeExtension is the 'more Flutter' route." },
      { title: "Light theme + dark theme", text: "ThemeData supports darkTheme/lightTheme pairs and follows the OS. This app is a dark-only card table by design; shipping both is a copy-paste template away if you ever want it." },
    ],
    improve: [
      { title: "Theme your components", text: "Define CardTheme, ElevatedButtonTheme, etc., so every card and button shares the felt-and-gold style without repeating decorations. The table widgets will thank you in module 4." },
      { title: "Dark-mode contrast audit", text: "The textMuted/textFaint ladder exists because low-contrast text is the #1 dark-UI complaint. Test your palette against WCAG AA once and you're done." },
    ],
    activity: {
      type: "quiz",
      q: "Where do custom fonts get registered in a Flutter project?",
      opts: ["In Dart code with TextStyle", "In pubspec.yaml under flutter: fonts:", "In AndroidManifest.xml", "In a CSS file"],
      correct: 1,
      explain: "Fonts and assets are declared in pubspec.yaml, then used by family name in Dart.",
    },
    done: ["You can add a font family and apply it app-wide."],
    refs: ["frontend/pubspec.yaml", "frontend/lib/main.dart"],
  }),
  C.step("m3s3", "Design tokens", {
    learn: [
      C.h("One place for every colour"),
      C.p("The rule: the UI never hard-codes a colour — everything comes from AppColors. This is your CSS custom properties file, enforced by convention. Change the gold once, the whole app changes."),
    ],
    do: [
      C.p("Create <code>lib/design/tokens.dart</code> and capture the brand palette — note the ARGB hex and the translucent panel values:"),
      C.code("class AppColors {\n  const AppColors._();   // never instantiate\n\n  // Brand golds\n  static const gold = Color(0xFFF5D78A);\n  static const goldMid = Color(0xFFF0C75E);\n  static const goldDeep = Color(0xFFC9922A);\n  static const goldBorder = Color(0xFFE8B84A);\n\n  // Text on dark felt\n  static const textPrimary = Color(0xFFF2F7F4);\n  static const textMuted = Color(0xFFA8C9B8);\n  static const textFaint = Color(0xFF7FA896);\n\n  // Card faces\n  static const cardFace = Color(0xFFF7F3EB);\n  static const cardInk = Color(0xFF1A1A1A);\n  static const cardRed = Color(0xFFC0392B);\n\n  // Surfaces + status\n  static const success = Color(0xFF3DDC84);\n  static const danger = Color(0xFFE85A4F);\n  static const panel = Color(0x8C04120D);   // translucent — felt shows through\n  static const hairline = Color(0x1FF2F7F4);\n}", "dart"),
      C.p("Create <code>lib/design/metrics.dart</code> for the size vocabulary — card widths, seat sizes, paddings. The visual system lives in two files."),
      C.p("Refactor the theme you wrote in m3s2 to reference these tokens instead of literals."),
      C.p("Change <code>gold</code> to a slightly different hex and watch the accent update app-wide. That's the payoff."),
    ],
    explain: [
      C.p("The tokens class is pure data — const statics, a private constructor so nobody instantiates it. The <code>0x8C</code> prefix in <code>panel = Color(0x8C04120D)</code> is alpha: 55% opacity, so the felt gradient shows through the panel. The first two hex digits are always alpha in Flutter's ARGB, which trips up everyone who assumes RGB."),
      C.p("Tokens + metrics as two files means layout math is consistent: the card-size formula in the table derives from metrics, not magic numbers scattered in widgets. When the design says 'cards are 5% wider', you change one file."),
      C.p("Why const? Every <code>static const</code> is a compile-time value the framework can share — the same single-instance optimization from module 1.2, applied to your whole color system."),
    ],
    alternatives: [
      { title: "ThemeExtension again", text: "Registering AppColors as a ThemeExtension makes tokens context-aware (colors can differ by theme). The app's dark-only design doesn't need it; the option is there when themes multiply." },
      { title: "A yaml/design export", text: "Keep the palette in a yaml the design team edits, generated into Dart. Over-engineered for one developer; the tokens class is the version-control-friendliest home." },
    ],
    improve: [
      { title: "Export tokens for the Go admin UI", text: "The server's admin dashboard (backend/internal/httpapi/admin_ui.html) duplicates the palette as CSS. A shared tokens file both sides import would kill the drift — a nice cross-repo refactor." },
      { title: "Add semantic aliases", text: "Prefer names like cardFace over raw hex everywhere. The alias IS the documentation; a magic 0xFFC0392B in a widget tells you nothing." },
    ],
    activity: {
      type: "code",
      starter: "// Create a Tokens class with three const colors:\n// felt (near-black green), gold, and text.\nclass Tokens {\n  // your code\n}",
      checks: [
        CHK.has("const class", "const\\s+Tokens\\._\\(\\)|class\\s+Tokens", "A class (optionally with private ctor) for tokens."),
        CHK.count("static const", "static\\s+const", 3, "At least three static const colours."),
        CHK.has("Color(", "Color\\(0x", "Use Color(0x...) literals."),
      ],
    },
    done: ["You can change the brand gold in exactly one file and see it ripple everywhere."],
    refs: ["frontend/lib/design/tokens.dart", "frontend/lib/design/metrics.dart"],
  }),
  C.step("m3s4", "Layout: Row, Column, Stack", {
    learn: [
      C.h("Your HTML/CSS, as code"),
      C.p("Row = horizontal, Column = vertical, Stack = absolutely-positioned layers. The felt table is one big Stack: felt → seats → trick → hand → overlays. This is flexbox, minus the agony."),
    ],
    do: [
      C.p("Build a Column + Row + Expanded demo in the scratch app — a top bar, a flexible middle, a bottom row — to feel the flex model:"),
      C.code("Column(\n  mainAxisAlignment: MainAxisAlignment.spaceBetween,\n  children: [\n    Row(children: [Icon(Icons.star), Text('Top bar')]),\n    Expanded(child: Center(child: Text('middle'))),\n    Row(\n      mainAxisAlignment: MainAxisAlignment.spaceEvenly,\n      children: const [Text('L'), Text('R')],\n    ),\n  ],\n)", "dart"),
      C.p("Overlay a Stack with Positioned children — a background layer and two pinned corners. This is the exact skeleton of the table screen:"),
      C.code("Stack(\n  children: [\n    Positioned.fill(child: felt),      // back layer\n    Positioned(left: 40, top: 80, child: seatAvatar),\n    Align(alignment: Alignment.bottomCenter, child: yourHand),\n  ],\n)", "dart"),
      C.p("Introduce a bug on purpose: drop the Expanded and let the middle overflow. Read the yellow-and-black overflow stripe in the emulator — then restore it."),
    ],
    explain: [
      C.p("Expanded is the layout workhorse: it tells the framework 'this child takes all the leftover space in its axis'. Without it, a Column child with unbounded content overflows — the yellow-black striped error you just triggered. That error is 80% of beginner layout bugs: missing Expanded, or a child that can't shrink to fit."),
      C.p("MainAxisAlignment is justify-content; CrossAxisAlignment is align-items. <code>spaceBetween</code> spreads children to the edges; <code>spaceEvenly</code> adds equal gaps around them. The seat ring around the felt uses Positioned for exact pins — left/top offsets relative to the Stack."),
      C.p("A Stack paints children in order: the first is at the back, the last on top. The table relies on this ordering — felt, then seats, then the trick cluster, then your hand, then overlays — so z-order is just array order, no z-index to manage."),
    ],
    alternatives: [
      { title: "Wrap / Flexible", text: "Flexible is Expanded without the 'must fill' — children can keep intrinsic size. Wrap handles overflow to the next line (handy for bid button rows on narrow phones)." },
      { title: "CustomPainter for the table", text: "The felt's radial gradient and the cards' rounded corners are drawn by widgets here. A CustomPainter could render the whole table in one paint pass — faster, but far less inspectable in the widget inspector." },
    ],
    improve: [
      { title: "LayoutBuilder for adaptive sizes", text: "Seat/card sizes that scale with screen size come from LayoutBuilder or MediaQuery. The real app routes them through MetricsScope — copy that habit so a foldable doesn't break the table." },
      { title: "Constrain with LayoutBuilder", text: "Use constraints, not fixed sizes, for the table: constraining children inside the felt's Stack keeps everything within the screen." },
    ],
    activity: {
      type: "quiz",
      q: "You need the dealer's avatar pinned to the top-left of the felt, with the trick floating above everything. Which widget layout pairs fit?",
      opts: ["Two Columns", "A Stack with Positioned children", "A ListView", "A Row with spacing"],
      correct: 1,
      explain: "Stack + Positioned gives free-floating layers — exactly the table surface.",
    },
    done: ["You can compose Row/Column/Stack to reproduce a simple UI from a screenshot."],
    refs: ["frontend/lib/ui/widgets/felt_table.dart", "frontend/lib/ui/screens/table_screen.dart"],
  }),
  C.step("m3s5", "The home screen", {
    learn: [
      C.h("Four ways to start a table"),
      C.p("The home screen presents four game modes as data (PlayModeSpec) rendered by one card widget. Adding a mode = adding one const spec, not copy-pasting a widget."),
    ],
    do: [
      C.p("Declare the GameMode enum with its label extension — the single source of truth for mode naming:"),
      C.code("enum GameMode { bots, private, online, lan }\n\nextension GameModeInfo on GameMode {\n  String get label => switch (this) {\n    GameMode.bots => 'vs Bots',\n    GameMode.private => 'Private',\n    GameMode.online => 'vs Humans',\n    GameMode.lan => 'LAN',\n  };\n}", "dart"),
      C.p("Define the four specs as a const list — colors, badges, subtitles, all data:"),
      C.code("const playModes = <PlayModeSpec>[\n  PlayModeSpec(mode: GameMode.bots,    accent: Color(0xFF5B9BD5), letter: 'v',\n    badge: 'Solo',    subtitle: 'Practice against AI opponents'),\n  PlayModeSpec(mode: GameMode.online,  accent: AppColors.danger, letter: 'v',\n    badge: 'Online',  subtitle: 'Quickplay or a full match'),\n  PlayModeSpec(mode: GameMode.private, accent: AppColors.goldBorder, letter: 'P',\n    badge: 'Friends', subtitle: 'Invite-only room with a code'),\n  PlayModeSpec(mode: GameMode.lan,     accent: AppColors.success, letter: 'L',\n    badge: 'Local',   subtitle: 'Play on the same Wi-Fi network'),\n];", "dart"),
      C.p("Build the home screen: a ListView/Column over <code>playModes</code>, each card a tappable widget that currently just debugPrints its mode. Wire the real navigation in module 4."),
      C.p("Add a fifth spec (a 'Tournament' placeholder) and watch it render without touching the widget. That's the data-driven payoff."),
    ],
    explain: [
      C.p("The pattern is 'describe the UI as data, render it with one widget'. PlayModeSpec carries everything the card needs to look right; the card widget is a dumb renderer of a spec plus a callback. This is the widget version of a table-driven test — and it means the four modes can never drift out of sync."),
      C.p("GameMode's label extension (module 1.3) is where the naming lives, so the enum and its human text can't disagree. When a later phase passes the chosen mode to a session factory, the same enum drives both the button and the session."),
      C.p("The const list means the whole menu is compile-time data — the framework builds it once and shares it, and there is no startup work to populate the menu."),
    ],
    alternatives: [
      { title: "A switch over modes in the card", text: "The card could switch on GameMode and hand-write each design. That duplicates the data-driven structure and couples the widget to every mode — the exact drift the spec list removes." },
      { title: "Navigation with go_router", text: "The app uses plain Navigator.push. go_router is the 'better way' when deep links and web routes matter; for 5 screens, Navigator is fewer moving parts." },
    ],
    improve: [
      { title: "Route via a session factory", text: "The home screen's tap handler will become 'build a session from mode + settings' (module 4). Extract that factory early — it's where the network modules plug in." },
      { title: "Persist last-used mode", text: "Remembering 'you always play vs Bots' and preselecting it is a small settings-driven touch that feels polished." },
    ],
    activity: {
      type: "quiz",
      q: "Why model the four modes as a const list of PlayModeSpec instead of four hard-coded card widgets?",
      opts: ["It's faster at runtime", "One render loop + one spec per mode; adding a mode = one entry", "Widgets can't repeat", "The compiler requires it"],
      correct: 1,
      explain: "Data-driven UI: one card widget, driven by specs. Less code, one source of truth.",
    },
    done: ["You can render N cards from a const list without writing N widget copies."],
    refs: ["frontend/lib/ui/screens/home_screen.dart", "frontend/lib/net/session.dart (GameMode)"],
  }),
  C.step("m3s6", "Rendering a playing card", {
    learn: [
      C.h("A card is just a widget"),
      C.p("No images needed — a card is a rounded Container with pip text and suit symbols. Trump gets a gold edge. Hearts/diamonds are red."),
    ],
    do: [
      C.p("Write <code>PlayingCardView</code> — a const StatelessWidget sized by a <code>Size</code>, with a <code>faceUp</code> flag for the deal animation later:"),
      C.code("class PlayingCardView extends StatelessWidget {\n  const PlayingCardView(this.card, {super.key, this.size, this.faceUp = true});\n  final PlayingCard card;\n  final Size? size;\n  final bool faceUp;\n\n  @override\n  Widget build(BuildContext context) {\n    final w = size?.width ?? 56.0;\n    final h = size?.height ?? 82.0;\n    final ink = card.suit.isRed ? AppColors.cardRed : AppColors.cardInk;\n\n    return Container(\n      width: w, height: h,\n      decoration: BoxDecoration(\n        color: AppColors.cardFace,\n        borderRadius: BorderRadius.circular(6),\n        border: Border.all(\n          color: card.isTrump ? AppColors.trumpEdge : AppColors.cardEdge,\n          width: 1.5,\n        ),\n        boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4, offset: Offset(0, 2))],\n      ),\n      child: Padding(\n        padding: const EdgeInsets.all(4),\n        child: Column(\n          crossAxisAlignment: CrossAxisAlignment.start,\n          children: [\n            Text(card.label, style: TextStyle(color: ink, fontWeight: FontWeight.bold, fontSize: w * 0.26)),\n            Text(card.suit.symbol, style: TextStyle(color: ink, fontSize: w * 0.26)),\n          ],\n        ),\n      ),\n    );\n  }\n}", "dart"),
      C.p("Render a row of all 52 cards to eyeball them, then scale the same widget to half size and check it still reads. The relative font sizing (<code>w * 0.26</code>) is what keeps a card 'card-shaped' at any scale."),
      C.p("Render the card back for faceUp=false — a solid Container with the gold edge. You'll use it in the dealing animation."),
    ],
    explain: [
      C.p("Container + BoxDecoration is the styled-box primitive: color, radius, border, shadow in one object. The gold <code>trumpEdge</code> versus the faint <code>cardEdge</code> is the trump visual cue — a spade card visibly stands out, which is the Call Break brand move."),
      C.p("Sizing by proportion (<code>w * 0.26</code>) instead of fixed px is why the same widget works in the hand fan, the trick cluster, and a mini preview. Font scales with the box; the card never looks text-heavy or empty."),
      C.p("The <code>faceUp</code> flag is forward-looking: during the deal animation the framework shows card backs briefly, then flips them. Because it's just a bool on a pure widget, the animation layer toggles it with no card logic involved."),
    ],
    alternatives: [
      { title: "Pre-rendered card images", text: "An asset sprite-sheet of 52 faces is faster to paint and can look fancier (textured linen). The widget approach needs no assets and rescales freely — the right call for a first build; assets are the polish pass." },
      { title: "CustomPainter for pips", text: "Painting the four-corner pip layout with CustomPainter gives pixel-perfect pips but adds a painter class. For a 2-3 text-pip card, text widgets are plenty." },
    ],
    improve: [
      { title: "Ranks and pip layout", text: "Real decks show corner rank + two pips and a center suit emblem. Add pips scaled by rank count for a more convincing face — a pure-widget upgrade." },
      { title: "Lift animation hook", text: "Expose an offset/lift parameter so the hand fan can raise the selected card on drag. The real table does this with a Transform; adding the parameter now saves a refactor later." },
    ],
    activity: {
      type: "code",
      starter: "// Write a CardView widget: a rounded Container with the\n// card label and suit symbol, sized by a size param.\nclass CardView extends StatelessWidget {\n  const CardView(this.label, this.symbol, {super.key, this.size});\n  final String label, symbol;\n  final Size? size;\n\n  @override\n  Widget build(BuildContext context) {\n    // your code\n    return Container();\n  }\n}",
      checks: [
        CHK.has("Container", "Container\\s*\\(", "Use a Container as the card body."),
        CHK.has("decoration", "BoxDecoration|decoration:", "Add a BoxDecoration (color/radius/border)."),
        CHK.has("shows label", "label|card\\.label", "Render the label text."),
        CHK.has("shows symbol", "symbol|suit\\.symbol", "Render the suit symbol."),
      ],
    },
    done: ["A card with a gold edge renders for trump, red pips for red suits."],
    refs: ["frontend/lib/ui/widgets/playing_card_view.dart"],
  }),
  C.step("m3s7", "The hand fan", {
    learn: [
      C.h("Your 13 cards, playable"),
      C.p("The hand sits across the bottom, fanned and slightly overlapped, trumps first (sortForDisplay). A scrollable row of small cards does it; tapping one plays it (module 4)."),
    ],
    do: [
      C.p("Build the HandFan — a horizontal scrollable row with a per-card overlap using Transform.translate:"),
      C.code("class HandFan extends StatelessWidget {\n  const HandFan(this.hand, {super.key});\n  final List<PlayingCard> hand;\n\n  @override\n  Widget build(BuildContext context) {\n    return SingleChildScrollView(\n      scrollDirection: Axis.horizontal,\n      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),\n      child: Row(\n        children: [\n          for (var i = 0; i < hand.length; i++)\n            Transform.translate(\n              offset: Offset(-i * 4.0, 0),   // overlap into a fan\n              child: PlayingCardView(hand[i], size: const Size(52, 76)),\n            ),\n        ],\n      ),\n    );\n  }\n}", "dart"),
      C.p("Feed it a sorted hand (sortForDisplay) and verify trumps lead, then within each suit high-to-low."),
      C.p("Try the overlap parameter: -4 fully shows the corner pip, -20 hides most cards (a real deck fan), -60 breaks it (cards fully behind). Find the sweet spot."),
      C.p("Wire onTap on a card to debugPrint its id — the play gesture is one tap away from real."),
    ],
    explain: [
      C.p("SingleChildScrollView + horizontal Row is the lightweight scrollable row — for 13 cards it's simpler than a ListView's lazy recycling and costs nothing. Transform.translate shifts each card in paint space by <code>-i * 4</code>, so card N overlaps card N+1's left edge by 4px — the fan effect is pure arithmetic."),
      C.p("Why trumps first? sortForDisplay orders spades, then hearts/diamonds/clubs, each high-to-low — the same order a human sorts a Call Break hand. The engine's sort is display-coupled by design, which is why it lives in card.dart (the display and the wire format are both 'engine')."),
      C.p("The onTap hook is where the UI's only card-level intent meets the session: tapping will call <code>session.play(card)</code> (module 4). The fan stays a dumb renderer; legality is the session's job."),
    ],
    alternatives: [
      { title: "A true arc fan", text: "The real app fans cards in an arc (each card rotated slightly). That's a Transform.rotate per card with the pivot at the bottom center — prettier, and a pure-widget change. The overlap row is the version that ships first." },
      { title: "ReorderableListView", text: "If you wanted drag-to-reorder the hand, ReorderableListView handles it. The game sorts automatically, so there's nothing to reorder." },
    ],
    improve: [
      { title: "Drag-to-play", text: "The app's settings offer drag-to-play: drag a card up and release to throw it. A GestureDetector per card with an onHorizontalDragUpdate lift is the deluxe version of the tap." },
      { title: "Auto-throw last card", text: "A nice touch: when only one card (or one suit) remains, auto-play it on tap. The settings expose exactly these toggles — you can ship them in module 4." },
    ],
    activity: {
      type: "quiz",
      q: "Which widget makes a row of cards horizontally scrollable when there isn't room?",
      opts: ["Column", "SingleChildScrollView(scrollDirection: Axis.horizontal)", "Stack", "Positioned"],
      correct: 1,
      explain: "SingleChildScrollView with a horizontal Row is the lightweight scrollable row.",
    },
    done: ["A 13-card hand renders as a fanned, scrollable strip, trumps first."],
    refs: ["frontend/lib/ui/widgets/hand_fan.dart", "frontend/lib/engine/card.dart (sortForDisplay)"],
  }),
]));
