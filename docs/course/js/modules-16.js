/* Build Call Break — module 16: The Complete Inventory.
   The completeness guarantee: every file in the repo, what it does, and which
   step builds it. Nothing is left to discover. */

REGISTER(C.module("m16", "🗺", "The Complete Inventory", "every file mapped — nothing left to discover", [
  C.step("m16s1", "Every frontend file, mapped", {
    learn: [
      C.h("The completeness guarantee"),
      C.p("This step is the contract that 'everything is covered'. It lists every file under frontend/lib, what it does, and which step in this course builds it. If a file appears here with a step number, you have already (or will, in order) built it. Nothing in the app is built by magic or left to discovery."),
      C.h("The engine & state core (module 2, 5)"),
      C.code("lib/engine/card.dart              m2s1  cards, suits, deck, wire ids\nlib/engine/rules.dart              m2s2  legality, winner, scoring, bid estimate\nlib/engine/game.dart               m2s4  state machine, viewFor, GameEvent outbox\nlib/state/identity_store.dart      m5s1  device id + token on shared_preferences\nlib/state/app_settings.dart        m5s2  settings notifier + SettingsScope\nlib/state/active_game_binding.dart m7s4  'I'm mid-game, seat N, resume token'", "text"),
      C.h("The sessions (module 4, 7, 8, 9)"),
      C.code("lib/net/session.dart              m4s1  the GameSession contract\nlib/net/local_session.dart        m4s3  solo-vs-bots host + pacing\nlib/net/remote_session.dart       m7s3  server-backed session + reconnect\nlib/net/lan_host_session.dart     m8s1  on-device host server\nlib/net/lan_discovery.dart        m8s2  UDP beacon + listener\nlib/net/api_client.dart           m6s3  REST client + error mapping\nlib/net/api_models.dart           m6s2  REST DTOs, lenient fromJson\nlib/net/game_uploader.dart        m9s2  offline queue + idempotent upload", "text"),
      C.h("The UI (module 3, 4)"),
      C.code("lib/main.dart                     m3s2  wiring + theme\nlib/ui/screens/home_screen.dart   m3s5  the four play modes\nlib/ui/screens/table_screen.dart  m4s4  the felt table shell\nlib/ui/screens/settings_sheet.dart m5s4 settings + server URL\nlib/ui/screens/profile_screen.dart m5s4 profile + history/stats\nlib/ui/widgets/playing_card_view.dart m3s6  one card\nlib/ui/widgets/hand_fan.dart      m3s7  your 13 cards\nlib/ui/widgets/felt_table.dart    m4s4  the felt surface\nlib/ui/widgets/bid_panel.dart     m4s5  bidding overlay\nlib/ui/widgets/scoreboard.dart    m4s5  between-hands scores\nlib/ui/widgets/seat_view.dart     m4s4  seat placement (bottom/left/top/right)\nlib/ui/widgets/turn_clock.dart    m4s6  the seat countdown\nlib/design/tokens.dart            m3s3  colours\nlib/design/metrics.dart           m3s3  sizes\nlib/audio/audio_controller.dart   m5s3  music + SFX\nlib/bots/bot.dart                 m4s2  the opponent", "text"),
      C.h("The remaining widgets (next step)"),
      C.code("lib/ui/screens/lan_screen.dart        m16s2\nlib/ui/widgets/backdrop.dart          m16s2\nlib/ui/widgets/deadline_bar.dart      m16s2\nlib/ui/widgets/fields.dart            m16s2\nlib/ui/widgets/pulse_ripple.dart      m16s2\nlib/ui/widgets/quick_settings_panel.dart m16s2\nlib/ui/widgets/round_history.dart     m16s2\nlib/ui/widgets/winner_screen.dart     m16s2", "text"),
      C.callout("The rule that makes this list honest: every file above is either built in a numbered step OR covered explicitly in m16s2. Cross them off as you go — the list IS your 'am I done?' answer.", "ok"),
    ],
    do: [
      C.p("Open frontend/lib and tick every file against this map. Any file you find here that you haven't met yet tells you exactly which step to revisit."),
      C.p("Write the map onto one page and pin it next to your editor. When you're 90% through, the list is what shows you the last 10%."),
    ],
    explain: [
      C.p("Completeness here means every file has a named home: a step number (built in place) or an explicit covering step. There is no file in frontend/lib that 'just appears'. The map is also the reverse lookup — stuck on a file? The step number is the tutorial for it."),
      C.p("Notice the files you haven't built are exactly the ones m16s2 covers — the map has no orphans by construction."),
    ],
    alternatives: [
      { title: "A generated tree in the README", text: "A plain README tree is static and rots as the code moves. The course map doubles as a checklist with progress tracking — the better home for a build you're actively following." },
      { title: "One file per step only", text: "You could split every file into its own course step (about 38 UI steps). That over-sequences; several files are small pieces of one screen. The map groups them by the step that builds them." },
    ],
    improve: [
      { title: "Keep the map in sync", text: "When you add a file in a future version, add it to the map in the same commit — the inventory is only a guarantee while it's current." },
      { title: "Turn the map into a CI check", text: "A tiny script comparing the lib tree against this list fails when a file appears without a mapping. That's the map as an executable contract." },
    ],
    activity: {
      type: "quiz",
      q: "Where is the GameSession contract — the abstraction every game mode plugs into — built?",
      opts: ["m2s4 (the engine)", "m4s1 (the table module)", "m7s3 (the sockets)", "m16s2"],
      correct: 1,
      explain: "m4s1 builds net/session.dart, the interface LocalSession/RemoteSession/LanHostSession all implement.",
    },
    done: ["You can point at any file in frontend/lib and name the step that builds it."],
    refs: ["frontend/lib/"],
  }),
  C.step("m16s2", "The widgets you haven't met yet", {
    learn: [
      C.h("Eight widgets + one screen — the last 10%"),
      C.p("These polish the table from 'functional' to 'designed'. Each is a small, pure piece you can build in an hour; together they are what makes the app feel finished rather than prototyped. Build them in this order — each one plugs into the table screen you already have."),
      C.h("The environment"),
      C.code("backdrop.dart\n  The three-stop gradient + soft radial bloom behind every screen.\n  Portrait: top-to-bottom. Landscape: left-to-right.\n  Build after m3s3 (tokens) — it's the app's shared background.\n\nfields.dart\n  The standard text input chrome: filled panel, hairline border that\n  warms to gold on focus, gold cursor. Used by every TextField\n  (join code, player name, server URL).", "text"),
      C.h("The table furniture"),
      C.code("seat_view.dart\n  Maps an absolute seat index to a screen slot (bottom/left/top/right)\n  so whoever is viewing always sees THEMSELVES at the bottom:\n    SeatSlot.values[(seat - viewer + 4) % 4]\n  Renders the avatar, name, connected/autoplay badge — the per-seat HUD.\n\npulse_ripple.dart\n  Radar-style expanding rings around a glyph: 'searching / connecting /\n  waiting' — clearer than a spinner, gentler than a loading bar.\n\ndeadline_bar.dart\n  A draining bar on a PANEL the player is asked to answer (bid, scoreboard):\n  'this decision gets made with or without you'. Unlike TurnClock it shows\n  for the whole wait, not just the last seconds. Reports the clock only —\n  the table's host is the one that acts on it.", "text"),
      C.h("The overlays"),
      C.code("round_history.dart\n  Full round-by-round scorecard opened from the HUD. Non-blocking:\n  tapping the scrim dismisses it and play continues.\n\nwinner_screen.dart\n  The final podium: standings, full history, next move (another game\n  or the lobby). Full-screen when GameView.phase reaches gameOver.\n\nquick_settings_panel.dart\n  The compact settings sheet FROM the table — gameplay behaviour and\n  sound without leaving the game. Reads/writes AppSettings live.\n\nlan_screen.dart\n  The LAN discovery + join flow screen (module 8): finds the host\n  via the UDP beacon, joins over WebSocket.", "text"),
    ],
    do: [
      C.p("Build backdrop.dart first — every other screen sits on it. It takes a colors list, a glow, and a child; you'll wrap each screen in it."),
      C.p("Build fields.dart second — every TextField (join code, name, server URL) uses it. Two functions: an InputDecoration builder and the field widget."),
      C.p("Build seat_view.dart — the seat→slot map is one line (the modulo trick above); then the avatar/badge HUD around it. Feed it PlayerInfo and connected/autoplay state from the view."),
      C.p("Build pulse_ripple.dart — an AnimatedBuilder with a repeating controller scaling + fading rings around a centered child. Use it on the connecting screen and LAN discovery."),
      C.p("Build deadline_bar.dart — a timer-driven fraction from the session's turnDeadline/handAdvanceDeadline (module 4.6's clock-skew conversion), painting a draining bar under the panel."),
      C.p("Build round_history.dart — render view.completedTricks per hand into a scrollable scorecard; non-modal (dismiss without blocking the game)."),
      C.p("Build winner_screen.dart — full-screen on phase == gameOver: podium from the view's rankings, the round history inside, and a restart/exit button calling session.restart()."),
      C.p("Build quick_settings_panel.dart — a showModalBottomSheet that reads/writes AppSettings through SettingsScope (module 5.2), no game-state access."),
      C.p("Build lan_screen.dart — the m8 flow wired to a UI: pulse_ripple while discovering, host table list from the UDP beacon, join via RemoteSession to the host address."),
      C.p("Wire each into the table screen where the module's improve-section says; hot-reload each one and look at the felt before moving on."),
    ],
    explain: [
      C.p("These nine files share one property: they are all pure presenters. None of them owns game state — they read from the view and the session, exactly like everything in module 4. The two that LOOK stateful (pulse_ripple's animation, deadline_bar's countdown) own only their own visual clock, which is what keeps them trivial to slot in."),
      C.p("seat_view's modulo trick is the one genuinely clever line: <code>(seat - viewer + 4) % 4</code> rotates the seat ring so whoever is looking always sees themselves bottom-center. One expression, and the table is correct for every player in every mode — no per-player layout logic anywhere."),
      C.p("deadline_bar vs turn_clock is a product decision worth copying: the turn clock on a SEAT counts the last seconds of YOUR turn; the deadline bar on a PANEL communicates 'this decision gets made with or without you' for the whole wait. Same clock source, two different messages, because the two situations need different empathy."),
      C.p("winner_screen is deliberately full-screen rather than the table's card-sized overlay: a podium needs width. The table screen switches on phase == gameOver and swaps the whole body — the same phase-driven pattern as every overlay (module 4.5)."),
    ],
    alternatives: [
      { title: "Skip the polish", text: "The app works without these — a plain Column for the scoreboard, a bare CircularProgressIndicator for connecting. What you lose is the design intent: gold focus chrome, radar ripple, non-blocking history. They're the difference between 'demo' and 'product'." },
      { title: "Animation packages", text: "pulse_ripple could use a package, but a repeating AnimatedBuilder is ~40 lines and dependency-free. The pattern you learn (controller.repeat() + scale/fade) is the same one every animation package wraps." },
    ],
    improve: [
      { title: "Backdrop per theme", text: "The backdrop takes colors as parameters — the settings' table themes (emerald/classic/...) pass their own palettes. Each theme is a data table feeding the same widget." },
      { title: "Accessible deadline signals", text: "deadline_bar is visual-only. A haptic tick in the last second, or a sound cue, makes it usable without looking — the table screen's event subscription is the hook." },
    ],
    activity: {
      type: "quiz",
      q: "How does seat_view.dart put the right player at the bottom for every viewer?",
      opts: ["Four separate layouts", "One modulo expression that rotates the seat ring: (seat - viewer + 4) % 4", "The server sends a 'your position' field", "Hard-coded seat 0"],
      correct: 1,
      explain: "One expression, correct for every player in every mode — no per-player layout code.",
    },
    done: ["All nine files exist, are wired into the table, and hot-reload clean."],
    refs: [
      "frontend/lib/ui/screens/lan_screen.dart",
      "frontend/lib/ui/widgets/backdrop.dart",
      "frontend/lib/ui/widgets/deadline_bar.dart",
      "frontend/lib/ui/widgets/fields.dart",
      "frontend/lib/ui/widgets/pulse_ripple.dart",
      "frontend/lib/ui/widgets/quick_settings_panel.dart",
      "frontend/lib/ui/widgets/round_history.dart",
      "frontend/lib/ui/widgets/seat_view.dart",
      "frontend/lib/ui/widgets/turn_clock.dart",
      "frontend/lib/ui/widgets/winner_screen.dart",
    ],
  }),
  C.step("m16s3", "The Go server, file by file", {
    learn: [
      C.h("The backend inventory"),
      C.p("The server is ~47 files. This map is the completeness guarantee for the backend half: every file, its job, and the module/step that teaches the concepts it implements. None is built by magic."),
    ],
    do: [
      C.p("Tick the tree against what you've built in modules 10-14:"),
      C.code("cmd/server/main.go              m10s1  wiring: config -> deps -> HTTP -> graceful drain\ncmd/loadtest/main.go             m13s5  real-socket load test + legality check\n\ninternal/config/config.go        m14s1  env parsing + defaults + ENV=production strictness\ninternal/obs/obs.go              m14    logging, metrics, health\ninternal/protocol/protocol.go    m11s3  every frame that crosses the wire\ninternal/protocol/server.go      m11s3  frame validation at the edge\n\ninternal/engine/*.go             m10s2  the rules, ported from Dart\ninternal/bot/brain.go            m10s2  the opponent, ported from Dart\ninternal/room/*.go               m10s1  the actor: one goroutine per table\n  room.go        the actor loop + panic recovery\n  hub.go         rooms by code + lifecycle\n  lobby.go       the pre-deal table\n  play.go        move application\n  deadlines.go   turn clocks + timeouts\n  status.go      the admin's live-table view\n  message.go     inbox message types\n  recorder.go    build game records for persistence\n  gamerecord.go  the record shape\ninternal/ws/*.go                 m11s3  the socket edge\n  server.go  upgrade + route\n  conn.go    the per-connection read/write loop\n  identity.go auth token resolution\n  limit.go   the token-bucket budget\n\ninternal/auth/auth.go           m10s3  guest identities + resume tokens (JWT)\ninternal/match/broker.go        m10s4  quickplay seating\ninternal/store/registry.go      m13s1  the Redis room registry\ninternal/httpapi/*.go           m11    the REST surface + admin API\ninternal/db/*.go                m12    Postgres: identity, games, stats, admin\ninternal/settings/settings.go   m14s4  runtime pacing knobs\n\nmigrations/*.sql                m12s4  forward-only schema, embedded\nmigrations/embed.go             m12s4  embed.FS into the binary\n\ndeploy/Dockerfile               m15s5\n deploy/docker-compose.yml      m15s5\nMakefile                        m10s6  test/race/test-db/build targets\nscripts/go.sh                   m10s6  docker fallback when no Go toolchain\nREADME.md                       m10s1  the architecture note\nPROTOCOL.md                     m11s3  the socket contract\ndocs/API.md                     m11    the REST contract\ndocs/PERSISTENCE.md             m12    the database contract", "text"),
      C.p("For any file you haven't opened yet, the map names the concept step. Open internal/room/room.go and confirm it matches the actor you designed in m10s1."),
      C.p("Run <code>make test && make race</code> as the final backend gate (module 10.6)."),
    ],
    explain: [
      C.p("The backend's completeness story is the same as the frontend's: every file is either built step-by-step (the core: engine, room, ws, auth, match) or documented by a concept step that names exactly what the file implements. The room package is 10 files but one idea — the actor from m10s1 — split by concern (play, deadlines, status, recording)."),
      C.p("The inventory also shows the layering the modules taught you in order: cmd (wiring) → ws (edge) → room (actor) → engine (pure) → protocol (contract) → auth (identity) → store (registry) → httpapi/db (persistence) → obs (observability). If the map reads like a dependency graph, that's because it is one — the modules built it in that order on purpose."),
      C.p("Three files carry no module because they're infrastructure: config, obs, and settings. They're covered by the config table in the README, the metrics catalog in m14.3, and the admin knobs in m14.4 — the map points you at the right step, which is its job."),
    ],
    alternatives: [
      { title: "A single backend step per file", text: "47 backend steps would be over-sequenced — internal/room is one actor split across files. The map groups files by the concept step that builds them." },
      { title: "Generate the map from a tree", text: "A `tree backend` output is static and unlinked to the course. This map's value is the step-number linkage — it's the tutorial index for the backend." },
    ],
    improve: [
      { title: "Map the tests too", text: "The next step maps the test suite; keep the two maps together when you add a file." },
      { title: "Document new packages here", text: "When you add an internal/ package, add a line to this map with its owning step — the inventory stays the single source of 'what's where'." },
    ],
    activity: {
      type: "quiz",
      q: "The 10 files of internal/room implement one idea. Which one?",
      opts: ["Ten unrelated features", "The actor from m10s1 — one goroutine per table, split by concern (play, deadlines, status, recording)", "The REST API", "The engine port"],
      correct: 1,
      explain: "room.go is the loop; hub/lobby/play/deadlines/status/message/recorder are the same actor split by concern.",
    },
    done: ["You can point at any backend file and name the module that teaches it."],
    refs: ["backend/internal/", "backend/README.md"],
  }),
  C.step("m16s4", "The test suite, mapped", {
    learn: [
      C.h("Every test has a job"),
      C.p("16 test files, each guarding something specific. This map names what each protects and which step's definition-of-done runs it. When a change breaks something, the failing file tells you which layer is guilty."),
    ],
    do: [
      C.p("Map the frontend tests:"),
      C.code("engine_test.dart          m2s8   the rules: legality, scoring, redaction, flow\n                                        (ported to Go in m10s2 — the cross-language contract)\ndeal_repro_test.dart        m2s1   seeded deals reproduce forever\nwire_contract_test.dart     m7s3   the client parses the docs' frames correctly\napi_contract_test.dart      m6s3   the client parses the docs' JSON correctly\ngame_upload_test.dart       m9s2   upload queue + idempotency across restarts\njoin_sheet_test.dart        m7s2   the private-room join flow\nlan_host_deal_test.dart     m8s1   the host deals + seats guests correctly\nlan_host_clock_test.dart    m8s1   host turn clocks advance under fake time\nlan_guest_restart_test.dart m8s1   a LAN guest survives a host restart\nprofile_screen_test.dart    m5s4   profile + stats render from server fixtures\nturn_clock_test.dart        m4s6   the countdown, wound forward with fake_async\nauto_play_test.dart         m4s3   bot pacing advances a game to completion\ndeadline_bar_test.dart      m16s2  the draining bar's fraction from deadlines\nquick_settings_test.dart    m16s2  the in-table settings sheet\nseat_badge_test.dart        m16s2  seat badges: connected/autoplay states\ntable_probe_test.dart       m4s4   the table screen renders a view\nwidget_test.dart            m4s4   the app shell pumps", "text"),
      C.p("Map the backend tests (the same suite, in Go):"),
      C.code("internal/engine/*_test.go    the rules, ported case-for-case from engine_test.dart\ninternal/bot/brain_test.go   the opponent\ninternal/httpapi/*_test.go   REST + admin, against the doc fixtures\ninternal/settings/*_test.go  runtime knobs\ninternal/db/*_test.go        persistence, gated by TEST_DATABASE_URL\ncmd/loadtest                 not a test — a real-socket load harness (m13s5)", "text"),
      C.p("Answer the coverage question: which layer is NOT unit-tested, and why is that OK (what catches it instead)?"),
    ],
    explain: [
      C.p("The test map is a fault-locator: each file owns a layer, so a red test names its layer. The engine tests are the deepest — and their Go twins (ported case-for-case) are the cross-language contract that keeps client and server agreeing about the rules (module 10.2)."),
      C.p("The two contract tests (wire_contract, api_contract) verify the CLIENT against the literal docs' fixtures — the spec becomes executable (modules 6.3, 7.3). They're why a doc change that the code misreads fails CI instead of reaching players."),
      C.p("The one layer without its own unit test is the UI/animations — deliberately. The table's card-flight and dealing animations are visual; unit-testing them would assert pixels, not meaning. What catches them instead is the widget tests that pump views (table_probe, seat_badge) plus the human run of the animation during module 11 polish. Test the logic, sample the pixels."),
      C.p("fake_async and the clock package are the enablers of the clock tests (turn_clock, lan_host_clock, deadline_bar): they wind time forward instead of waiting — the module 4.6 reason the app's deadlines are durations, not wall-clock comparisons."),
    ],
    alternatives: [
      { title: "Golden-image UI tests", text: "Snapshot every widget to an image and diff. Catches visual regressions; brittle to fonts/platforms. The project samples visuals by hand instead — a defensible trade for a 2-developer app." },
      { title: "Property-based tests", text: "The engine's legality is the ideal property-test target (module 2.2's improve). The hand-written cases are the semantics; property tests are the fuzz net above them." },
    ],
    improve: [
      { title: "Coverage as a trend, not a gate", text: "Run flutter test --coverage and watch the trend per module. The engine should sit near 100%; the UI lower by design. Gate on the trend, not an absolute number." },
      { title: "One test per fixed bug", text: "Every bug you fix in future should land with its failing test first (module 14.6's runbook follow-up). The map is where the test's file is decided." },
    ],
    activity: {
      type: "quiz",
      q: "Which layer deliberately has no unit test, and what catches it instead?",
      opts: ["The engine — caught by the Go port", "The UI animations — caught by widget pumps + a human pass in polish", "The REST client — nothing", "The database — nothing"],
      correct: 1,
      explain: "Visual animations assert pixels, not meaning; widget tests + a human run cover them. Logic is unit-tested, pixels are sampled.",
    },
    done: ["You can point at any test file and name the layer it guards."],
    refs: ["frontend/test/", "backend/internal/", "backend/Makefile"],
  }),
  C.step("m16s5", "Scripts, assets & platforms", {
    learn: [
      C.h("The rest of the repo"),
      C.p("Not code, but still part of the build: the multi-instance test script, the audio/images/fonts the app bundles, and the platform folders that ship it. Each has a job and a step that uses it."),
    ],
    do: [
      C.p("Inventory the non-code assets:"),
      C.code("frontend/scripts/launch_multi_instance.sh   m8s1  launch 4 app copies to test a LAN table solo\nfrontend/assets/audio/                        m11s1 music + card SFX (registered in pubspec)\nfrontend/assets/images/                       m11s1 icon source, any raster art\nfrontend/assets/fonts/                        m3s2  Cinzel + PlusJakartaSans (registered weights)\nfrontend/music_to_use/                        m11s1 licensed tracks awaiting the final cut\nfrontend/test/                                m16s4 the suite\n\nplatform folders (mostly never touched):\nandroid/  ios/  web/  linux/  macos/  windows/\n  native shells generated by flutter create; you edit them only for\n  signing (m15s2/m15s3), bundle ids, and platform-specific config\n\nfrontend/web/                                 the Flutter web target — `flutter run -d chrome`\n                                              during UI dev (module 0.4 alternative)", "text"),
      C.p("Run the multi-instance script and play a four-seat LAN game by yourself — the single best way to exercise module 8 end to end."),
      C.p("Run the app on web (<code>flutter run -d chrome</code>) and confirm the LAN/UDP path degrades gracefully (browsers can't bind raw sockets — the web target is a UI-dev tool, not a LAN host)."),
    ],
    explain: [
      C.p("launch_multi_instance.sh exists because a LAN table needs four players and you are one of them — the script runs multiple app copies so a single developer can play every seat. It's the module 8 equivalent of the loadtest for the frontend: a solo harness for a multiplayer flow."),
      C.p("The platform folders are the 'write once, run everywhere' price of admission: flutter create generates them, and you touch them only at the edges — signing keys (m15s2), bundle id + team (m15s3), and the odd platform permission. The skill to internalize: 99% of your time is in lib/; the platform folders are packaging, not product."),
      C.p("The web target is a dev convenience with a hard boundary: it can't bind raw sockets, so LAN host mode and UDP discovery won't work there — which is exactly why the multi-instance script targets desktop instead. Web is for fast UI iteration (module 3), desktop/Android is for the real game."),
    ],
    alternatives: [
      { title: "One multi-instance launcher", text: "The script could live in CI instead, but its job is a single dev playing four seats — a desktop shell script is the honest tool. A future CI 'four-emulator' matrix is a different harness." },
      { title: "Desktop as the primary dev target", text: "Some teams develop the whole game on Linux/macOS desktop and only package for mobile at the end. Faster feedback (no emulator), same Flutter code. The project's multi-platform folders make this free." },
    ],
    improve: [
      { title: "License tracking", text: "music_to_use needs a provenance table (track, artist, license URL) before any of it ships. An unlicensed asset is a takedown risk, not a feature (module 11.1)." },
      { title: "Platform smoke tests", text: "A script that builds each platform (apk, appbundle, ipa, web) on a schedule catches config rot before a release does. The m15 build steps, automated." },
    ],
    activity: {
      type: "quiz",
      q: "Why doesn't the LAN host mode work on the web target?",
      opts: ["Web is slow", "Browsers can't bind raw UDP sockets — so UDP discovery + the LAN host can't run there; web is a UI-dev tool, desktop/Android is the real game", "Flutter blocks it", "There's no audio"],
      correct: 1,
      explain: "The platform boundary is real: no raw sockets in the browser. Hence the desktop multi-instance script for LAN dev.",
    },
    done: ["You can name what each non-code asset is for and which step uses it."],
    refs: ["frontend/scripts/launch_multi_instance.sh", "frontend/pubspec.yaml", "frontend/assets/"],
  }),
  C.step("m16s6", "The final checklist: you built the whole thing", {
    learn: [
      C.h("Done means verifiable"),
      C.p("This is the project-wide definition of done. Each line is a gate from a module's definition of done — the whole project is done when every line is green. This is your 'nothing at all missing' answer, made checkable."),
    ],
    do: [
      C.p("Run the complete gate, top to bottom:"),
      C.code("FRONTEND\n[ ] flutter analyze           clean (every module's gate)\n[ ] flutter test             the 16-file suite green\n[ ] offline game vs bots     plays a full 5-hand match, sounds + clocks\n[ ] settings persist         theme/difficulty survive a restart\n[ ] REST profile             guest login, history, stats from the server\n[ ] online game              two devices play through the Go server\n[ ] reconnect                killing the app mid-game offers 'Rejoin?'\n[ ] LAN game                 two phones, one host, no internet\n[ ] offline upload           a game finished offline appears ONCE in history\n\nBACKEND\n[ ] make test && make race   green (actor model race-clean)\n[ ] make test-db             persistence against a throwaway Postgres\n[ ] loadtest                 p99 ~13.6ms at 200 tables, zero timeouts\n[ ] /healthz /readyz /metrics answer\n[ ] admin dashboard          live tables + pacing knobs, token-gated\n[ ] degrade drills           kill Postgres/Redis: play continues\n\nSHIP\n[ ] release builds           signed apk + appbundle + TestFlight build\n[ ] store listing            data-safety form answered from real storage\n[ ] deployed backend         make up running, probes green, wss:// live", "text"),
      C.p("Where a line fails, the module that owns it is the tutorial — the checklist is also the map back to the fix."),
      C.p("Then pick your next project from the 'Improve it yourself' columns you collected: accounts upgrade, room snapshots, leaderboards, replay, real-money tables — every one is a named feature with a designed seam in the code."),
    ],
    explain: [
      C.p("The final gate is the course's thesis made concrete: 'complete' is not an opinion, it's a list. Every line traces to a module's definition of done, so a failing line is never 'figure it out' — it's 'the module that owns this, re-read its step'."),
      C.p("The degrade drills are the ones people skip and should not: killing Postgres and Redis mid-game is the difference between trusting the README's degradation postures (modules 12.6, 13.1) and proving them. Game-day drills are a two-hour investment that makes the runbook (module 14.6) real."),
      C.p("The 'Improve it yourself' columns across all 80 steps are the roadmap beyond this course. Each improvement names a feature AND the seam it plugs into (accounts → user_identities + the 501 link endpoint; snapshots → the Redis registry + room rehydration). The design made every extension a named gap — that is what 'designed, not just built' means."),
    ],
    alternatives: [
      { title: "Ship on green only", text: "Treat the checklist as a merge gate, not a to-do. A release that fails a line is a release that ships a hole — the gate is the discipline that keeps the app honest." },
      { title: "A release checklist in the repo", text: "Copy this list into RELEASE.md and keep it current as the app grows — the course's checklist is the seed of your release process." },
    ],
    improve: [
      { title: "Make it CI", text: "The frontend+backend gates already run in CI (module 0.1's improve). Add the loadtest and the degrade drills as scheduled jobs so the checklist verifies itself." },
      { title: "Track post-launch health", text: "After shipping, the six alertable metrics (module 14.3) are your ongoing 'is it still done' — the course's final gate becomes your SLO." },
    ],
    activity: {
      type: "quiz",
      q: "A final-checkout line fails: 'online game — two devices play through the server'. What does the checklist give you?",
      opts: ["A bug report form", "The owning module (m7), whose steps are the tutorial back to the fix", "Permission to skip it", "A server restart"],
      correct: 1,
      explain: "Every line maps to its module's definition of done — the checklist is also the map back to the fix, never a dead end.",
    },
    done: ["The whole project-wide checklist is green — you built and shipped the game."],
    refs: ["docs/course/README.md", "backend/README.md"],
  }),
]));
