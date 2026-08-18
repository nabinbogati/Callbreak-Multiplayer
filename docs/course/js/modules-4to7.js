/* Build Call Break — modules 4-7: table vs bots, state/audio, REST, WebSockets. */

REGISTER(C.module("m4", "♣", "The Table vs Bots", "your first playable game", [
  C.step("m4s1", "The GameSession contract", {
    learn: [
      C.h("The single most important design decision"),
      C.p("The table screen never talks to a game object — it talks to an interface called GameSession: a redacted GameView to render, a Stream of events to animate, and three intents. A solo game, a server-backed game, and a LAN game are all just different implementations. Swap the implementation, the screen doesn't change."),
    ],
    do: [
      C.p("Create <code>lib/net/session.dart</code> and declare the abstract contract — this is your service interface:"),
      C.code("abstract class GameSession extends ChangeNotifier {\n  GameView? get view;                // what to render\n  SessionStatus get status;\n  String? get errorMessage;\n  GameMode get mode;\n  Stream<GameEvent> get events;      // what happened (sounds, animations)\n\n  bool get isReady => status == SessionStatus.ready && view != null;\n\n  // The three intents — the UI's entire vocabulary:\n  void placeBid(int bid);\n  void play(PlayingCard card);\n  void continueToNextHand();\n  void restart();\n}", "dart"),
      C.p("Add the networked flavour: NetworkSession extends GameSession with lobby concerns (lobby state, countdown, leaveLobby, startGame, resume). The table screen still only sees GameSession."),
      C.p("Write the three intents as a one-line test double: a fake session that records the calls. This double is what your widget tests will inject in place of a real session."),
    ],
    explain: [
      C.p("This is 'program to an interface, not an implementation' applied to UI. The screen depends only on the contract, so LocalSession, RemoteSession, and LanHostSession are interchangeable behind it. When module 7 ships a WebSocket-backed session, the table screen doesn't change a line — that's the test of whether the abstraction is honest."),
      C.p("ChangeNotifier is the pub/sub: the session calls <code>notifyListeners()</code> whenever its view changes, and the UI rebuilds. Extending ChangeNotifier (rather than rolling a callback list) is the framework's built-in mechanism — same shape you'd use a NotificationService for in Go."),
      C.p("The three intents are the entire command vocabulary: <code>placeBid</code>, <code>play</code>, <code>continueToNextHand</code> (+ restart). No 'set game state', no mutation of views — the session owns how intents become state, whether that's an engine call or a socket frame."),
    ],
    alternatives: [
      { title: "Provider/Riverpod exposure", text: "A Riverpod provider could expose the session and auto-dispose it when the screen unmounts. The app passes sessions explicitly via constructor — simpler, and the same interface pattern survives either way." },
      { title: "Interface + factory", text: "A session factory (buildSession(mode, settings)) centralizes which implementation to create. The home screen will grow one in module 4.5 — extract it early." },
    ],
    improve: [
      { title: "Document the contract", text: "The session.dart file's docs are the best teaching in the repo — copy that tone for any new intent you add. The clock-skew comment (module 4.6) is a model of explaining why, not just what." },
      { title: "Contract test the UI", text: "Because every mode drives the same GameSession, one widget test suite with a fake session covers ALL modes. That's the abstraction's hidden payoff — a single table-screen test suite." },
    ],
    activity: {
      type: "quiz",
      q: "The table screen needs to play a card. What does it call?",
      opts: ["game.playCard(seat, card)", "session.play(card)", "setState()", "A direct WebSocket write"],
      correct: 1,
      explain: "The UI's only move is session.play(card) — the session decides where it goes (local engine, socket, LAN host).",
    },
    done: ["You can explain why the UI only ever touches GameSession."],
    refs: ["frontend/lib/net/session.dart", "frontend/lib/ui/screens/table_screen.dart"],
  }),
  C.step("m4s2", "The bot brain", {
    learn: [
      C.h("The opponent"),
      C.p("BotBrain has two jobs: choose a bid (estimateTricks + noise) and choose a card during play. Difficulty is a dial — how much noise around the estimate and how often to blunder."),
    ],
    do: [
      C.p("Create <code>lib/bots/bot.dart</code>. Start with the difficulty dial — the whole difficulty system is two numbers:"),
      C.code("double get _noise => switch (difficulty) {\n  BotDifficulty.easy => 1.4,\n  BotDifficulty.normal => 0.5,\n  BotDifficulty.hard => 0.0,\n};\ndouble get _blunderRate => switch (difficulty) {\n  BotDifficulty.easy => 0.25,\n  BotDifficulty.normal => 0.06,\n  BotDifficulty.hard => 0.0,\n};", "dart"),
      C.p("Implement <code>chooseBid</code> — the estimate plus jitter, clamped:"),
      C.code("int chooseBid(List<PlayingCard> hand) {\n  final estimate = estimateTricks(hand);\n  final jitter = _noise == 0 ? 0.0 : (_random.nextDouble() * 2 - 1) * _noise;\n  return clampBid((estimate + jitter).round());\n}", "dart"),
      C.p("Implement <code>chooseCard</code>: filter to legal moves, single-card shortcut, blunder roll, then lead vs follow strategies."),
      C.p("Write the lead strategy first: side-suit masters first (unbeatable tricks), then long-suit building. Follow strategy comes next — play to the bid (module 9's trick-counting shows up here)."),
    ],
    explain: [
      C.p("The <code>played</code> parameter — every face-up card this hand — is what makes the bot a card-counter. From 'what's been played' it derives <code>unseen</code>: the cards that can still beat it. A side-suit master is a card no unseen card can beat — an actual guaranteed trick. That's the whole value of the parameter."),
      C.p("Blunders are the difficulty honesty mechanism: the hard bot never blunders and has zero jitter, the easy bot misplays a quarter of its turns. Same brain, different variance — which is how real card skill actually differs between players."),
      C.p("The bot ALWAYS asks legalMoves first. It may play badly, but it never cheats — the same legality the human faces, so a bot can never be caught winning on an illegal card."),
    ],
    alternatives: [
      { title: "Two-ply search", text: "A lookahead bot could simulate its best reply to each legal move. Stronger play, far more compute — the current heuristic is the cost/quality sweet spot for a phone." },
      { title: "Learned evaluation", text: "Train the estimate weights on logged games. The project keeps a hand-tuned formula; a future you with data could swap in learned weights behind the same estimateTricks signature." },
    ],
    improve: [
      { title: "Different bot personalities", text: "Aggressive (bid high, lead trumps), passive (underbid, hold back) — same brain, different noise curves. Cheap variety for a 4-seat table." },
      { title: "Port to Go, reuse for autoplay", text: "The Go port (module 10) runs the same brain for server-side autoplay. One brain, three seats of the family: bots, autoplay, and the estimate." },
    ],
    activity: {
      type: "quiz",
      q: "What makes an easy bot easy?",
      opts: ["It knows fewer rules", "More noise in the bid estimate + a higher blunder rate", "It plays slower", "It has fewer cards"],
      correct: 1,
      explain: "Difficulty is just noise + blunderRate dials around the same deterministic brain.",
    },
    done: ["You can explain the bot's two jobs and how difficulty dials in."],
    refs: ["frontend/lib/bots/bot.dart", "frontend/lib/engine/rules.dart"],
  }),
  C.step("m4s3", "LocalSession: the host clock", {
    learn: [
      C.h("A session that runs itself"),
      C.p("LocalSession is a GameSession owning the engine, three bot brains, and the pacing timers. Its heartbeat is <code>_publish</code>: take the redacted view → drain events → notifyListeners → schedule the next automatic action. This method is the rhythm of the entire app."),
    ],
    do: [
      C.p("Create <code>lib/net/local_session.dart</code>. Declare TablePacing — every duration the game needs, in one place:"),
      C.code("class TablePacing {\n  static const botThinkMin = Duration(milliseconds: 550);\n  static const botThinkExtra = Duration(milliseconds: 450);\n  static const trickLinger = Duration(milliseconds: 1100);\n  static const dealSettle = Duration(milliseconds: 350);\n  static const bidTimeout = Duration(seconds: 5);\n  static const playTimeouts = [\n    Duration(seconds: 10), Duration(seconds: 8),\n    Duration(seconds: 6), Duration(seconds: 5),\n  ];\n  static const handAdvanceWait = Duration(seconds: 5);\n}", "dart"),
      C.p("Extend GameSession. Hold the engine, the brains, and a timer. In the constructor, build the four seats and start the game."),
      C.p("Implement the publish loop — mutate, publish, schedule:"),
      C.code("void _publish() {\n  if (_disposed) return;\n  _view = _game.viewFor(humanSeat);\n  for (final event in _game.takeEvents()) {\n    _record(event);                    // feed the offline uploader\n    if (!_events.isClosed) _events.add(event);  // fan out to the UI\n  }\n  notifyListeners();                   // UI rebuilds with the new view\n  _scheduleNextAutoAction();           // bots, trick linger, ...\n}\n\nvoid _scheduleNextAutoAction() {\n  _timer?.cancel();\n  if (_disposed) return;\n  if (_game.awaitingTrickClear) {\n    _timer = Timer(_scaled(TablePacing.trickLinger), () {\n      _game.clearTrick(); _publish();\n    });\n    return;\n  }\n  final seat = _game.turn;\n  if (seat == null || seat == humanSeat) return;  // human: wait for input\n  final brain = _brains[seat];\n  if (brain == null) return;\n  _timer = Timer(_thinkTime(), () => _takeBotTurn(seat, brain));\n}", "dart"),
      C.p("Implement <code>_takeBotTurn</code> — switch on phase, ask the brain, apply, republish. Then the three UI intents (placeBid/play/continueToNextHand) as thin forwards. Cancel the timer and close the stream in dispose."),
    ],
    explain: [
      C.p("The publish loop is a tiny scheduler: after every state change it recomputes 'what should the table do on its own next?'. A bot is up → schedule a think timer. A finished trick is lingering → schedule the clear. A human is up → do nothing and wait. One timer at a time, cancelled before rescheduling, so there is never a stale action firing late."),
      C.p("The engine does NOT drive itself. Purity means LocalSession decides WHEN a bot thinks (550-1000ms jittered), how long a trick stays on the table (1.1s), how long a deal settles (350ms). Those constants are the difference between a game that feels like a table and one that feels like a script. The Go server's pacing defaults deliberately match these — one feel, two languages."),
      C.p("dispose cancels the timer and closes the event stream. A leaked Timer would keep playing bot turns for a disposed screen; a closed stream makes that impossible. Your backend version of this is shutting down a worker pool — same reflex, smaller scale."),
    ],
    alternatives: [
      { title: "Injected clock for tests", text: "Real time is untestable. The repo uses the clock package (injectable now) and fake_async (winds timers forward) so a turn-clock test runs in milliseconds, not 5 real seconds. Reach for them the moment a test 'waits'." },
      { title: "The host as a separate class", text: "LocalSession could be split into a GameHost (pacing) + a transport. The merge here is intentional — a solo session has no transport, so one class is honest." },
    ],
    improve: [
      { title: "Respect animation-speed settings", text: "The real session scales every pacing duration by AnimationSpeed (slow/normal/fast) — a settings toggle that multiplies TablePacing. Add a durationScale getter and multiply once in _scaled()." },
      { title: "Auto-play idle humans", text: "The online server does this (module 7); the offline mode deliberately never rushes you. Keep it that way — solo play is the patient practice mode." },
    ],
    activity: {
      type: "code",
      starter: "// Write the skeleton of a publish loop:\n// a _publish() that notifies listeners and schedules a\n// Timer-delayed auto action if a bot seat is up.\nimport 'dart:async';\nimport 'package:flutter/foundation.dart';\n\nclass MiniSession extends ChangeNotifier {\n  Timer? _timer;\n  bool botUp = false;\n\n  void _publish() {\n    // your code: notify + schedule\n  }\n\n  void _scheduleNext() {\n    _timer?.cancel();\n    if (!botUp) return;\n    _timer = Timer(const Duration(milliseconds: 500), () {\n      botUp = false;\n      _publish();\n    });\n  }\n\n  @override\n  void dispose() {\n    _timer?.cancel();\n    super.dispose();\n  }\n}",
      checks: [
        CHK.has("notifies", "notifyListeners", "Call notifyListeners() in _publish()."),
        CHK.has("schedules", "_scheduleNext", "Call _scheduleNext() from _publish()."),
        CHK.has("cancels", "_timer\\?\\?\\.cancel|_timer\\.cancel", "Cancel the pending timer before scheduling."),
      ],
    },
    done: ["You can explain the publish loop's four steps from memory."],
    refs: ["frontend/lib/net/local_session.dart"],
  }),
  C.step("m4s4", "The table screen structure", {
    learn: [
      C.h("The felt, the seats, your hand"),
      C.p("One Stack: felt background, four seat views pinned around the edges, trick area in the middle, your hand fanned at the bottom, overlays on top. The screen is a StatefulWidget whose state is one GameSession."),
    ],
    do: [
      C.p("Create <code>lib/ui/screens/table_screen.dart</code> — a StatefulWidget taking a session. In initState, subscribe to the session's events for sounds/animations:"),
      C.code("class TableScreen extends StatefulWidget {\n  const TableScreen({super.key, required this.session});\n  final GameSession session;\n  @override\n  State<TableScreen> createState() => _TableScreenState();\n}\n\nclass _TableScreenState extends State<TableScreen> {\n  StreamSubscription<GameEvent>? _eventsSub;\n\n  @override\n  void initState() {\n    super.initState();\n    _eventsSub = widget.session.events.listen((e) {\n      switch (e) {\n        case CardPlayed():  playCardSound();\n        case TrickWon():    playTrickSound();\n        case GameOver():    playGameOverSound();\n        default:            break;\n      }\n    });\n  }\n\n  @override\n  void dispose() {\n    _eventsSub?.cancel();       // ALWAYS cancel\n    super.dispose();\n  }", "dart"),
      C.p("Build the body with ListenableBuilder — rebuild whenever the session notifies:"),
      C.code("@override\nWidget build(BuildContext context) {\n  return ListenableBuilder(\n    listenable: widget.session,\n    builder: (context, _) {\n      final view = widget.session.view;\n      if (view == null) return _connecting();   // still starting\n      return Stack(children: [\n        const Positioned.fill(child: FeltTable()),\n        ...seatViews(view),\n        Center(child: TrickCluster(view)),\n        Align(alignment: Alignment.bottomCenter, child: HandFan(view.hand)),\n        ...phaseOverlays(view),   // bid panel / scoreboard / winner\n      ]);\n    },\n  );\n}", "dart"),
      C.p("Wire it into the home screen: tapping 'vs Bots' builds a LocalSession(playerName, difficulty) and pushes TableScreen. You just made the app playable."),
    ],
    explain: [
      C.p("ListenableBuilder is the idiomatic glue for a ChangeNotifier: its builder re-runs on every notifyListeners, so the Stack re-derives from the latest view. The switch over sealed GameEvent is where the compiler guarantees every event type is handled — add an event in the engine and this switch forces you to decide what it does here."),
      C.p("The <code>view == null</code> branch is the connecting state — the session exists but hasn't produced a view yet (spinning up, or a network connect in flight). Rendering a loader instead of a broken table is the difference between a professional app and a demo."),
      C.p("The Stack ordering IS the render order: felt at the back, then seats, then the trick, then your hand, then overlays on top. Each layer is a function of the view, and the whole thing is pure data → widgets."),
    ],
    alternatives: [
      { title: "AnimatedBuilder", text: "AnimatedBuilder is ListenableBuilder with a child parameter for static parts — the felt, which never changes, could be hoisted to avoid rebuild. Marginal here; good micro-optimization habit." },
      { title: "StreamBuilder for events", text: "Events could drive widgets via StreamBuilder. The screen instead uses the stream for side effects (sounds) and the notifier for state (view) — two concerns, two mechanisms, deliberately split." },
    ],
    improve: [
      { title: "Seat keys for animation", text: "The real screen keeps GlobalKeys per seat and the felt Stack so the flight animation can measure real on-screen positions. Add the keys when you add the card-throw animation (module 11 polish)." },
      { title: "Extract phase overlays", text: "Each overlay (bid panel, scoreboard, winner) is its own widget file. Keep them separate so the table screen stays a coordinator, not a mega-widget." },
    ],
    activity: {
      type: "quiz",
      q: "Why does the table screen use ListenableBuilder around the session?",
      opts: ["To make the session faster", "To rebuild the table whenever the session's view/state changes", "Because Stack needs it", "To play sounds"],
      correct: 1,
      explain: "The session is a ChangeNotifier; ListenableBuilder rebuilds the UI on every notifyListeners().",
    },
    done: ["You can explain what renders for view == null."],
    refs: ["frontend/lib/ui/screens/table_screen.dart", "frontend/lib/ui/widgets/felt_table.dart"],
  }),
  C.step("m4s5", "Bid panel + scoreboard", {
    learn: [
      C.h("The overlays"),
      C.p("When the phase is bidding, an overlay shows bid buttons. Between hands, a scoreboard shows running totals and the countdown. Both read from the view; both call session intents."),
    ],
    do: [
      C.p("Build the bid panel — phase-gated, with the shared suggestion the engine already gives your bots:"),
      C.code("// shown only when view.phase == GamePhase.bidding\nfinal suggested = suggestBid(view.hand);      // same heuristic the bots use\n\nElevatedButton(\n  onPressed: () => widget.session.placeBid(bid),\n  child: Text('\$bid'),\n)", "dart"),
      C.p("Build the scoreboard for handOver — totals per seat, and the advance button:"),
      C.code("Column(children: [\n  for (final p in view.players)\n    Row(children: [\n      Text(p.name),\n      Text(view.totals[p.seat].toStringAsFixed(1)),\n    ]),\n  TextButton(\n    onPressed: () => widget.session.continueToNextHand(),\n    child: const Text('Deal next hand'),\n  ),\n])", "dart"),
      C.p("Add the winner overlay for gameOver — rankings from the view's seatRanking list, with a Restart intent."),
      C.p("Gate all three by switching on view.phase in <code>phaseOverlays(view)</code>."),
    ],
    explain: [
      C.p("The bid suggestion is a freebie: estimateTricks already powers every bot's bid, so the human gets the same brain as a 'suggest' — one heuristic, three consumers (bots, suggestion, and the server's autoplay later). Notice the UI never computes a strategy; it asks the engine."),
      C.p("Everything the overlays show is in the view — players, totals, phase — so they're pure functions of data. The only 'mutation' they do is call session intents, which the session routes. Phase-driven UI is the entire overlay strategy: switch on phase, render the right panel, no cross-widget state."),
      C.p("<code>toStringAsFixed(1)</code> is the score formatting detail — Call Break scores like 4.1 (module 2.2), and 1 decimal keeps the scoreboard tight. Small decisions like this are what make a scoreboard read as designed rather than dumped."),
    ],
    alternatives: [
      { title: "An index-based overlay", text: "You could track an overlay int and swap widgets. Deriving from view.phase is strictly better — the data decides, so the overlay can never disagree with the game." },
      { title: "Bottom sheet for scoreboard", text: "The real app shows the scoreboard as a popup/countdown between hands. A modal sheet works too; the countdown (from handAdvanceDeadline, module 4.6) is what makes the popup a real UX decision." },
    ],
    improve: [
      { title: "Score delta animation", text: "Animate the +4.1 / -3 on the scoreboard at HandOver. The events stream already fires — a scale/fade on the delta is a few lines." },
      { title: "Running score history", text: "The round_history widget shows per-hand scores across the match. The engine's HandOver deltas give you exactly that data — render a column of deltas per seat." },
    ],
    activity: {
      type: "quiz",
      q: "The bid suggestion comes from the same code that bids for bots. True or false?",
      opts: ["True — one heuristic, three consumers", "False — bots cheat", "Only for hard bots", "Only offline"],
      correct: 0,
      explain: "estimateTricks → suggestBid for the human, and the same estimate feeds every bot's chooseBid.",
    },
    done: ["You can switch the overlay on view.phase."],
    refs: ["frontend/lib/ui/widgets/bid_panel.dart", "frontend/lib/ui/widgets/scoreboard.dart"],
  }),
  C.step("m4s6", "Turn clock & pacing", {
    learn: [
      C.h("Making it feel like a game"),
      C.p("Human seats get a countdown; bots don't. The deadline comes from the view, converted once to a device-clock duration (the two clocks disagree — serverTimeMs anchors 'now'). TablePacing owns every duration."),
    ],
    do: [
      C.p("Understand the clock-skew trap BEFORE writing the deadline getter — read this comment twice:"),
      C.code("// The server's deadline is on the SERVER's clock, useless to compare\n// against DateTime.now() on a phone whose clock is minutes off.\n// Convert it ONCE, when the view lands, by treating view.serverTimeMs\n// as 'now'. What survives is a DURATION, which both clocks agree on.\nDateTime? turnDeadline => _view == null ? null\n    : _deadlineFrom(view.turnDeadlineMs, view.serverTimeMs);", "dart"),
      C.p("Build the turn clock widget: a countdown that reads the session's turnDeadline and repaints each second, turning red under 3s."),
      C.p("Build the between-hands countdown from handAdvanceDeadline the same way — the table won't wait forever on a player who put their phone down."),
      C.p("Add the pacing constants for playTimeouts (leader thinks longest — 10s down to 5s for the last seat) and explain why each seat gets less time."),
    ],
    explain: [
      C.p("The clock-skew bug is the classic 'obvious' bug you'd ship as a backend dev: you compare the server's deadline to <code>DateTime.now()</code> and it works on the emulator (same clock) and breaks on phones (clocks minutes off). The fix — convert to a duration once, anchored to <code>serverTimeMs</code> — is a five-line idiom that belongs in every networked app. Read the session.dart comment when you get here; it's a model of explaining the WHY."),
      C.p("playTimeouts shrink by trick position for a reason: the leader has nothing down to react to, so they get 10s; the 4th seat has three cards already down and usually one legal reply, so 5s. Pacing that mirrors real thinking time is what makes the table feel alive rather than mechanical."),
      C.p("The between-hands cap is a social feature: a table with other people can't sit on a scoreboard forever because one player walked away. The countdown communicates that the deal is coming regardless — the <code>continueToNextHand</code> intent is consent, not a requirement."),
    ],
    alternatives: [
      { title: "Let the server count down", text: "The server could push '1s left' frames. It doesn't — a lost frame would stall the clock. Local rendering from a converted deadline is robust to frame loss." },
      { title: "Duration-only in the view", text: "The view could carry a duration instead of an absolute deadline. It carries serverTimeMs so ANY widget can re-anchor without a server round-trip — the timestamp is the more general contract." },
    ],
    improve: [
      { title: "Show bot think as anticipation", text: "A subtle 'thinking…' ripple on the active bot seat (the real app's pulse_ripple widget) turns pacing into theatre. Pure decoration, huge feel." },
      { title: "Re-sync on every view", text: "Each new view re-anchors the deadline, so a stuttery network connection self-corrects instead of compounding skew. Make sure your conversion runs per-view, not per-session." },
    ],
    activity: {
      type: "quiz",
      q: "Why can't the app compare view.turnDeadlineMs to DateTime.now() directly?",
      opts: ["It's slower", "The phone's clock may be minutes off the server's", "Dart forbids it", "The deadline is always null"],
      correct: 1,
      explain: "Clock skew: convert the deadline to a duration once, using serverTimeMs as the anchor.",
    },
    done: ["You can explain the clock-skew conversion and the pacing table."],
    refs: ["frontend/lib/net/local_session.dart (TablePacing)", "frontend/lib/net/session.dart", "frontend/lib/ui/widgets/turn_clock.dart"],
  }),
]));

