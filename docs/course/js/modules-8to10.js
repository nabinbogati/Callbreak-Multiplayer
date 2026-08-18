/* Build Call Break — modules 8-11: LAN host, upload queue, Go backend, deploy. */

REGISTER(C.module("m8", "♣", "LAN Host Mode", "your phone becomes the server", [
  C.step("m8s1", "A server inside the app", {
    learn: [
      C.h("dart:io in a Flutter app"),
      C.p("The host mode turns one device into a mini game server for friends on the same Wi-Fi. It reuses the SAME engine + bot pacing as LocalSession, but also drives remote human seats over a WebSocket server listening on dart:io — no internet, no backend, no cloud."),
    ],
    do: [
      C.p("Bind a WebSocket server on the host device — dart:io is available in the app, not just on servers:"),
      C.code("import 'dart:io';\n\nfinal server = await HttpServer.bind(InternetAddress.anyIPv4, 8180);\nawait server.forEach((HttpRequest req) async {\n  if (WebSocketTransformer.isUpgradeRequest(req)) {\n    final ws = await WebSocketTransformer.upgrade(req);\n    hostSession.attach(ws);    // each guest becomes a seat on this table\n  }\n});", "dart"),
      C.p("Build LanHostSession as a GameSession that owns the engine and bot brains — the LocalSession shape — plus a WebSocket per guest:"),
      C.code("class LanHostSession extends GameSession {\n  final CallBreakGame _game = ...;     // the module-2 engine\n  final List<BotBrain?> _brains = ...; // the module-4 bots\n  // ...plus a WebSocket per guest seat, listening like RemoteSession\n  // but on the other side of the socket.\n}", "dart"),
      C.p("Reuse the exact protocol frames — the guest app's RemoteSession connects to this host the same way it connects to the Go server."),
      C.p("Test the four-seat flow with scripts/launch_multi_instance.sh — several app copies on one machine, playing every seat yourself."),
    ],
    explain: [
      C.p("This is the payoff of module 2's purity: the engine, the bots, the pacing, and the protocol are all shared. The only thing that changes is the transport direction — LocalSession drives bots with Timers, LanHostSession drives bots AND remote humans over sockets. One engine to rule all three modes."),
      C.p("The host is effectively an embedded Go server, minus the Go: same frames, same seats, same redaction. That's why the guest app doesn't need a separate 'LAN mode' implementation — RemoteSession speaks the protocol to whatever listens."),
      C.p("Running the server INSIDE the app is the constraint that keeps LAN mode honest: the host's phone is the whole datacenter, so pacing (module 4.6) and seat management happen on a device, not a rack. It's a great lesson in what the Go server abstracts away."),
    ],
    alternatives: [
      { title: "A real server on the LAN", text: "Run the Go server on a laptop and have phones connect to its IP. Same protocol, no dart:io needed — but requires a machine and setup. LAN host mode is the zero-infrastructure version: one phone hosts the table." },
      { title: "Multipeer connectivity", text: "Apple's MultipeerConnectivity (nearby.device or similar) handles peer discovery natively. The UDP broadcast + WebSocket approach is platform-neutral and uses the same protocol as the Go server — a better fit for a Flutter app." },
    ],
    improve: [
      { title: "Host leaves gracefully", text: "When the host app backgrounds or dies, tell every guest 'table closed' and return them to the home screen. The reconnect story (module 7.4) doesn't apply — there's no server to reconnect to." },
      { title: "Cap guests + handshake", text: "Reject a 5th connection with a friendly frame, and validate the join's mode/version like the Go server does. A phone-server needs the same guards, just smaller." },
    ],
    activity: {
      type: "quiz",
      q: "Which parts of the app does LAN host mode reuse rather than reinvent?",
      opts: ["Only the UI", "The engine, the bots, and the wire protocol", "The Go server", "Nothing"],
      correct: 1,
      explain: "The whole game core is shared; only the transport (a listening socket vs a connecting one) differs.",
    },
    done: ["You can explain what moves into the app and what stays shared."],
    refs: ["frontend/lib/net/lan_host_session.dart", "frontend/lib/net/local_session.dart"],
  }),
  C.step("m8s2", "UDP discovery", {
    learn: [
      C.h("No IPs to type"),
      C.p("Guests shouldn't type the host's IP. The host broadcasts its presence on the local network over UDP; guests listen and show 'Table found'. Same Wi-Fi, zero config."),
    ],
    do: [
      C.p("Host side — broadcast a discovery beacon every second:"),
      C.code("final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);\nsocket.broadcastEnabled = true;\nTimer.periodic(Duration(seconds: 1), (_) {\n  final msg = utf8.encode('CALLBREAK:\$tableName');\n  socket.send(msg, InternetAddress('255.255.255.255'), kLanDiscoveryPort);\n});", "dart"),
      C.p("Guest side — listen for the beacon and extract the host's address:"),
      C.code("final listener = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kLanDiscoveryPort);\nlistener.listen((event) {\n  if (event == RawSocketEvent.read) {\n    final datagram = listener.receive();\n    if (datagram != null && utf8.decode(datagram.data).startsWith('CALLBREAK:')) {\n      // found a table -> connect over WebSocket to datagram.address\n    }\n  }\n});", "dart"),
      C.p("Wire the found-table callback to create a RemoteSession pointed at the host's address."),
    ],
    explain: [
      C.p("UDP is fire-and-forget discovery; the GAME rides the reliable WebSocket. The split is a correctness argument: a lost discovery packet is harmless (the host repeats it every second), but a lost play frame breaks the trick. Discovery is allowed to be lossy precisely because it self-heals — the same reason DNS uses UDP and TCP carries the actual data."),
      C.p("Broadcasting to 255.255.255.255 reaches the whole subnet — right for one Wi-Fi network. The beacon is a plain UTF-8 prefix ('CALLBREAK:'), trivially debuggable in a packet dump, and carries just enough info for a guest to connect to the right WebSocket port."),
      C.p("This is the last network primitive you learn: UDP for presence, WebSocket for state. Between them you've covered the full transport toolbox a mobile game needs."),
    ],
    alternatives: [
      { title: "mDNS/Bonjour", text: "mDNS (via multicast_dns package) is the standards-track discovery protocol with name service. The app's bespoke UDP beacon is simpler and needs no package; mDNS is the 'better way' when many hosts or structured names appear." },
      { title: "QR code pairing", text: "Show a QR containing ws://host-ip:port; guests scan it. The most reliable fallback when multicast is blocked on a guest's network (some routers isolate clients)." },
    ],
    improve: [
      { title: "In-network listing with names", text: "Include the host's table name and player count in the beacon so the guest UI can render 'Nabin's table (2/4)' before connecting — richer discovery for free." },
      { title: "Discovery expiry", text: "Drop a found-table entry if its beacon stops arriving (e.g. 5s of silence). Stale entries are how 'found' lists rot; expiry is three lines." },
    ],
    activity: {
      type: "quiz",
      q: "Why is discovery over UDP while the game itself is over WebSocket?",
      opts: ["UDP is faster for cards", "Discovery is loss-tolerant and repeats; the game needs reliability", "WebSocket can't do LAN", "They're the same thing"],
      correct: 1,
      explain: "One lost discovery packet is harmless (it repeats); one lost play frame breaks the trick.",
    },
    done: ["You can explain the split: lossy discovery, reliable play."],
    refs: ["frontend/lib/net/lan_discovery.dart"],
  }),
]));