REGISTER(C.module("m5", "♢", "State & Audio", "settings, identity, sound", [
  C.step("m5s1", "Persisting identity", {
    learn: [
      C.h("shared_preferences"),
      C.p("Your device id and session token must survive restarts. shared_preferences is a tiny key-value store on disk — your Redis for one phone. The identity is read ONCE in main() before runApp, so widgets treat it as a plain synchronous value."),
    ],
    do: [
      C.p("Create <code>lib/state/identity_store.dart</code> — a thin wrapper over SharedPreferences with the id minted once:"),
      C.code("class IdentityStore {\n  IdentityStore._(this._prefs);\n  final SharedPreferences _prefs;\n\n  static Future<IdentityStore> open() async {\n    final prefs = await SharedPreferences.getInstance();\n    return IdentityStore._(prefs);\n  }\n\n  String get deviceId {\n    final cached = _prefs.getString('device_id');\n    if (cached != null) return cached;\n    final id = _generateId();       // Random.secure() — no uuid package\n    _prefs.setString('device_id', id);\n    return id;\n  }\n\n  String? get sessionToken => _prefs.getString('session_token');\n  void saveSessionToken(String t) => _prefs.setString('session_token', t);\n}", "dart"),
      C.p("Implement <code>_generateId</code> with Random.secure() — you do NOT need the uuid package for a v4."),
      C.p("In main(), open the store BEFORE runApp so the whole tree reads it synchronously:"),
      C.code("Future<void> main() async {\n  WidgetsFlutterBinding.ensureInitialized();   // plugin channels need this\n  final settings = AppSettings(identity: await IdentityStore.open());\n  runApp(CallBreakApp(settings: settings));\n}", "dart"),
      C.p("Add <code>IdentityStore.inMemory()</code> for widget tests — a fake that never touches the real storage channel."),
    ],
    explain: [
      C.p("<code>WidgetsFlutterBinding.ensureInitialized()</code> is required before any async work in main: plugin channels (like SharedPreferences) need the binding up. Forgetting it is the classic 'await before runApp throws' startup crash."),
      C.p("The sync-after-await design is the important choice: because identity is loaded before runApp, no widget ever awaits a Future to get the device id — they read <code>settings.identity.deviceId</code> as a plain value. That's the same 'hoist the async to startup' discipline you'd use to avoid a config fetch on every request."),
      C.p("Minting the id ONCE and persisting it is what makes the device id stable across restarts — and that stability is what ties a guest's history and uploads to one identity in module 6."),
    ],
    alternatives: [
      { title: "Hive / sqflite", text: "For more than a few keys, Hive or sqflite are structured stores. shared_preferences is a flat key-value map — exactly right for an id and a token; anything relational is future scope." },
      { title: "secure storage", text: "flutter_secure_storage puts keys in the OS keychain/keystore — the right call if the token were a real credential. For a casual guest token, prefs is honest about its security posture." },
    ],
    improve: [
      { title: "Rotate tokens", text: "Issue a fresh guest token on reconnect and invalidate the old one server-side. The protocol supports re-issuing via the joined frame — a real security improvement for the 'findable' guest identity." },
      { title: "Account upgrade path", text: "The server's schema carries Google/Facebook/Apple identities (POST /v1/auth/link, currently 501). Tying the device identity to a real account is the designed-but-unbuilt upgrade — your future monetization/logon story." },
    ],
    activity: {
      type: "quiz",
      q: "Why is IdentityStore opened in main() before runApp() instead of lazily in a widget?",
      opts: ["It's faster", "So every widget can read the device id synchronously, no Future plumbing", "The framework requires it", "It avoids memory leaks"],
      correct: 1,
      explain: "Load once up front; the whole tree reads plain values.",
    },
    done: ["Your device id is stable across app restarts."],
    refs: ["frontend/lib/state/identity_store.dart", "frontend/lib/main.dart"],
  }),
  C.step("m5s2", "AppSettings + InheritedWidget scope", {
    learn: [
      C.h("DI without a framework"),
      C.p("AppSettings is a ChangeNotifier holding every preference. A SettingsScope InheritedWidget provides it down the tree — this is your DI container. Any widget reads settings via SettingsScope.of(context); any change notifies listeners."),
    ],
    do: [
      C.p("Create <code>lib/state/app_settings.dart</code> — the settings notifier with setters that notify:"),
      C.code("class AppSettings extends ChangeNotifier {\n  AppSettings({IdentityStore? identity})\n      : _identity = identity ?? IdentityStore.inMemory();\n\n  final IdentityStore _identity;\n  String _playerName = 'You';\n  BotDifficulty _difficulty = BotDifficulty.normal;\n  String _serverUrl = '';\n  bool _dragToPlayEnabled = true;\n  AnimationSpeed _animationSpeed = AnimationSpeed.normal;\n\n  IdentityStore get identity => _identity;\n  String get playerName => _playerName;\n  BotDifficulty get difficulty => _difficulty;\n\n  set playerName(String v) { _playerName = v; notifyListeners(); }\n  set difficulty(BotDifficulty v) { _difficulty = v; notifyListeners(); }\n}", "dart"),
      C.p("Add the scope — Flutter's native DI:"),
      C.code("class SettingsScope extends InheritedWidget {\n  const SettingsScope({super.key, required this.settings, required super.child});\n  final AppSettings settings;\n\n  static AppSettings of(BuildContext context) =>\n      context.dependOnInheritedWidgetOfExactType<SettingsScope>()!.settings;\n\n  @override\n  bool updateShouldNotify(SettingsScope old) => settings != old.settings;\n}", "dart"),
      C.p("Wrap the app in main: <code>SettingsScope(settings: settings, child: MaterialApp(...))</code>."),
      C.p("In any widget, read and write: <code>SettingsScope.of(context).playerName = 'Nabin'</code>. Watch dependent widgets rebuild."),
    ],
    explain: [
      C.p("<code>context.dependOnInheritedWidgetOfExactType</code> subscribes the calling widget to the scope: when the value changes, every dependent rebuilds. That's the pub/sub again, but for the whole widget tree — your DI container AND your reactivity in one mechanism."),
      C.p("The setters call notifyListeners because AppSettings IS the state: changing difficulty from the settings sheet must reach a live table that reads it. One object, shared by reference, drives both the sheet and the game."),
      C.p("The identity living inside AppSettings is deliberate — 'the persistent half'. One object hands everything down the tree: your name, your difficulty, your token, your id. No scatter of singletons, no global state to hunt."),
    ],
    alternatives: [
      { title: "provider package", text: "provider is a thin wrapper over InheritedWidget with the same of(context) API — it exists precisely because this pattern is the right one and the wrapper removes ~15 lines per scope. The app hand-rolls it to teach the mechanics; switching to provider later is a drop-in." },
      { title: "Riverpod", text: "Riverpod adds compile-safe providers and auto-dispose. It's the 'better way' when the tree of dependencies grows; for one settings object, the scope is enough." },
    ],
    improve: [
      { title: "Persist settings", text: "The real app keeps display settings in memory only — 'a theme is cheap to pick again after a reinstall, an account is not'. Decide consciously which settings deserve disk and which are session-scratch." },
      { title: "Server URL in a debug sheet", text: "The settings sheet's server field is how you point the app at your Go server during dev. Keep it visible-but-out-of-the-way — it's a dev tool that would confuse end users." },
    ],
    activity: {
      type: "code",
      starter: "// Build a minimal ChangeNotifier holding one int _level\n// with a setter that notifies.\nimport 'package:flutter/foundation.dart';\n\nclass GameSettings extends ChangeNotifier {\n  int _level = 1;\n  int get level => _level;\n\n  set level(int v) {\n    // your code\n  }\n}",
      checks: [
        CHK.has("extends", "extends\\s+ChangeNotifier", "Extend ChangeNotifier."),
        CHK.has("getter", "get\\s+level", "Expose a level getter."),
        CHK.has("setter notifies", "notifyListeners", "Call notifyListeners() in the setter."),
      ],
    },
    done: ["You can provide a settings object down a widget tree via InheritedWidget."],
    refs: ["frontend/lib/state/app_settings.dart"],
  }),
  C.step("m5s3", "Audio controller", {
    learn: [
      C.h("Sound without blocking anything"),
      C.p("A tiny singleton, initialized once in main, playing background music and one-shot SFX via audioplayers. Gated by settings so users can mute. Fire-and-forget — a missing asset must never crash the table."),
    ],
    do: [
      C.p("Create <code>lib/audio/audio_controller.dart</code> — a static-init singleton:"),
      C.code("class AudioController {\n  static AudioController? _instance;\n  static void init(AppSettings settings) {\n    _instance ??= AudioController(settings);   // one per process\n  }\n\n  AudioController(this._settings);\n  final AppSettings _settings;\n\n  void playCardThud() { if (_settings.sfxEnabled) _play('assets/audio/card.mp3'); }\n  void playTrickWin() { if (_settings.sfxEnabled) _play('assets/audio/trick.mp3'); }\n  void playBackground() {\n    if (_settings.musicEnabled) _loop('assets/audio/table.mp3');\n  }\n}", "dart"),
      C.p("Implement <code>_play</code>/<code>_loop</code> over the audioplayers plugin with try/catch — audio failure is never fatal."),
      C.p("Call <code>AudioController.init(settings)</code> in main, start background music after runApp."),
      C.p("Wire the SFX into the table screen's event subscription (module 4.4): CardPlayed → playCardThud, TrickWon → playTrickWin, GameOver → playGameOverSound."),
    ],
    explain: [
      C.p("The <code>??=</code> guard is a process-wide singleton — one controller for the whole app, created once in main and passed the settings by reference. Every play method gates on <code>settings.sfxEnabled</code> AT PLAY TIME, so flipping the toggle in the sheet takes effect immediately with no re-registration."),
      C.p("Sound lives with the EVENT CONSUMER, not the engine. The table screen's sealed-event switch calls playCardThud; the engine never knows audio exists. That's the purity rule from module 2 enforced at the edges — the same reason the Go server has no audio at all."),
      C.p("The try/catch around every play is a robustness decision: a missing or corrupt asset must degrade to silence, never a crash. Your backend version is a metrics call that swallows its own errors."),
    ],
    alternatives: [
      { title: "just_audio / flame_audio", text: "just_audio is the heavier-duty player (streams, gapless); audioplayers is the lightweight all-rounder the app uses. Either works; the abstraction (a controller gated by settings) is what matters." },
      { title: "Sound via the engine events", text: "You could play sounds inside the engine's event emission. That couples the pure engine to the plugin and breaks the Go port. The consumer-side hook is the only honest place." },
    ],
    improve: [
      { title: "Crossfade between tracks", text: "The music_to_use/ folder holds licensed tracks awaiting a cut. Crossfading between them needs just_audio's gapless support — a polish-phase swap behind the same controller." },
      { title: "Volume preferences", text: "A music/SFX volume slider per channel is two more settings + two gain calls. The toggle exists; the slider is the natural next step." },
    ],
    activity: {
      type: "quiz",
      q: "Where should the 'card landed' sound be triggered?",
      opts: ["Inside the engine's playCard", "From the table screen's event subscription on CardPlayed", "In build()", "In the bots"],
      correct: 1,
      explain: "Side effects live with the consumer of events — never inside the pure engine.",
    },
    done: ["Sound plays from events, and muting respects the settings."],
    refs: ["frontend/lib/audio/audio_controller.dart", "frontend/lib/ui/screens/table_screen.dart"],
  }),
  C.step("m5s4", "Settings sheet + profile screen", {
    learn: [
      C.h("Editing the state you built"),
      C.p("Two thin screens complete module 5: a settings sheet (theme, card style, difficulty, server URL, animation speed, sound) and a profile screen (name, guest identity, history + stats — which the REST layer fills in module 6). Both read/write AppSettings through SettingsScope."),
    ],
    do: [
      C.p("Build the settings sheet — form controls that write straight into the notifier:"),
      C.code("class SettingsSheet extends StatelessWidget {\n  const SettingsSheet({super.key});\n\n  @override\n  Widget build(BuildContext context) {\n    final settings = SettingsScope.of(context);\n    return Column(children: [\n      SwitchListTile(\n        title: const Text('Sound effects'),\n        value: settings.sfxEnabled,\n        onChanged: (v) => settings.sfxEnabled = v,\n      ),\n      DropdownButton<BotDifficulty>(\n        value: settings.difficulty,\n        onChanged: (v) => settings.difficulty = v ?? BotDifficulty.normal,\n        items: const [\n          DropdownMenuItem(value: BotDifficulty.easy, child: Text('Easy')),\n          DropdownMenuItem(value: BotDifficulty.normal, child: Text('Normal')),\n          DropdownMenuItem(value: BotDifficulty.hard, child: Text('Hard')),\n        ],\n      ),\n    ]);\n  }\n}", "dart"),
      C.p("Add a server URL field (a TextField the app reads when creating network sessions) — your dev gateway to the Go server."),
      C.p("Build the profile screen skeleton: your name (editable → settings.playerName), device id, and placeholder slots for history/statistics that module 6 fills."),
      C.p("Wire the home screen to open both from app-bar actions."),
    ],
    explain: [
      C.p("SwitchListTile and DropdownButton write DIRECTLY into the ChangeNotifier — no form framework, no controller plumbing, no submit button. Because SettingsScope notifies, flipping a switch rebuilds every dependent, including a live table's pacing and audio. 'One object, shared by reference' is doing all the work."),
      C.p("The server URL is a TextField in settings because the app is developed against a local Go server — it's the config-file equivalent for a mobile app, where there's no env var to set. Keeping it in SettingsScope means every network session reads the same source of truth."),
      C.p("The profile's identity block (name, device id) is the visible seam between module 5 (local identity) and module 6 (server-side account): the profile screen will fetch history/statistics from the REST layer while the identity stays local."),
    ],
    alternatives: [
      { title: "A state-management package for settings", text: "Riverpod/Bloc would manage this same notifier. The scope IS the mechanism; packages add ergonomics (and dependencies). Your call — the app proves the hand-rolled version scales fine to this size." },
      { title: "Bottom sheet vs full screen", text: "Settings as a modal sheet (the app's choice) keeps the table context visible; a full screen page is better for long lists. Sheet is right for ~10 settings." },
    ],
    improve: [
      { title: "Debounce the server URL", text: "Every keystroke notifies the tree; a TextEditingController + onChanged debounce (300ms) keeps typing smooth if anything expensive listens." },
      { title: "Reachability test in settings", text: "A 'Test connection' button that hits /healthz and shows the result turns the server field from a blind guess into a tool. Great dev UX, cheap to build with the module 6 client." },
    ],
    activity: {
      type: "quiz",
      q: "A user flips the SFX toggle in the settings sheet. How does the audio controller know?",
      opts: ["It polls every second", "The shared AppSettings notifies; audio checks settings.sfxEnabled on each play", "A global event bus", "It doesn't"],
      correct: 1,
      explain: "One AppSettings instance, shared by reference; gating reads it live.",
    },
    done: ["Settings persist, and toggling a setting visibly changes behaviour."],
    refs: ["frontend/lib/ui/screens/settings_sheet.dart", "frontend/lib/ui/screens/profile_screen.dart"],
  }),
]));

REGISTER(C.module("m6", "♥", "REST Layer", "API client + models — comfort zone", [
  C.step("m6s1", "The contract first", {
    learn: [
      C.h("Two codebases, one spec"),
      C.p("The REST API is defined in backend/docs/API.md — the normative wire format. Both the Go server and the Dart client are written against it. The conventions matter more than the endpoints."),
    ],
    do: [
      C.p("Read backend/docs/API.md cover to cover. Before writing a line of Dart, write down the three conventions that shape everything:"),
      C.code("// 1. lowerCamelCase keys, RFC 3339 UTC timestamps\n// 2. errors are ALWAYS:  { \"error\": { \"code\": \"...\", \"message\": \"...\" } }\n// 3. the golden rule:\n//    Adding a field is SAFE (decoders read known keys, ignore the rest)\n//    Renaming/removing a field is BREAKING and needs a version bump", "json"),
      C.p("List the endpoints you'll need: guest login, /v1/me, match history, statistics. Note which need a bearer token."),
      C.p("Skim the error-code table (unauthorized, not_found, conflict, rate_limited, persistence_disabled...) and decide how each maps to a client behaviour."),
    ],
    explain: [
      C.p("The golden rule — additive fields are safe — is why the Dart decoders ignore unknown keys. It's a compatibility contract you get for free by writing lenient fromJson: the server can add a field in a new release and every old client keeps working. The mirror image is that you must NEVER reorder or rename a key without a version bump, because old clients will silently misread it."),
      C.p("A typed error envelope (<code>error.code</code>) is strictly better than HTTP numbers alone: the client switches on the code ('unauthorized' → prompt re-login) while the HTTP status stays the coarse outer layer. This is the API equivalent of typed exceptions over status codes."),
      C.p("The single-document discipline is the part worth copying at work: one normative spec, both sides written against it, and the client's contract test verifies against the LITERAL JSON in the doc (module 6.3). No drift between 'what the doc says' and 'what the code expects' — the test closes the loop."),
    ],
    alternatives: [
      { title: "OpenAPI / codegen clients", text: "Generate the Dart client from an OpenAPI spec. You lose the hand-written leniency story but gain automation — the right move when the API is large and stable. This project's API is 8 endpoints; hand-writing is fine." },
      { title: "GraphQL", text: "One typed query endpoint instead of REST. Overkill for a game client that fetches three shapes; REST + the envelope is simpler to reason about." },
    ],
    improve: [
      { title: "Version the contract explicitly", text: "The socket protocol carries v:2. Give the REST API the same explicit versioning (it lives under /v1) and document when /v2 appears — the spec file is where that decision gets recorded." },
      { title: "Add the contract test early", text: "The api_contract_test.dart pattern — feed the client the literal doc JSON — is so cheap and valuable that you should add it before the server exists. It turns the spec into an executable assertion." },
    ],
    activity: {
      type: "quiz",
      q: "Your server adds a new optional field to the user object. Old app clients will:",
      opts: ["Crash", "Silently ignore it — decoders read known keys only", "Show an error", "Refuse to log in"],
      correct: 1,
      explain: "Lenient fromJson ignores unknown keys; additive changes are non-breaking.",
    },
    done: ["You can state the three naming conventions and the golden rule."],
    refs: ["backend/docs/API.md", "frontend/lib/net/api_models.dart"],
  }),
  C.step("m6s2", "Hand-written models", {
    learn: [
      C.h("DTOs without codegen"),
      C.p("Every REST model is a plain class with a factory fromJson reading exactly the keys it knows. Deliberately no json_serializable/freezed — you can read, debug, and control leniency explicitly."),
    ],
    do: [
      C.p("Create <code>lib/net/api_models.dart</code> and write the User model with tolerant defaults:"),
      C.code("class User {\n  const User({required this.id, required this.displayName, required this.isGuest});\n  final String id;\n  final String displayName;\n  final bool isGuest;\n\n  factory User.fromJson(Map<String, dynamic> json) => User(\n    id: json['id'] as String,\n    displayName: json['displayName'] as String,\n    isGuest: json['isGuest'] as bool? ?? true,   // tolerant default\n  );\n}\n\nclass ErrorBody {\n  const ErrorBody({required this.code, required this.message});\n  final String code, message;\n\n  factory ErrorBody.fromJson(Map<String, dynamic> json) => ErrorBody(\n    code: json['code'] as String? ?? 'unknown',\n    message: json['message'] as String? ?? 'Something went wrong.',\n  );\n}", "dart"),
      C.p("Add the history/statistics models from the spec — gameSummary, statistics — with the same lenient reads."),
      C.p("Write a round-trip test for each: fromJson on a doc sample, assert fields; toJson and back, assert equality."),
    ],
    explain: [
      C.p("<code>as bool? ?? true</code> is lenient decoding in one line: tolerate a missing key with a sensible default. This is the discipline that makes additive server changes safe — you never throw on an absent field you can default."),
      C.p("The <code>factory ... fromJson</code> pattern with <code>Map&lt;String, dynamic&gt;</code> is what jsonDecode produces — you cast field by field, never auto-decode. It's verbose, and that verbosity is the point: every key is explicit, every default is a decision, and a schema change shows up as a compile error in exactly one file."),
      C.p("Hand-written equality isn't needed for DTOs — you never put a User in a Set. The engine's models (module 1.2) override ==; REST DTOs skip it. Different needs, different models — a useful instinct to keep: only build what the code actually does."),
    ],
    alternatives: [
      { title: "json_serializable codegen", text: "@JsonSerializable generates fromJson/toJson — less typing, one build_runner step, and codegen you can't read. The classic trade; this course has you hand-write first, then graduate to codegen when models multiply." },
      { title: "freezed", text: "freezed bundles immutable models + == + JSON. The ergonomic pinnacle, but it brings a codegen dependency graph. Reach for it when the DTO count outgrows the manual cost." },
    ],
    improve: [
      { title: "Keep decoders tolerant, always", text: "Never tighten a decoder to 'must have this key'. Tolerant reads are the compatibility contract — a strict decoder IS a breaking change in disguise." },
      { title: "Sample fixtures file", text: "Keep a fixtures/ folder of real API responses, and run the decoder over them in a test. Catches 'the server sends X but I assumed Y' before it reaches a user." },
    ],
    activity: {
      type: "code",
      starter: "// Write User.fromJson for a user with id, name, and an\n// optional integer score (default 0).\nclass User {\n  final String id, name;\n  final int score;\n\n  User({required this.id, required this.name, required this.score});\n\n  factory User.fromJson(Map<String, dynamic> json) =>\n      // your code\n      User(id: '', name: '', score: 0);\n}",
      checks: [
        CHK.has("reads id", "json\\['id'\\]\\s+as\\s+String", "Decode id with `json['id'] as String`."),
        CHK.has("reads name", "json\\['name'\\]\\s+as\\s+String", "Decode name."),
        CHK.has("default score", "json\\['score'\\].*\\?\\?\\s*0|\\?\\?\\s*0", "Tolerate a missing score with ?? 0."),
      ],
    },
    done: ["You can write a lenient fromJson by hand from the API spec."],
    refs: ["frontend/lib/net/api_models.dart"],
  }),
  C.step("m6s3", "The API client", {
    learn: [
      C.h("A typed HTTP client"),
      C.p("ApiClient wraps the http package: base URL, bearer token, typed endpoints, error mapping from the ErrorBody envelope. Constructor-injected, so tests hand it literal JSON instead of a live server."),
    ],
    do: [
      C.p("Create <code>lib/net/api_client.dart</code> with the base fetch helper and error mapping:"),
      C.code("class ApiClient {\n  ApiClient({required this.baseUrl, http.Client? httpClient})\n      : _http = httpClient ?? http.Client();\n\n  final String baseUrl;\n  final http.Client _http;\n  String? _token;\n\n  Future<Map<String, dynamic>> _getJson(String path) async {\n    final res = await _http.get(\n      Uri.parse('$baseUrl\$path'),\n      headers: {'Authorization': 'Bearer \$_token'},\n    );\n    final body = jsonDecode(res.body) as Map<String, dynamic>;\n    if (res.statusCode < 200 || res.statusCode >= 300) {\n      throw ApiException.fromErrorBody(\n        ErrorBody.fromJson((body['error'] as Map?) ?? const {}),\n        res.statusCode,\n      );\n    }\n    return body;\n  }\n\n  Future<User> me() async => User.fromJson(await _getJson('/v1/me'));\n}\n\nclass ApiException implements Exception {\n  final String code, message;\n  final int status;\n  ApiException.fromErrorBody(this.message, this.status, {this.code = ''});\n  bool get isUnauthorized => code == 'unauthorized';\n}", "dart"),
      C.p("Implement the guest login: POST /v1/auth/device with your deviceId, store the returned token in IdentityStore, set it on the client."),
      C.p("Add history() and statistics() endpoints per the spec."),
      C.p("Write the contract test: a mock http client that answers with the LITERAL JSON from the API doc — no server needed."),
    ],
    explain: [
      C.p("The injected <code>http.Client</code> is what makes the contract test work: the test substitutes a fake client that returns the exact JSON from backend/docs/API.md, and asserts the parsed models match. This is contract testing without a server — the spec becomes executable, and a doc change that the code misreads fails the test."),
      C.p("Error mapping happens in ONE place: every non-2xx becomes an ApiException carrying the error code. Callers branch on code, not status — <code>isUnauthorized</code> is the one branch the whole app cares about (re-login). There's no scattered 'if statusCode == 401' anywhere."),
      C.p("The token lives in IdentityStore (module 5) and is applied as a Bearer header per request. The store is the single source of truth, so login, re-login, and logout all reduce to 'write the token to the store'."),
    ],
    alternatives: [
      { title: "dio", text: "dio adds interceptors (logging, retry, auth refresh) on top of http. For 8 endpoints, plain http + a helper is cleaner; dio is the 'better way' when the API surface grows." },
      { title: "Retry with backoff", text: "A retry wrapper (like the socket's reconnect) belongs here for flaky networks: retry once on timeouts, never on 4xx. Cheap insurance you already know how to write." },
    ],
    improve: [
      { title: "Logging interceptor", text: "Wrap requests to log method/path/status in debug mode (kDebugMode). When the profile screen misbehaves against your server, the log IS the diff between what you sent and expected." },
      { title: "Timeout + cancellation", text: "Give every call a timeout and support cancellation when a screen unmounts. A hung request on a dead network should surface as an error, not a frozen spinner." },
    ],
    activity: {
      type: "quiz",
      q: "The contract test (api_contract_test.dart) verifies the client against what?",
      opts: ["A mock server", "The literal JSON examples in backend/docs/API.md", "The Go source", "A golden image"],
      correct: 1,
      explain: "It answers requests with the exact JSON from the API doc — a contract test without a server.",
    },
    done: ["Your client turns a 401 with code 'unauthorized' into a typed exception."],
    refs: ["frontend/lib/net/api_client.dart", "frontend/test/api_contract_test.dart"],
  }),
]));