REGISTER(C.module("m9", "♢", "Offline Upload Queue", "write-behind, idempotent", [
  C.step("m9s1", "Record as you play", {
    learn: [
      C.h("The outbox pattern"),
      C.p("Bots and LAN games are played entirely on the device, so the device is the only one who knows the result. A GameRecorder inside LocalSession consumes the engine's events and builds an upload payload. At GameOver it hands the payload to a queue that flushes when the network allows. Fire-and-forget — a dead connection must never slow the table."),
    ],
    do: [
      C.p("Create a GameRecorder that consumes the events you built in module 2.7. The critical snapshot moment is HandOver — the engine clears that hand's bids/tricks on the next deal:"),
      C.code("void _record(GameEvent event) {\n  final recorder = _recorder;\n  if (recorder == null) return;\n\n  switch (event) {\n    case HandOver(): {\n      recorder.recordHand(\n        handIndex: event.handIndex,\n        bids: _game.bids,            // snapshot NOW — next deal clears them\n        tricksWon: _game.tricksWon,\n        deltas: event.deltas,\n      );\n    }\n    case GameOver(): {\n      _recorder = null;\n      final payload = recorder.build(\n        players: _game.players, totals: _game.totals,\n        rankings: event.rankings, handsTotal: _game.totalHands,\n      );\n      final uploader = GameUploader.instance;\n      if (payload != null && uploader != null) {\n        unawaited(uploader.enqueue(payload));   // fire-and-forget\n      }\n    }\n    default: break;\n  }\n}", "dart"),
      C.p("Hook _record into LocalSession._publish, before the events fan out to the UI."),
    ],
    explain: [
      C.p("Snapshotting AT HandOver is an ordering contract: the engine is about to reset per-hand state when the next hand deals, so the recorder must take bids/tricksWon the instant the hand ends — before that state is gone. Miss the moment and the hand is permanently unrecoverable."),
      C.p("The engine stays pure: it emits the HandOver event with the deltas; the recorder (a host-layer collaborator) decides what to capture. Same separation of concerns you've been practicing — the uploader is a consumer of the same event log the UI animates."),
      C.p("unawaited() is deliberate: enqueuing never blocks the table, online or off. Your write-behind queue instinct from backend work applies verbatim — the game finishes exactly as fast on a plane as on Wi-Fi."),
    ],
    alternatives: [
      { title: "Upload at hand, not at game", text: "Send each hand as it completes instead of one payload per game. The batch-per-game shape is simpler for the server (one idempotency key, one transaction) — hand-by-hand would multiply the retry surface." },
      { title: "Record in the engine", text: "The engine could keep its own history. It deliberately doesn't — the recorder keeps the engine portable to Go, where the SERVER records instead." },
    ],
    improve: [
      { title: "Redact before upload", text: "The payload goes to your server, which stores it. Decide what's personal (names? device id?) and trim before it leaves the device — privacy by default." },
      { title: "Record replays", text: "The completedTricks list (module 2.5) holds every trick. Extending the recorder to include them enables a future 'watch your last game' feature — the data is already there." },
    ],
    activity: {
      type: "quiz",
      q: "Why does the recorder snapshot bids/tricksWon at HandOver instead of at the end?",
      opts: ["The engine clears them when the next hand deals", "It's more efficient", "Bids change later", "Uploads need them immediately"],
      correct: 0,
      explain: "The engine's per-hand state resets on the next deal — snapshot at the moment it's still intact.",
    },
    done: ["You can explain when each hand's data must be captured."],
    refs: ["frontend/lib/net/local_session.dart (_record)", "frontend/test/game_upload_test.dart"],
  }),
  C.step("m9s2", "Queue + idempotency", {
    learn: [
      C.h("No double records"),
      C.p("Each game mints an id at DEAL time, before the first card. The upload queue stores pending payloads; when the app starts online it flushes them. If a retry is interrupted and re-sent, the server matches the game id and refuses to record twice. That id is the whole anti-duplication story."),
    ],
    do: [
      C.p("Build GameUploader — a queue that persists its backlog and flushes on launch:"),
      C.code("class GameUploader {\n  static GameUploader? instance;\n\n  static Future<void> install(GameUploader u) async {\n    instance = u;\n    unawaited(u.flush());   // pending games go out on every launch\n  }\n\n  Future<void> enqueue(GameUploadPayload payload) async {\n    _pending.add(payload);\n    await _persist();          // survives the process dying mid-queue\n    await _tryFlushOne(payload);\n  }\n\n  Future<void> _tryFlushOne(GameUploadPayload p) async {\n    try {\n      await _client.uploadGame(p);\n      _pending.remove(p);\n      await _persist();\n    } catch (_) {\n      // leave it queued; the next launch retries\n    }\n  }\n}", "dart"),
      C.p("Mint the game id once at deal time in LocalSession (Random.secure is enough — module 5's device-id trick):"),
      C.code("// id minted when the game starts, before the first card:\n_recorder = GameRecorder(mode: mode, youSeat: humanSeat)\n  ..gameId = newId();   // stable for the whole game, every retry same id", "dart"),
      C.p("Persist the pending list with the module 5 prefs wrapper so a killed process doesn't lose the queue."),
      C.p("On the server side, record the id as a unique key — the second upload of the same id is a no-op (see docs/PERSISTENCE.md §4.1)."),
    ],
    explain: [
      C.p("This is the outbox pattern from your backend world, moved into the app: writes go to a durable local queue first, and a flusher retries against the network. The game id is the idempotency key — minted ONCE at deal, carried unchanged by every retry, and unique on the server. Without it, a retried upload after a network blip would double-record."),
      C.p("Enqueue-then-flush means the failure mode is always safe: enqueue to the durable list, try to flush, and on failure just leave it queued. There is no state in which a game is recorded before the player saw the result, and none in which a finished game is silently lost forever."),
      C.p("The id lives on the recorder, which is replaced on restart() — so each game gets its own idempotency key exactly once. The same key can't accidentally dedupe two different games."),
    ],
    alternatives: [
      { title: "A generic offline-first store", text: "Hive or a local SQLite as the queue store would scale to more shapes than prefs' key-value. For one bounded list of payloads, prefs is honest and debuggable." },
      { title: "Background isolate upload", text: "Uploading in an isolate (or via background fetch) would let the queue flush while the app is closed. WorkManager/background_fetch is the 'better way' for larger offline-first ambitions; this app flushes on launch, which covers the common case." },
    ],
    improve: [
      { title: "Inspect the queue in settings", text: "A 'pending uploads: 3' line in the profile screen turns a silent queue into something you can reason about — and a 'Retry now' button gives the user agency." },
      { title: "Bound the queue size", text: "A cap (e.g. 20 games) with oldest-dropped-first prevents a long offline streak from unbounded growth. Decide the cap consciously." },
    ],
    activity: {
      type: "quiz",
      q: "When is the game id that guarantees no-double-upload created?",
      opts: ["At upload time", "At DEAL time, before the first card", "At app launch", "By the server"],
      correct: 1,
      explain: "Mint the id once at deal so every retry of the same game carries the same id.",
    },
    done: ["Offline games appear in server history exactly once."],
    refs: ["frontend/lib/net/game_uploader.dart", "backend/docs/PERSISTENCE.md §4.1"],
  }),
]));

REGISTER(C.module("m10", "⚙", "The Go Backend", "your home turf — build it your way", [
  C.step("m10s1", "Architecture in one page", {
    learn: [
      C.h("The actor model, done in Go"),
      C.p("Read backend/README.md first — the best architecture note in this repo. The headline: a table is an actor. Each room is ONE goroutine owning its engine, seats, timers and client handles. Nothing outside touches that state; callers post messages to an inbox and the actor applies them in order. Turn ordering correct by construction, no locks on the hot path."),
    ],
    do: [
      C.p("Map the package layout — this is your feature checklist:"),
      C.code("//   cmd/server    wiring: config -> deps -> HTTP -> graceful drain\n//   internal/engine  the rules, ported from frontend/lib/engine/\n//   internal/bot     the opponent, ported from frontend/lib/bots/bot.dart\n//   internal/room    one goroutine per table, owning all of its state\n//   internal/match   quickplay seating\n//   internal/ws      websocket edge: upgrade, auth, validate, route\n//   internal/protocol  every frame that crosses the wire\n//   internal/auth   guest identities and seat resume tokens\n//   internal/store  optional Redis room registry\n//   internal/obs    logging, metrics, health", "go"),
      C.p("Write the room's run loop — a goroutine reading an inbox channel:"),
      C.code("func (r *Room) Run(ctx context.Context) {\n  for {\n    select {\n    case msg := <-r.inbox:\n      r.apply(msg)      // one message at a time — no locks needed\n    case <-ctx.Done():\n      r.close()\n      return\n    }\n  }\n}", "go"),
      C.p("Make the room recover panics: a panic costs ONE table (tell its players, close), never the process."),
    ],
    explain: [
      C.p("The actor model is the concurrency answer for a game server: one goroutine per table owns ALL the mutable state, so there is no shared memory and therefore no locking. Turn ordering is correct by construction — the leader's play is applied before the next seat's, because the actor applies messages serially. Your mutex intuition goes quiet here; the channel IS the synchronization."),
      C.p("A room is a few KB resident, so the ceiling on tables per node is websocket fan-out, not game logic. 50,000 rooms is a config knob (MAX_ROOMS), not a hardware prayer — the actor model is what makes that density safe."),
      C.p("The panic-recovery wrapper is the resilience posture: a room bug degrades one table, tells those four players, and leaves the other 49,999 alone. That's your recover-per-request pattern from HTTP servers, applied per-table."),
    ],
    alternatives: [
      { title: "Mutex-guarded game objects", text: "A single game object with a RWMutex would work at this scale. The actor model wins on ordering guarantees and removes the lock-convention discipline entirely — you can't forget to lock what nobody else can touch." },
      { title: "A library framework (centrifugo/nats-based)", text: "Building on a message bus or a game-server framework buys routing but constrains your protocol. One binary, own protocol, own actor loop is the most learnable and the most yours." },
    ],
    improve: [
      { title: "Observability from day one", text: "The metrics that matter (rooms_active, players_connected, turn_timeouts_total) are named in the README. Instrument them as you build each subsystem, not after — retrofitting metrics is archaeology." },
      { title: "Drain, don't drop", text: "SIGTERM should stop accepting, tell every table it's going away, wait SHUTDOWN_GRACE, then exit. Graceful drain is the production discipline that separates a hobby server from a deployable one." },
    ],
    activity: {
      type: "quiz",
      q: "Why does the room use a single-owner goroutine instead of mutex-protected state?",
      opts: ["Goroutines are free", "Serial ownership makes turn ordering correct by construction and keeps locks off the hot path", "Go forbids mutexes", "Channels are faster"],
      correct: 1,
      explain: "Actor model: one owner, inbox messages, ordering is trivial and safe.",
    },
    done: ["You can explain the actor-per-table design and its two benefits."],
    refs: ["backend/README.md", "backend/internal/room"],
  }),
  C.step("m10s2", "Port the engine", {
    learn: [
      C.h("One implementation of the rules, two languages"),
      C.p("internal/engine is a faithful Go port of the Dart engine. The rule that keeps them honest: internal/engine's tests are ported case-for-case from frontend/test/engine_test.dart. If they ever disagree, the client and server disagree about the rules — the one bug class this project cannot afford."),
    ],
    do: [
      C.p("Port card.dart's types first — Suit, Card, the wire id format ('AS', '10H'):"),
      C.code("// Dart:\nString get id => '\$label\${suit.code}';   // 'AS', '10H'\n\n// Go:\ntype Card struct{ Rank int; Suit Suit }\nfunc (c Card) ID() string { return c.RankLabel() + c.Suit.Code() }\n\n// The wire format must byte-for-byte match — both sides parse it.", "go"),
      C.p("Port legalMoves, trickWinner, scoreHand, estimateTricks from rules.dart — mechanically, not as a redesign:"),
      C.code("// Dart:\nif (trick.isEmpty) return [...hand];\n// Go:\nif len(trick) == 0 {\n  return append([]Card(nil), hand...)\n}", "go"),
      C.p("Port the test cases from engine_test.dart case-for-case. Same assertions, both languages."),
      C.p("Port the redaction invariant: ViewFor(seat) is the only way state leaves the engine, and a test asserts no other seat's card ids appear anywhere in the serialized view."),
    ],
    explain: [
      C.p("'Port mechanically, don't redesign' is the rule because the Dart version is TESTED. A redesign forfeits the test suite — you'd be shipping rules you believe are equivalent. Line-by-line porting plus the same test cases is how you keep the two suites in lockstep."),
      C.p("The wire format is the shared contract: 'AS' must mean the same card in Dart and Go, so the port defines Card with the same ID() encoding and the same parse. The compatibility rules from the protocol (additive fields safe) flow from here — both sides know what a frame is."),
      C.p("The redaction invariant is the security guarantee ported whole: ViewFor(seat) hands out your own cards and everyone else's count — nothing else. A test on BOTH sides asserts no other seat's card ids appear anywhere. Cheating in multiplayer dies at this boundary."),
    ],
    alternatives: [
      { title: "Shared rules via a DSL", text: "Define the rules once in a DSL and generate Dart + Go. Powerful, but the generation layer is a third codebase to debug. Two hand-synced ports with a shared test suite is simpler and equally safe — the tests are the real enforcement." },
      { title: "Server as the only engine", text: "Drop the Dart engine and make the server authoritative even offline. Then offline play needs a network — the whole solo story collapses. The dual port is what makes offline + online share one truth." },
    ],
    improve: [
      { title: "A cross-language CI job", text: "One fixture file of hands, run through both engines, assert identical results. When you add a rule, the fixture is the checklist that both ports update together." },
      { title: "Fuzz both ports", text: "Throw random legal boards at both legalMoves implementations. Disagreement → bug in one port, found by a machine." },
    ],
    activity: {
      type: "quiz",
      q: "The Go engine's tests are ported from where?",
      opts: ["Written fresh from the spec", "Case-for-case from frontend/test/engine_test.dart", "From the loadtest", "From the admin UI"],
      correct: 1,
      explain: "Ported case-for-case so a disagreement between the suites means the client and server disagree about the rules.",
    },
    done: ["Both engine test suites pass the same cases."],
    refs: ["backend/internal/engine", "frontend/test/engine_test.dart"],
  }),
  C.step("m10s3", "Auth: guests + resume tokens", {
    learn: [
      C.h("Identity without accounts"),
      C.p("A first-time player joins anonymously; the server mints a guest identity (signed JWT) and returns it. The resume token reclaims a seat after a drop — honoured only while the seat still belongs to that player and within the grace window. No passwords, no sign-up."),
    ],
    do: [
      C.p("Implement guest login: POST /v1/auth/device mints an identity + token on first run; the client stores and resends it."),
      C.p("Implement the resume token lifecycle: issued in the joined frame, validated on rejoin against ownership + RECONNECT_GRACE."),
      C.code("// guestToken = identity, survives reconnects\n// resumeToken = capability to a specific seat, right now\n//\n// honoured only while:\n//   the seat still belongs to that player\n//   AND within the grace window (default 2m)\n// so a stolen token cannot take someone else's place.", "go"),
      C.p("Gate nothing else on auth for now — play proceeds anonymously; identity only enriches history (PERSISTENCE.md §4.1)."),
    ],
    explain: [
      C.p("The two-token split is the whole auth story: the guest token answers 'who are you across reconnects', the resume token answers 'may you take THIS seat right now'. They're issued by different flows, expire on different timelines, and their checks are independent — possession + ownership + time window for resume, versus simply 'have you been seen before' for guest."),
      C.p("Why no accounts: onboarding friction is the enemy of a casual card game, and 'play first, ask questions later' is the product decision. The schema carries Google/Facebook/Apple identities (the auth/link endpoint answers 501 today) — the upgrade path is designed but unbuilt. You're building the anonymous-first core."),
      C.p("Auth sits at the ws edge, not in the engine: the edge validates tokens, the room trusts the seat. That separation means the engine port stays clean of security plumbing."),
    ],
    alternatives: [
      { title: "Session cookies", text: "A server-side session store instead of stateless JWTs. JWTs let any node validate without shared state — the horizontal-scaling choice. Sessions need sticky state and are the pre-actor-era answer." },
      { title: "OAuth from the start", text: "Real provider logins day one. It adds a signup wall before play and a privacy form burden; anonymous-first is the leaner product. When monetization or leaderboards arrive, the link endpoint activates." },
    ],
    improve: [
      { title: "Rotate the guest token", text: "Issue a fresh token on every reconnect and invalidate the old one. Prevents a captured token from being replayed forever — a real hardening you can ship without product changes." },
      { title: "Rate-limit auth", text: "The API_RATE_PER_MINUTE budget already exists; make sure the device-login path is inside it. Anonymous identity mints are the cheapest abuse vector." },
    ],
    activity: {
      type: "quiz",
      q: "A resume token can reclaim a seat when:",
      opts: ["Anyone presents it", "It's still that player's seat, within the grace window", "The seat is empty", "Anytime, forever"],
      correct: 1,
      explain: "Possession + ownership + grace window — capability, not a password.",
    },
    done: ["You can explain the guest vs resume token split."],
    refs: ["backend/internal/auth", "backend/PROTOCOL.md"],
  }),
  C.step("m10s4", "WebSocket edge + quickplay match", {
    learn: [
      C.h("The two networked modes"),
      C.p("The ws edge upgrades sockets, validates auth, and routes frames into rooms. internal/match seats quickplay players: they join shared tables as they arrive (real seats, visible to each other), and a table deals itself once at least two humans are present, filling the rest with bots."),
    ],
    do: [
      C.p("Build the ws edge responsibilities in order: upgrade → validate → route the frame to the room's inbox:"),
      C.code("//   reject frames > 4096 bytes before parsing\n//   per-connection frame budget (MSG_RATE_PER_SECOND / MSG_BURST)\n//   version check: clients newer than the server -> unsupported_version\n//   route by room id to that room's inbox", "go"),
      C.p("Implement quickplay seating (internal/match): join{mode:online, room:QUICKPLAY} → seat at a real shared table → once MATCH_MIN_PLAYERS humans are present, START_COUNTDOWN ticks, then it deals and bots fill the gaps."),
      C.p("Implement the redirect: with Redis enabled, a client reaching the wrong node gets error{code:'redirect', endpoint} — a load balancer hashing on ?room= avoids most redirects."),
    ],
    explain: [
      C.p("The ws edge is a thin, hostile-boundary layer: every rule that protects the server from a bad client lives here — frame size, rate budget, version handshake — while the room stays focused on the game. This is your middleware chain, applied to sockets."),
      C.p("Quickplay's 'seat at a real table immediately' is a deliberate anti-queue design: players SEE each other filling in, which reads as social rather than waiting. The self-deal countdown (MATCH_FILL_WAIT + START_COUNTDOWN) is the lobby UX (module 7.2) implemented server-side — the client just renders lobby frames."),
      C.p("Redis is advisory, not authoritative — an outage degrades routing (more redirects), it does not stop play. That's the resilience posture the README teaches: the registry is a cache in front of reality, never reality itself."),
    ],
    alternatives: [
      { title: "Single room for quickplay", text: "One giant room with a queue. It serializes all games through one goroutine and destroys horizontal scaling. Shared tables + self-deal is the scalable seat-the-arriving-player model." },
      { title: "Enforce rooms by node-local table", text: "Without Redis, rooms live where they were created and clients must reach that node (LB hash on ?room=). Redis + PUBLIC_URL makes redirects possible; both are documented, pick by scale." },
    ],
    improve: [
      { title: "Room lifecycle hygiene", text: "ROOM_IDLE_TTL (5m) reaps empty tables. Make sure the idle clock and the reconnect grace interact sanely — a player reconnecting right as the room expires is a race worth a test." },
      { title: "Matchmake by difficulty preference", text: "When quickplay fills with bots, honor each human's difficulty setting for the bot that sits beside them — a settings-driven nicety with real product value." },
    ],
    activity: {
      type: "quiz",
      q: "On a quickplay table with 2 humans online, how many seats are filled by bots at deal time?",
      opts: ["0", "2", "4", "Depends on the lobby"],
      correct: 1,
      explain: "4 seats total, 2 humans → 2 bots fill the gaps.",
    },
    done: ["You can describe the ws edge's jobs and quickplay's self-deal flow."],
    refs: ["backend/internal/ws", "backend/internal/match"],
  }),
  C.step("m10s5", "Persistence + horizontal scaling", {
    learn: [
      C.h("Postgres optional, Redis advisory"),
      C.p("With no DATABASE_URL the server runs exactly as it always has — tables work, nothing is recorded, REST answers 503 persistence_disabled. With Postgres: accounts, match history, statistics, runtime settings. With Redis + PUBLIC_URL: a shared room registry so a misrouted client gets a redirect instead of a dead table."),
    ],
    do: [
      C.p("Add Postgres behind the optional flag — the store degrades rather than fails:"),
      C.code("# docker compose brings up the full stack:\n#   server + Redis + Postgres\n\n# Persistence degrades, it does not fail:\n#   a database that dies mid-game never interrupts play — recording\n#   sits behind a bounded queue that drops records rather than\n#   stalling a table.", "shell"),
      C.p("Design the schema from docs/PERSISTENCE.md: accounts, games, hands, statistics. Read that doc first — it explains WHY each table exists before you write a migration."),
      C.p("Implement source provenance: bots/lan games upload as source='client' (fine for personal history, never a leaderboard); server-hosted games are source='server'."),
      C.p("Add Redis as the room registry + PUBLIC_URL for redirects, behind env flags."),
    ],
    explain: [
      C.p("'Recording sits behind a bounded queue that drops records rather than stalling a table' is the resilience posture in one sentence. A dead database must never interrupt play — the price is that some records are dropped under extreme load, which is the right trade for a game server. Your instinct to make persistence optional is validated here."),
      C.p("Provenance is a trust statement: source='client' vs 'server' is stored, so a future leaderboard can exclude client-uploaded scores without a schema change. Storing the trust level AT WRITE TIME is the design that makes the trust decision auditable later."),
      C.p("Redis is advisory by construction: the registry is a cache of where rooms live. A Redis outage degrades routing (more redirects) but never stops play — the same degradation-posture as the database, applied to the control plane."),
    ],
    alternatives: [
      { title: "SQLite embedded", text: "A single-node SQLite file would remove the Postgres dependency. Postgres is chosen for the horizontal story and the stats queries; SQLite is the 'good enough for one hobby node' alternative." },
      { title: "Event-sourced history", text: "Store the game's event log (module 2.7's events) instead of pre-aggregated rows, and derive stats on read. Cleaner replay story, more complex reads — the pre-aggregated schema is the pragmatic choice." },
    ],
    improve: [
      { title: "Snapshot rooms to Redis", text: "The README lists this as designed-but-unbuilt: snapshot a room so another node can rehydrate it mid-game. That's the path to zero-loss restarts — a meaty but well-scoped next feature." },
      { title: "Stats you'll actually read", text: "Implement only the statistics your profile screen shows (win rate, average score per hand) — metrics nobody reads are schema debt." },
    ],
    activity: {
      type: "quiz",
      q: "The database dies mid-game. What happens to the running tables?",
      opts: ["Everything stops", "Play continues; recording drops records rather than stalling", "The server crashes", "Players are disconnected"],
      correct: 1,
      explain: "Recording is behind a bounded queue that drops records before it stalls a table.",
    },
    done: ["You can explain both degradation stories (DB down, Redis down)."],
    refs: ["backend/internal/db", "backend/docs/PERSISTENCE.md", "backend/deploy/docker-compose.yml"],
  }),
  C.step("m10s6", "Verify: loadtest + race", {
    learn: [
      C.h("Prove it, don't hope it"),
      C.p("The verification gates: make test (full suite incl. real-websocket integration tests), make race (same under the race detector), make test-db (persistence against a throwaway Postgres container), and the loadtest — real websockets playing only legal cards, measuring the wall time from move to the view that reflects it."),
    ],
    do: [
      C.p("Get the full suite green and under the race detector:"),
      C.code("make test\nmake race\nmake test-db        # starts a Postgres container, throws it away", "shell"),
      C.p("Build and run the loadtest — real sockets, real protocol, legal moves only:"),
      C.code("make build\n./bin/loadtest -url ws://localhost:8080/ws -tables 200 -humans 4\n\n# 200 tables x 4 humans (800 players, 55,440 moves) on one core:\n#   p50 625µs | p90 5.3ms | p99 13.6ms | max 38ms\n# zero dropped connections, zero turn timeouts, 198/200 games finished", "shell"),
      C.p("Read the known-limitations list in the README and decide which ones you'll tackle (room codes, snapshots, account upgrade)."),
    ],
    explain: [
      C.p("The loadtest measures what a player FEELS: wall time from sending a move to receiving the view that reflects it. p50 625µs / p99 13.6ms is a response-time contract, not a synthetic CPU benchmark — and it only plays cards the server said were legal, so the harness can't cheat the numbers."),
      C.p("The race detector is non-negotiable for the actor model: your one-goroutine-per-room design has no locks by construction, and make race proves it — if a stray goroutine ever touches shared state, the detector finds it in CI instead of production."),
      C.p("The 'two tables didn't finish' line in the README is honest failure analysis: 2 of 200 games collided on random room codes and the server correctly refused the second table's start. Reading limitations honestly is part of engineering a system you trust."),
    ],
    alternatives: [
      { title: "k6 / vegeta against the ws edge", text: "General load tools can hit the socket with scripted traffic. The bespoke loadtest speaks the real protocol AND validates legality — that's the difference between measuring load and measuring the game." },
      { title: "Chaos-test the failures", text: "Kill Postgres mid-game, drop Redis, SIGTERM a draining node — assert the degradation stories hold. The README's resilience postures deserve a scripted chaos test, not faith." },
    ],
    improve: [
      { title: "Track the p99 over time", text: "Feed the loadtest's numbers into the metrics pipeline and alert on p99 regression. Latency that drifts quietly is how 'fine' becomes 'why is it slow'." },
      { title: "Adopt the limitations", text: "Lengthening room codes means changing RoomCodeLength AND the client's _newCode together. When you do, the loadtest collision rate drops with it — a measurable payoff." },
    ],
    activity: {
      type: "quiz",
      q: "What does the loadtest measure?",
      opts: ["CPU usage", "Wall time from sending a move to receiving the view reflecting it", "Network bandwidth", "Database throughput"],
      correct: 1,
      explain: "The thing a player feels: move → reflected view latency.",
    },
    done: ["make test, make race, and the loadtest all green on your machine."],
    refs: ["backend/Makefile", "backend/cmd/loadtest/main.go"],
  }),
]));