REGISTER(C.module("m7", "♠", "WebSockets — Online Play", "the multiplayer heart", [
  C.step("m7s1", "The wire protocol", {
    learn: [
      C.h("One socket per player"),
      C.p("GET /ws, JSON text frames, server-authoritative. The server decides all state; the client renders views and sends intents. Private rooms keyed by a 4-char code, or quickplay (mode online, room QUICKPLAY) where the server matches you."),
    ],
    do: [
      C.p("Read backend/PROTOCOL.md cover to cover — the single most important document you'll read in this course."),
      C.p("Write out the client→server frame table and the server→client frame table by hand. Forgetting one of the four intents (join, bid, play, next + restart) will cost you a debug session:"),
      C.code("// Client → server (intents):\n{ \"type\": \"join\", \"v\": 2, \"room\": \"7QF2\", \"mode\": \"private\",\n  \"name\": \"Nabin\", \"guestToken\": \"...\", \"resumeToken\": \"...\" }\n{ \"type\": \"bid\",  \"bid\": 3 }\n{ \"type\": \"play\", \"card\": \"AS\" }       // wire ids: 'AS', '10H'\n{ \"type\": \"next\" }                        // leave the scoreboard\n\n// Server → client (state):\n{ \"type\": \"joined\", \"seat\": 1, \"guestToken\": \"...\", \"resumeToken\": \"...\" }\n{ \"type\": \"lobby\",  \"room\": \"7QF2\", \"seats\": [ ... ], \"canStart\": true }\n{ \"type\": \"view\",   ...the redacted GameView you built in module 2... }", "json"),
      C.p("Note the compatibility rules and explain why 'adding a field is safe' here too."),
    ],
    explain: [
      C.p("Server-authoritative means the client never mutates shared state — it REQUESTs (bid 3, play AS) and the server validates, applies, and broadcasts fresh redacted views. The redaction you built in module 2 is exactly what serializes over the wire: viewFor(seat) is the server's only way out of the engine."),
      C.p("guestToken vs resumeToken is the identity/seat split again: the guest token proves who you are (survives reconnects), the resume token reclaims a SPECIFIC seat after a drop. The client carries both in join; the server decides how far each one gets you."),
      C.p("The 4-char room code is a real constraint: ~1M combinations, small enough that two random rooms occasionally collide (~2% at 200 tables) and a determined stranger could find an open room by guessing. It matches what the client generates — lengthening it means changing both sides together. A documented trade, not a bug."),
    ],
    alternatives: [
      { title: "Protobuf/MessagePack over the socket", text: "Binary framing would shrink frames and add schema codegen. JSON text frames are debuggable (read them in your server logs) and fine at this frame rate. The 4096-byte frame cap keeps abuse in check." },
      { title: "SSE / long-polling", text: "Server-sent events one-way + POST intents would work without a socket library, but half-duplex and chatty. WebSocket is the honest choice for an interactive game." },
    ],
    improve: [
      { title: "Add a schema version to join", text: "The protocol already carries v:2 and refuses newer clients with unsupported_version. When you bump to v3, the guard is already in place — document the migration in PROTOCOL.md as you go." },
      { title: "Frame budget on the client", text: "The server rate-limits (MSG_RATE_PER_SECOND). The client should throttle its own ping/pong and never send 'spam' frames — a cooperative client keeps the server's budgets sane." },
    ],
    activity: {
      type: "quiz",
      q: "In 'server-authoritative', when a client wants to play a card it:",
      opts: ["Locally updates the game and tells everyone", "Sends a play frame and waits for the server's next view", "Directly mutates the shared state", "Waits for a lobby frame"],
      correct: 1,
      explain: "The client requests; the server validates, updates, and broadcasts the new redacted view.",
    },
    done: ["You can name the four client intents and two token types."],
    refs: ["backend/PROTOCOL.md", "frontend/lib/net/remote_session.dart"],
  }),
  C.step("m7s2", "Lobby: filling the table", {
    learn: [
      C.h("Before the deal"),
      C.p("A private table sits in a lobby until the host starts it; quickplay deals itself once enough humans arrive. NetworkSession exposes LobbyState — who's here, can the host start, the countdown."),
    ],
    do: [
      C.p("Model the lobby — NetworkSession's added surface on top of GameSession:"),
      C.code("class LobbyState {\n  final String roomCode;\n  final bool isOnline;         // quickplay vs invite-only\n  final List<LobbySeat> seats;\n  final bool isHost;\n  final bool canStart;\n  final int humansSeated;\n  final int minPlayers;        // quickplay needs N humans before dealing\n  final int handsPerGame;\n\n  int get stillNeeded {\n    final missing = minPlayers - humansSeated;\n    return missing > 0 ? missing : 0;\n  }\n  bool get isWaitingForPlayers => isOnline && stillNeeded > 0;\n}", "dart"),
      C.p("Add the lobby intents to NetworkSession: startGame (private, host only), leaveLobby, setHandsPerGame, countdown."),
      C.p("Render the lobby in the table screen: <code>session.lobby != null</code> switches the UI from 'waiting room' to 'table'."),
      C.p("Implement quickplay room creation: join with mode online + room QUICKPLAY; show 'waiting for N more players' from lobby.stillNeeded."),
    ],
    explain: [
      C.p("Quickplay seats you at a REAL table the moment you arrive — there's no anonymous queue. You see your table-mates in the lobby, and the table deals itself on a countdown once <code>minPlayers</code> humans are present, filling empty seats with bots at deal time. The lobby state's <code>isWaitingForPlayers</code> getter is what the UI reads to decide whether to show 'waiting…'."),
      C.p("Private tables invert the control: the HOST presses start, and bots fill any empty seats. <code>canStart</code> is only true on the host's screen — the server enforces that, not the client's optimism."),
      C.p("The lobby is part of NetworkSession, NOT GameSession, because offline play has no lobby. The table screen checks <code>lobby != null</code> to decide which mode it's in — the interface split (module 4.1) keeps the offline table code completely unaware of lobbies."),
    ],
    alternatives: [
      { title: "A separate LobbyScreen widget", text: "A distinct screen for the lobby (instead of a phase inside TableScreen) is arguably cleaner. The app renders it inside the table's Stack so the felt shows behind — a product choice about how 'in the room' you feel." },
      { title: "Anonymous matchmaking queue", text: "Hold players in an opaque queue and only reveal seats at deal. The design deliberately seats people visibly — strangers see each other filling in, which is friendlier than a black box." },
    ],
    improve: [
      { title: "Room code sharing", text: "A 'Copy room code' button plus a share sheet (share_plus) turns the invite flow into one tap. The code is the product's whole invitation mechanism — make it a first-class citizen." },
      { title: "HandsPerGame negotiation", text: "The lobby lets host and players agree on 3 vs 5 hands before the deal (setHandsPerGame). Resolving conflicts politely (host wins, everyone sees it) is a small but real UX decision." },
    ],
    activity: {
      type: "quiz",
      q: "On a quickplay table, who presses Start?",
      opts: ["The host", "Nobody — it deals itself once minPlayers are present", "The first player", "The server admin"],
      correct: 1,
      explain: "Quickplay is hostless: the table deals on a countdown when enough humans are seated.",
    },
    done: ["You can explain the difference between private-start and quickplay self-deal."],
    refs: ["frontend/lib/net/session.dart (LobbyState, NetworkSession)", "frontend/test/join_sheet_test.dart"],
  }),
  C.step("m7s3", "RemoteSession basics", {
    learn: [
      C.h("A GameSession over a socket"),
      C.p("RemoteSession extends NetworkSession (which extends GameSession). It connects, sends join, receives joined/lobby/view frames, forwards intents as frames, and re-emits view events so the table screen's sounds/animations just work."),
    ],
    do: [
      C.p("Create <code>lib/net/remote_session.dart</code>. Start with connect + the frame router:"),
      C.code("class RemoteSession extends NetworkSession {\n  WebSocketChannel? _ws;\n  StreamSubscription? _sub;\n  GameView? _view;\n  LobbyState? _lobby;\n\n  Future<void> connect() async {\n    _ws = WebSocketChannel.connect(Uri.parse(_serverUrl));\n    _sub = _ws!.stream.listen(_onFrame, onDone: _onClosed);\n    _send({'type': 'join', 'v': 2, 'room': _room, 'mode': _mode.name,\n            'name': _settings.playerName, 'guestToken': _identity.guestToken,\n            'resumeToken': _resumeToken});\n  }\n\n  void _onFrame(dynamic raw) {\n    final frame = jsonDecode(raw as String) as Map<String, dynamic>;\n    switch (frame['type']) {\n      case 'joined':  _joined(frame);\n      case 'lobby':   _lobby = LobbyState.fromJson(frame); notifyListeners();\n      case 'view':    _applyView(GameView.fromJson(frame));\n      case 'error':   _onServerError(frame);\n    }\n  }", "dart"),
      C.p("Implement the intents as thin frame senders — <code>play(card)</code> sends <code>{type:'play', card: card.id}</code>, etc."),
      C.p("Implement _applyView: convert the server deadline once (clock-skew anchor, module 4.6), re-emit the view's events, notifyListeners."),
      C.p("Implement _onServerError — including the redirect code: <code>error{code:'redirect', endpoint}</code> means the room lives on another node; reconnect there."),
    ],
    explain: [
      C.p("The frame router is the socket-side mirror of your sealed GameEvent switch: switch on frame['type'], handle each case. Same discipline, different transport. The four inbound frames (joined, lobby, view, error) are the only things that change client state."),
      C.p("_applyView is where the redacted GameView from module 2 comes home: <code>GameView.fromJson(frame)</code> reconstructs the typed view the table renders. The clock-skew conversion (module 4.6) runs here, once per view, so deadlines stay honest on a device whose clock is minutes off the server's."),
      C.p("The redirect error frame is the horizontal-scaling story in one frame: with Redis enabled, a client that hits the wrong node gets told where to go. The load balancer hashing on ?room= avoids most redirects — the client just needs to handle the instruction gracefully."),
    ],
    alternatives: [
      { title: "A reactive layer over the socket", text: "Packages (web_socket_channel's higher-level helpers, or socket.io clients) abstract reconnect/heartbeat. Hand-rolling here teaches the protocol; a package is the 'better way' when you'd rather not own it." },
      { title: "Full-duplex binary frames", text: "Binary frames with a 1-byte type tag would halve bandwidth. JSON keeps frames human-readable in server logs — worth more during development than the saved bytes." },
    ],
    improve: [
      { title: "Backpressure-aware sends", text: "If the socket backs up, drop the oldest ping rather than queue unbounded frames. The server's rate budget already defends it; the client's outbound queue should too." },
      { title: "kDebugMode frame logger", text: "Log every outbound/inbound frame under kDebugMode. The wire-contract test verifies shape; the logger verifies your actual server traffic reads the way you think." },
    ],
    activity: {
      type: "code",
      starter: "// Simulate the frame router: a function handleFrame(map)\n// that switches on frame['type'] for 'joined'/'lobby'/'view'/'error'.\nvoid handleFrame(Map<String, dynamic> frame) {\n  // your code\n}",
      checks: [
        CHK.has("switch", "switch\\s*\\(", "Switch on the type."),
        CHK.count("cases", "case\\s+['\"]", 4, "Handle joined, lobby, view, error."),
        CHK.has("reads type", "frame\\['type'\\]", "Read frame['type']."),
      ],
    },
    done: ["You can trace a join → joined → lobby → view round trip."],
    refs: ["frontend/lib/net/remote_session.dart", "frontend/test/wire_contract_test.dart"],
  }),
  C.step("m7s4", "Reconnect & resume", {
    learn: [
      C.h("A drop must not lose your seat"),
      C.p("If your socket dies mid-game, reconnecting as a NEW player would lose your seat. Instead: the session keeps the resume token, the server holds the seat for a grace window, and on reconnect the app sends resumeToken to reclaim it. The active-game binding persists 'I'm mid-game' so even a cold app restart offers 'Rejoin your game?'."),
    ],
    do: [
      C.p("Persist the active game — room, seat, resumeToken, mode — via a small ActiveGameBinding store (module 5's prefs wrapper) whenever a game starts:"),
      C.code("// persisted on start:\n{ room: '7QF2', seat: 2, resumeToken: '...', mode: 'private' }", "json"),
      C.p("Implement the backoff-reconnect loop in _onClosed — your standard retry policy, on a socket:"),
      C.code("void _onClosed() {\n  _status = SessionStatus.connecting;\n  _retryTimer = Timer(\n    Duration(milliseconds: 800 * (1 << _retries)),   // exponential backoff\n    () => _reconnect(),\n  );\n}\n\nFuture<void> _reconnect() async {\n  await connect();                                  // new socket\n  _send({'type': 'join', 'v': 2, 'room': _room, 'mode': _mode.name,\n         'resumeToken': _resumeToken});             // reclaim the seat\n}", "dart"),
      C.p("Expose canResume / seatHeldFor so the home screen can render 'Rejoin your game?' after a cold start."),
      C.p("Wire retryNow() and the manual 'Try again' button for a first-connect failure that never got in."),
    ],
    explain: [
      C.p("Exponential backoff — 800ms × 2^n — is exactly the retry policy you'd write for a flaky upstream, now applied to a socket. The cap and the reset-on-success matter as much as the formula: never hammer a dead server forever, and once you reconnect, reset the counter."),
      C.p("The resume token is a CAPABILITY, not a password: the server honours it only while the seat still belongs to that player and within RECONNECT_GRACE (2m default). Possession + ownership + time window. That's the anti-theft guarantee — a stolen token can't take someone else's seat, and a stale one can't squat forever."),
      C.p("Reclaiming also cancels autoplay (module 7.5): when your seat was being played for you during the drop, reconnecting takes it back. The joined frame's resumeToken re-issues, so the capability rotates on every reconnect."),
    ],
    alternatives: [
      { title: "Persistent connection layer", text: "A reconnection library (or socket.io semantics) manages backoff for you. Hand-rolling it here shows you the mechanics — and you control the resume-token flow, which libraries don't know about." },
      { title: "Reconnect on next launch", text: "Instead of mid-session retries, you could only attempt reclaim on the next app launch. The in-session backoff is what makes the experience seamless; the launch-time path is its cold-start sibling." },
    ],
    improve: [
      { title: "Backoff jitter", text: "Add random jitter to the backoff so many clients reconnecting together don't synchronize into thundering-herd retries. The classic distributed-systems fix, now justified on phones too." },
      { title: "Show seat-held status", text: "The UI already exposes seatHeldFor — surface it as a countdown so a player whose seat is about to be released knows they must hurry back." },
    ],
    activity: {
      type: "quiz",
      q: "Why does the app keep a resumeToken instead of just reconnecting?",
      opts: ["To avoid re-login", "To reclaim the exact seat the player held, even after a cold restart", "To keep the socket open", "To skip the lobby"],
      correct: 1,
      explain: "A reconnect is a new player; a resume reclaims the seat by token.",
    },
    done: ["You can explain the difference between reconnect and resume."],
    refs: ["frontend/lib/net/remote_session.dart", "frontend/lib/state/active_game_binding.dart"],
  }),
  C.step("m7s5", "Autoplay & wakeUp", {
    learn: [
      C.h("The dead-man's switch"),
      C.p("When a human stops responding, the server plays for them so the table doesn't stall. The player still owns the seat — any tap sends awake, cancelling autoplay and taking the seat back."),
    ],
    do: [
      C.p("Make every tap on the table a wake-up call — cheap, idempotent, safe to repeat:"),
      C.code("// TableScreen, on any tap:\nvoid _onAnyTap() {\n  widget.session.wakeUp();   // 'I'm still here' — cancels autoplay if any\n}\n\n// GameSession.wakeUp() default is a no-op — sessions with no server\n// to tell simply ignore it. RemoteSession sends { type: 'awake' }.", "dart"),
      C.p("Render autoplay honestly: PlayerInfo.autoplay flips a seat badge to 'Playing for you' — the server drives that seat, and everyone can see it."),
      C.p("Handle the reclaim moment: when the server hands your seat back (view shows autoplay false again), restore the turn clock and any paused UI."),
    ],
    explain: [
      C.p("Autoplay is the dead-man's switch that keeps a networked table alive when a phone's Wi-Fi blips. The server's own bot brain (the Go port of module 4.2) plays legal moves for the silent seat, so the game advances honestly. The player isn't kicked — their seat is held for the grace window."),
      C.p("wakeUp must be idempotent and side-effect-free because it fires on EVERY tap — sending it fifty times in a row is harmless. The server treats the first awake as 'stop autoplay' and ignores the rest. That's the same idempotency discipline as a POST that's safe to repeat."),
      C.p("Honesty in the UI is the design point: autoplay is a visible badge, not a secret. Everyone at the table knows the server is driving seat 2, which is what makes the feature feel fair rather than sneaky."),
    ],
    alternatives: [
      { title: "Kick after timeout", text: "The harsher alternative: drop the seat after N seconds and let a stranger take it. Autoplay is friendlier and keeps the match intact; kicking suits ranked/competitive modes where a missing player poisons the table." },
      { title: "Time-bank per player", text: "A per-player time bank (chess clocks) penalizes slow play without autoplay. It's the tournament-grade answer; autoplay is the casual answer this app ships." },
    ],
    improve: [
      { title: "Surface the grace window", text: "Tell the autoplayed player's OWN screen 'your seat is safe, tap to resume' with the remaining grace time — turning a scary disconnect into a calm prompt." },
      { title: "Autoplay difficulty from settings", text: "Let the host pick which bot difficulty autoplays at. A hard-autoplay table is a different (meaner) experience than a gentle one — a settings-driven dial." },
    ],
    activity: {
      type: "quiz",
      q: "A player's Wi-Fi blips for 30 seconds and the server autoplays their turn. What happens the moment they tap the table again?",
      opts: ["Nothing — they've lost the seat", "wakeUp cancels autoplay and they resume", "They're kicked to the lobby", "Autoplay continues"],
      correct: 1,
      explain: "Any tap sends wakeUp; the server cancels autoplay and the player is back.",
    },
    done: ["You can explain why wakeUp must be idempotent."],
    refs: ["frontend/lib/net/session.dart (wakeUp)", "backend/PROTOCOL.md (awake frame)"],
  }),
]));
