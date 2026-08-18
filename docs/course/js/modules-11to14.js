/* Build Call Break — modules 11-14: deep backend design.
   m11 API & Protocol, m12 Database, m13 Redis/Pub-Sub/Scaling, m14 Monitoring/Ops.
   Every decision answers 'why this, not that'. */

REGISTER(C.module("m11", "📡", "API & Protocol Design", "the wire contracts, why each decision", [
  C.step("m11s1", "Design principles first", {
    learn: [
      C.h("Two clients, one contract"),
      C.p("The API surface exists for exactly one consumer: the Flutter app. That constraint is the whole design tension — you could make a maximally general API, or a maximally convenient one. Call Break optimizes for convenience plus honesty: every response is an object, every error is a typed envelope, and additive changes are safe by construction."),
      C.b("lowerCamelCase keys, RFC 3339 UTC timestamps, scores with at most 2 decimals — the three conventions that make both codebases predictable."),
      C.b("Every response is an object, never a bare array — arrays live under named keys so the envelope can grow without breaking shape."),
      C.b("Adding a field is safe; renaming/removing is breaking — the golden rule that makes version-less evolution possible for one client."),
    ],
    do: [
      C.p("Write the three conventions on a card. They are the contract's grammar — everything else is vocabulary."),
      C.p("For each of these 'why not' questions, write one line each BEFORE reading on — then compare with the reasoning below:"),
      C.p("Why REST instead of GraphQL?"),
      C.p("Why hand-written JSON instead of Protobuf/msgpack?"),
      C.p("Why an object envelope instead of bare arrays?"),
      C.p("Read backend/docs/API.md 'Conventions' section and PROTOCOL.md 'Compatibility rules' — they are the codified versions of the principles."),
    ],
    explain: [
      C.p("Why REST here and not GraphQL: there are four shapes of data (user, game summary, stats, history page) and one fixed consumer. GraphQL's value — let each client fetch exactly the fields it wants — is a solution to a problem you don't have; it costs you a query layer, a schema server, and a typed client generator. REST's fixed shapes are perfectly matched to 'the app wants these exact objects'. The rule to generalize: pick the data-granting layer that matches how many consumers and how varied their needs are."),
      C.p("Why JSON and not Protobuf: the frame and response volumes are tiny (a view is a few KB), the traffic is debuggable in server logs, and the wire contract is human-negotiable in a doc. Protobuf buys compactness + schema enforcement at the cost of a codegen toolchain on both sides and unreadable logs. JSON + hand-written lenient decoders gives the same 'additive field' safety with none of the machinery — at this scale, the schema is the spec file, enforced by contract tests instead of a compiler."),
      C.p("Why object envelopes: a bare array can't gain metadata without breaking every consumer. An envelope can grow (add a 'next' cursor, a 'total', a 'warnings' key) and old clients ignore the new keys. That one rule — always an object, additive fields only — is what lets the API evolve without versioning gymnastics."),
    ],
    alternatives: [
      { title: "GraphQL", text: "One endpoint, client-selected fields, typed schema. Wins when consumers multiply and field sets diverge. Here: one consumer, four shapes — the overhead buys nothing." },
      { title: "gRPC + Protobuf", text: "Strong typing, HTTP/2, streaming for free. The server already streams state over WebSocket — adding gRPC for the REST side means two RPC stacks. JSON is the honest fit for a mobile game's small payloads." },
      { title: "OpenAPI-first", text: "Define the spec in OpenAPI and generate both client and server. Loses the hand-written-leniency story but automates the boring parts. The right move when the API outgrows one doc file." },
    ],
    improve: [
      { title: "Contract tests both ways", text: "The Dart client's api_contract_test feeds the literal doc JSON (module 6.3). The Go side should round-trip the SAME fixtures — a doc change either breaks the client test or the server test, never silently." },
      { title: "Changelog the wire format", text: "PROTOCOL.md and API.md already carry 'breaking' flags. Add a dated changelog section so a v2 bump has a migration trail." },
    ],
    activity: {
      type: "quiz",
      q: "The API wraps every list in an object (e.g. { games: [...] }) instead of a bare array. Why?",
      opts: ["It's more RESTful", "The envelope can grow metadata (cursors, totals) without breaking old clients", "Arrays are banned in JSON", "It's faster to parse"],
      correct: 1,
      explain: "A bare array can't gain fields; an object envelope can grow additively, and lenient decoders ignore the new keys.",
    },
    done: ["You can explain why each of the three conventions exists."],
    refs: ["backend/docs/API.md", "backend/PROTOCOL.md"],
  }),
  C.step("m11s2", "The REST surface, endpoint by endpoint", {
    learn: [
      C.h("Eleven endpoints, four jobs"),
      C.p("The /v1 surface clusters into four jobs: auth (device/refresh/restore/link), identity (me + patch), history (my games + a game detail), and offline upload (POST /v1/games). Read each through the lens of 'what does the app need, and what failure would break the product?'."),
    ],
    do: [
      C.p("Map the surface — write each endpoint and its job from the spec before reading on:"),
      C.code("POST /v1/auth/device    guest login: mint/find a user from a device id\nPOST /v1/auth/refresh    rotate an expiring session token\nPOST /v1/auth/link       (reserved, 501) attach Google/Facebook/Apple\nPOST /v1/auth/restore    reclaim an account from an old device\nGET  /v1/me              the user object\nPATCH /v1/me             change display name / avatar\nGET  /v1/me/stats        statistics per scope (all/bots/private/online/lan)\nGET  /v1/me/games        history page (mode filter, keyset pagination)\nGET  /v1/games/{id}      one game, full detail\nPOST /v1/games           upload an offline (client) game\nGET  /v1/admin/*         ops dashboard API (ADMIN_TOKEN gated)", "text"),
      C.p("For POST /v1/auth/device, trace the flow: deviceId → identity lookup → user row exists? return it, else INSERT user+identity → return {token, user}. Write the idempotency property: calling it twice with the same deviceId returns the SAME user."),
      C.p("For GET /v1/me/games, write out the keyset-pagination contract: ?mode=&limit=&cursor=, where cursor encodes the last row's (finished_at, game_id). Explain why a page number would be worse."),
    ],
    explain: [
      C.p("POST /v1/auth/device is the anti-signup-wall design: first launch generates a device id (module 5.1), posts it, and gets a real user row back — from that moment it's a full account that can later absorb Google/Apple logins without losing anything. The idempotency is structural: the ('device', deviceId) identity IS the unique key (module 12.1), so re-running the request returns the same user instead of minting a duplicate. That's the guest story done with a lookup, not a migration."),
      C.p("PATCH /v1/me (not PUT) is a semantic choice: a partial update of a couple of fields, not a full replace. PUT would require the client to send the entire user object and would clobber server-managed fields like created_at if the client echoed them wrong. PATCH says 'change exactly these'. Small, but it's the kind of convention that prevents a whole class of 'it reset my avatar' bugs."),
      C.p("Keyset pagination (cursor) vs page numbers is a database-designed decision, not a cosmetic one: page=3 breaks the moment a new game is inserted, because rows shift pages. A cursor encodes 'the last row I saw' as a tuple (finished_at, game_id), and the next query is a single index range scan on the history index (module 12.5). No OFFSET, no double-counting, no drift. That's why the API exposes cursor, not page."),
      C.p("POST /v1/auth/link returns 501 not 404: the endpoint is real, its verification (Firebase token check) is unbuilt. A 404 would hide the intent from future devs and clients; a 501 names the boundary. Reserved-but-named beats missing."),
    ],
    alternatives: [
      { title: "Page-based pagination", text: "page/limit is simpler to type and tempting. It breaks under inserts (row shifts) and needs OFFSET scans. Cursor is the honest choice once a table can grow." },
      { title: "PUT for profile", text: "A full-replace PUT would force the client to round-trip fields it doesn't own. PATCH keeps ownership of server fields on the server." },
      { title: "Batch upload endpoint", text: "POST /v1/games accepts one game at a time; a batch endpoint (up to N games) would cut request count after an offline streak. The client flushes per game today — a future optimization, not a current need." },
    ],
    improve: [
      { title: "ETag / conditional GET for /me", text: "The profile is fetched often; a lightweight If-None-Match returns 304 when unchanged. Cheap bandwidth win once history grows." },
      { title: "Audit-log admin actions", text: "The admin API changes pacing and runtime settings. A settings-change audit trail (who, when, from) turns a misfire into a fixable incident." },
    ],
    activity: {
      type: "code",
      starter: "// Implement the idempotency heart of device login (pseudo-code):\n// given a deviceId, return the existing user or create one,\n// never duplicate. Write the decision logic.\nObject deviceLogin(String deviceId) {\n  // your code\n  return {};  // {user, token}\n}",
      checks: [
        CHK.has("lookup first", "find|lookup|lookUp|SELECT|getUser|identity", "First look up the identity by deviceId."),
        CHK.has("create when missing", "create|insert|INSERT|newUser|mint", "Create a user only when none exists."),
        CHK.has("no duplicate", "if\\s*\\(|!=\\s*null|is\\s*null|exists", "Branch on whether it exists — never blindly insert."),
      ],
    },
    done: ["You can trace device login's idempotency and explain keyset pagination."],
    refs: ["backend/docs/API.md", "backend/internal/httpapi/games.go", "backend/internal/httpapi/auth.go"],
  }),
  C.step("m11s3", "The WebSocket protocol", {
    learn: [
      C.h("The socket is the game"),
      C.p("One WebSocket per player at GET /ws, JSON text frames, server-authoritative. The server is the only writer of game state; the client renders redacted views and sends intents. Four frames from the client (join, bid, play, next + restart/leave/awake/ping) carry the entire interactive surface."),
    ],
    do: [
      C.p("Read backend/PROTOCOL.md cover to cover. Then write the frame table from memory — client→server and server→client:"),
      C.code("client -> server:\n  join    {v, room, mode, name, difficulty?, handsPerGame?, resumeToken?, guestToken?}\n  start   (private: host only)\n  bid     {bid}          clamped 1-13 server-side\n  play    {card}         wire id, e.g. 'AS', '10H'\n  next    (leave the between-hands scoreboard)\n  restart (private: host; quickplay: needs every human)\n  leave   (forfeit the seat immediately)\n  awake   (a sign of life; cancels autoplay)\n  ping    {t}            echoed in pong\n\nserver -> client:\n  joined  {seat, guestToken, resumeToken}\n  lobby   {room, seats, canStart, ...}\n  view    the redacted per-seat GameView\n  error   {code, endpoint?}  (redirect points at the right node)\n  pong    {t}", "text"),
      C.p("Explain, in your own words, each compatibility rule: adding a field is safe; renaming/removing is breaking; a newer client is refused with unsupported_version; frames over 4096 bytes are rejected before parsing."),
      C.p("Trace one turn around the loop: you play AS → client sends play{card:'AS'} → server validates legality → engine applies → server broadcasts redacted views to all four → each client's RemoteSession._applyView converts deadlines and re-emits events."),
    ],
    explain: [
      C.p("Server-authoritative is the anti-cheat design: the client NEVER mutates state — it requests, and the server validates (legal move? your turn? correct phase?) then broadcasts the result. Because views are redacted (module 2.6) and the server is the only writer, there is no shared state to desync, no message that can be forged into an illegal move, and no client that can see what it mustn't."),
      C.p("The compatibility rules ARE the versioning story: because every decoder ignores unknown keys, the server can add a field in a new release and old clients keep working — the exact golden rule from REST, applied to frames. The v:2 handshake exists for the OPPOSITE direction: a client built for v3 must not be served a v2 protocol it might misread, so the server refuses with unsupported_version. Additive-forever + explicit-major = evolution without forks."),
      C.p("The 4096-byte frame cap and the per-connection rate budget (MSG_RATE_PER_SECOND 20, MSG_BURST 40) are the abuse surface: a socket is a cheap thing to open and a hostile client could flood frames or send 100KB blobs. Rejecting oversize frames BEFORE parsing means the JSON decoder never sees garbage, and the token-bucket budget keeps any one connection from dominating. MAX_CONNS_PER_IP (64) stops a single IP from opening a socket army."),
      C.p("ping/pong with an echo of t is the round-trip timer the client uses to notice a dead socket before the TCP timeout does — the early-warning system for the reconnect flow (module 7.4)."),
    ],
    alternatives: [
      { title: "REST for moves", text: "POST /play/{card} per move would add HTTP round-trips and force ordering management. The socket's persistent connection gives you ordering for free and halves latency — the right transport for a turn-based real-time game." },
      { title: "Binary framing", text: "A 1-byte type tag + payload would save bytes and add a codec + docs. JSON frames are debuggable in server logs, which outvalues the savings at this volume." },
      { title: "Delta-only views", text: "Send only what changed since the last view. Saves bandwidth; costs a diff protocol and a reconciliation story when frames are lost. Full redacted views are idempotent — any one view fully describes the table, which is what makes reconnect trivial." },
    ],
    improve: [
      { title: "Idle-disconnect", text: "A server-side read timeout that closes sockets silent for N seconds frees seats and beats TCP's slow detection. Coordinated with RECONNECT_GRACE so a brief blip never costs a seat." },
      { title: "Frame validation tests", text: "The wire-contract test on the client checks the client parses the docs' frames. A Go-side table test that every frame shape validates (or rejects) is the mirror — fuzz the frame parser too." },
    ],
    activity: {
      type: "quiz",
      q: "Why does the server reject frames larger than 4096 bytes BEFORE parsing them?",
      opts: ["To save bandwidth", "So the JSON decoder never sees garbage, and a hostile client can't flood it with huge blobs", "Because WebSocket forbids big frames", "To speed up the game"],
      correct: 1,
      explain: "Reject before parse = the decoder only ever sees sane input; the size cap is an abuse guard.",
    },
    done: ["You can write both frame tables from memory and justify the compatibility rules."],
    refs: ["backend/PROTOCOL.md", "backend/internal/ws", "backend/internal/protocol"],
  }),
  C.step("m11s4", "Errors & rate limits", {
    learn: [
      C.h("Fail loudly, fail typed"),
      C.p("Every error is { error: { code, message } }. The code is the machine contract (clients branch on it); the message is the human string (and must be safe to show a player). Eight codes cover the whole failure space."),
    ],
    do: [
      C.p("Write the error-code table and match each to the client behaviour it should trigger:"),
      C.code("bad_request          400  malformed body/query  -> show a validation hint\nunauthorized          401  missing/expired/forged  -> prompt re-login\nnot_found             404  no such game / not yours -> return to home\nconflict              409  identity already taken   -> offer merge\nrate_limited          429  too many requests        -> back off, retry later\npersistence_disabled  503  no database configured   -> degrade gracefully\nnot_implemented       501  reserved for the future  -> hide the feature\ninternal              500  anything else            -> generic message", "text"),
      C.p("Implement the two rate budgets in the ws edge and the REST layer:"),
      C.code("// socket: token bucket per connection\n//   MSG_RATE_PER_SECOND=20 refill, MSG_BURST=40 capacity\n//   a frame over budget -> close or throttle, never queue unbounded\n\n// REST: API_RATE_PER_MINUTE=120 per account\n//   a burst beyond the budget -> 429 rate_limited\n\n// plus MAX_CONNS_PER_IP=64 sockets per address", "go"),
      C.p("Decide the retry policy for each failure class: which errors deserve a client retry (rate_limited, 5xx, network) and which must NOT be retried (bad_request, unauthorized)."),
    ],
    explain: [
      C.p("The code/message split is the classic typed-error discipline: the message is for humans, the code is for machines. The client switches on code ('unauthorized' → sign-in screen) and ignores message differences, so the server can reword a message without breaking anyone. The one rule that keeps it safe: a message must be safe to show — never echo a database constraint, never leak an internal path."),
      C.p("The token bucket is why the rate budget is stated as rate + burst: 20/sec refill with a 40-frame burst lets a player's reconnect blast through briefly, then throttles sustained spam. A pure '20 per second' would punish legitimately chatty bursts; a pure counter would allow one long flood. Token buckets give you both a floor and a ceiling."),
      C.p("Which errors get retried is a policy decision with a bug behind every wrong answer: retrying a 400 is pointless (it will fail again) and retrying an expired 401 without refreshing the token is a retry storm. The client-side rule that maps cleanly: retry idempotent requests on 429/5xx/network; never on 4xx; refresh-then-retry exactly once on unauthorized."),
    ],
    alternatives: [
      { title: "HTTP status codes alone", text: "Status codes are the coarse outer layer; the code gives the fine grain. Branching on statuses alone can't distinguish 'identity taken' from 'game not yours' — both 4xx." },
      { title: "gRPC error model", text: "gRPC's typed statuses are the same idea in a framework. Hand-rolled codes here because the transport is JSON, not gRPC — the principle (typed machine errors) is what carries across." },
      { title: "Disconnect on abuse", text: "A hard disconnect on the first budget violation punishes one over-eager reconnect. Throttle-and-close-after-persistence is friendlier; the budget exists to stop floods, not to expel honest clients." },
    ],
    improve: [
      { title: "Expose rate-limit headers", text: "Retry-After / X-RateLimit-Remaining headers let a well-behaved client compute backoff instead of guessing. Cheap, and it makes 429 recoverable instead of hostile." },
      { title: "Alert on budget exhaustion", text: "rate_limited responses climbing near the cap is a real signal (an abusive client or a bug). A metrics counter feeding an alert beats discovering it in player complaints." },
    ],
    activity: {
      type: "quiz",
      q: "A client sends a move and gets 400 bad_request. Should it retry?",
      opts: ["Yes, with backoff", "No — a malformed request will fail again unchanged", "Only once", "Until 429"],
      correct: 1,
      explain: "4xx is a client bug — retrying the same request repeats the same failure. Fix the request, don't retry it.",
    },
    done: ["You can map each error code to a client behaviour and explain the token bucket."],
    refs: ["backend/docs/API.md (Errors)", "backend/internal/httpapi/errors.go", "backend/internal/ws"],
  }),
  C.step("m11s5", "Idempotency & the retry policy", {
    learn: [
      C.h("Make retries free, then make them work"),
      C.p("Idempotency is the contract that lets a client retry without fear. For offline game uploads the key is client_game_id, minted once at deal time (module 9.2) and enforced by a partial unique index — a retried upload collides and returns the original game, never a duplicate."),
    ],
    do: [
      C.p("Trace the upload flow end to end, marking every retry-safe point:"),
      C.code("client: game starts -> mint client_game_id (once, at deal)\nclient: game ends  -> enqueue payload {game, hands, seats, id}\nclient: flush -> POST /v1/games  (maybe offline: fails, stays queued)\nserver: INSERT games ... client_game_id=...\n        ON CONFLICT (client_game_id) -> return the EXISTING game\nclient: dedupe by id -> never double-record, never double-count", "text"),
      C.p("Write the retry matrix: which classes retry (rate_limited, 5xx, network, timeout), which don't (4xx), and the backoff shape (exponential + jitter, capped)."),
      C.p("Explain why the idempotency key must be minted at DEAL time, not at upload time — what breaks if a crash between deal and upload re-mints it?"),
    ],
    explain: [
      C.p("The client_game_id is an idempotency key, minted ONCE when the game starts. Minting it at upload time would break the guarantee: if the app crashes after the game ends but before the first upload, a second attempt would mint a NEW id and the server would record a duplicate. Minted at deal, the id is stable for the game's whole life — every retry of that game carries the same key, and the unique index turns the second insert into a lookup."),
      C.p("The partial unique index (WHERE client_game_id IS NOT NULL) is a database-shaped decision: server games never send a client id, so a plain unique index would index every server game for nothing (module 12.5). Partial + unique = the idempotency guarantee exists exactly where it's needed and costs nothing elsewhere."),
      C.p("The retry matrix is where 'idempotent' meets 'polite': exponential backoff with jitter (800ms × 2^n, randomized) prevents a reconnect herd (all clients retrying in lockstep), and the cap prevents infinite hammering. Combine with the module 9.2 queue: the payload lives durably until success, so 'retry' is just 'flush the queue again'."),
    ],
    alternatives: [
      { title: "Server-side dedupe by hash", text: "Hash the payload and dedupe on the hash. Fragile (two legitimately identical games would collide) and opaque. A client-owned key is explicit and debuggable." },
      { title: "Exactly-once via a message broker", text: "A broker (Kafka/Pulsar) gives exactly-once semantics as a platform feature. Massive machinery for one upload endpoint — a unique index is the same guarantee for three lines of SQL." },
      { title: "No idempotency, delete on error", text: "Record the game, and on upload error DELETE and retry. Loses a recorded game if the delete succeeds but the retry never does — the idempotency key is strictly safer." },
    ],
    improve: [
      { title: "Idempotency for auth refresh", text: "Token refresh deserves the same discipline: a refreshed token replaced concurrently should not invalidate the other. The auth refresh endpoint's semantics are a future test case." },
      { title: "Test the crash windows", text: "Kill the app at each point in the upload flow and assert: deal→crash, game-end→crash, upload-in-flight→crash. Each window must resolve to exactly one recorded game. That test suite is your idempotency proof." },
    ],
    activity: {
      type: "quiz",
      q: "Why mint the idempotency key at DEAL time instead of at first upload?",
      opts: ["It's faster", "A crash between game end and first upload would otherwise mint a new id and the retry would double-record", "The server requires it", "It saves storage"],
      correct: 1,
      explain: "Stable key for the game's life = every retry collides on the same id; the unique index returns the existing game.",
    },
    done: ["You can explain the full upload idempotency chain and the retry matrix."],
    refs: ["backend/docs/API.md (POST /v1/games)", "backend/migrations/0001_init.sql (games_client_game_id_key)", "frontend/lib/net/game_uploader.dart"],
  }),
]));

REGISTER(C.module("m12", "🗄", "Database Design", "Postgres schema, migrations, indexes", [
  C.step("m12s1", "The identity model", {
    learn: [
      C.h("Two tables, not one"),
      C.p("users.id is a surrogate key and the only key anything references. The device id is NOT the primary key — it lives one table over in user_identities as ('device', deviceId). That one indirection is what makes guests ordinary users, upgrades additive, and cross-device login a lookup."),
    ],
    do: [
      C.p("Sketch the two tables and their relationship:"),
      C.code("users\n  id uuid pk            <- the surrogate key everything references\n  display_name, is_guest, created_at, last_seen_at\n  merged_into uuid fk      (account absorption, NULL normally)\n\nuser_identities\n  PRIMARY KEY (provider, subject)   <- (device, <deviceId>) or (google, <uid>)\n  user_id uuid fk NOT NULL\n  provider text  CHECK in ('device','google','facebook','apple')", "sql"),
      C.p("Answer the 'why not one table' question: what breaks if device_id were the primary key of users?"),
      C.p("Trace the guest upgrade: player has ('device', X) on users row A, signs in with Google, gets ('google', uid) → INSERT a second identity row pointing at the SAME users.id A, flip is_guest=false. No foreign key moves."),
      C.p("Read PERSISTENCE.md §1.2 — the design doc argues this exact decision."),
    ],
    explain: [
      C.p("Why a surrogate key: the device id is a fact about HOW someone arrives, not WHO they are. If device_id were the primary key, the first Google login forces a rewrite of every foreign key that pointed at it. With users.id as the key, adding Google is an insert of a second identity row — no game, no seat, no stat row moves. The upgrade is a one-line insert BECAUSE the identity was indirection all along. That's the entire reason for the split."),
      C.p("Why (provider, subject) is the PRIMARY KEY of user_identities: the pair identifies the row, so it may as well be the key — and making it the key gives ON CONFLICT (provider, subject) something to arbitrate on. Two devices booting at once posting the same device id would otherwise mint two accounts; the conflict target collapses them into one user. This is the structural idempotency behind device login (module 11.2)."),
      C.p("The DEFERRABLE INITIALLY DEFERRED foreign key is load-bearing, not decoration: identity resolution is a single statement that inserts the identity first (its ON CONFLICT decides whether a new user is needed) and then the users row it points at in a dependent CTE. The identity has to be written before the user exists — deferring the FK check to commit makes that legal without weakening the constraint. A subtle bit of SQL that a rewrite would break."),
      C.p("The merged_into self-reference is the account-merging story: absorbed guests keep their row (tokens in flight and the audit trail survive), and identity resolution follows the pointer — which is why a merged guest's device still signs in. Deleting the row would orphan in-flight tokens."),
    ],
    alternatives: [
      { title: "Single-table with device_id as key", text: "Simpler now, but every future provider (Google/Apple/Facebook) either needs a device_id-shaped column or a rewrite of every FK. The two-table split prices the future at one join." },
      { title: "One identity provider only", text: "If you commit to device-only forever, the second table is speculative. The 'why not' answer is the product ambition: anonymous-first with a designed upgrade path. The schema is the plan." },
      { title: "Users without guests", text: "Requiring a real login before play would remove the guests story entirely. The whole game is anonymous-first (module 10.3) — guests are the product, not a workaround." },
    ],
    improve: [
      { title: "Email as a third identity", text: "A ('email', addr) identity is the natural bridge when the Firebase upgrade arrives — the schema already supports it (provider CHECK is extensible to your own values)." },
      { title: "Unique display names", text: "If leaderboards ever need uniqueness, that's a separate constraint + a resolution flow (suffix numbers). Not now; schema can grow it additively." },
    ],
    activity: {
      type: "quiz",
      q: "Why is users.id a surrogate key instead of the device id?",
      opts: ["UUIDs are faster", "So upgrading a guest to Google/Apple is an insert of an identity row, not a rewrite of every foreign key", "Device ids are too short", "Postgres requires it"],
      correct: 1,
      explain: "Indirection: users.id is what everything references; identity providers are rows that point at it, so adding a provider never moves a foreign key.",
    },
    done: ["You can explain the two-table identity model and why upgrades are additive."],
    refs: ["backend/migrations/0001_init.sql (users, user_identities)", "backend/docs/PERSISTENCE.md §1"],
  }),
  C.step("m12s2", "The game grain", {
    learn: [
      C.h("Games, seats, hands, tricks"),
      C.p("History is queryable because the player is on the SEAT, not the game. game_seats is the row that lets four players each see the same game in their own history with their own result. Everything below a game cascades from it, so deleting a game can never orphan a row."),
    ],
    do: [
      C.p("Sketch the four tables and their grain (what one row means):"),
      C.code("games        one row = one match   (mode, source, completed, client_game_id)\ngame_seats   one row = one seat in one game  (user_id, final_score, place)\ngame_hands   one row = one seat, one hand     (bid, tricks_won, score_delta)\ngame_tricks  one row = one trick              (winner_seat, plays as jsonb)", "sql"),
      C.p("Explain the cascade chain: games → seats → hands/tricks all ON DELETE CASCADE. Why is deletion the safe path rather than leaving orphaned rows?"),
      C.p("Explain the completed flag: false for a table that closed without a final scoreboard. Why should a rage-quit still count as played but never as won?"),
      C.p("Read PERSISTENCE.md §2 (game grain) and confirm your reasoning."),
    ],
    explain: [
      C.p("Why the player is on the seat, not the game: history is a per-user query ('my last 20 games'), and four different users own different seats in the same game. If the game row carried 'owner', only one player would ever see it. game_seats is the join that makes the SAME game appear in four different histories with each player's own score and place — and bots are just seats with user_id NULL."),
      C.p("Why hands are a real table: the history screen renders the per-hand scoreboard (bid, tricks, delta per hand). Five hands × four seats = 20 rows per game — cheap to store, exactly what the UI reads. It's the grain the whole statistics layer derives from."),
      C.p("Why game_tricks is jsonb instead of a fifth table: a trick's four plays are only ever read as a whole, alongside the trick. Four rows per trick would quadruple the row count of the largest table for data that's never queried one-card-at-a-time. jsonb stores the ordered plays as one value — the 'why not normalized' answer is about read patterns, not purism. RECORD_TRICKS gates writes, so the table exists from day one but costs nothing until switched on."),
      C.p("The completed flag is a truth statement about rage-quits: the game happened (it counts as played, its stats still accrue) but it was never won (no place ranking, no score record). Abandonment is a real outcome, not a missing row — keeping it as data means the analytics can distinguish 'finished' from 'abandoned' without inferring it from gaps."),
      C.p("CASCADE everywhere is the orphan-prevention rule: you can delete a game and every seat, hand, and trick goes with it in one transaction. Orphans are how 'my history' silently grows ghost rows and how aggregate counts go wrong."),
    ],
    alternatives: [
      { title: "One game row with a seats array", text: "A jsonb seats array would store the game in one row. Querying 'my games' becomes a full-table scan with jsonb filters — the history index (module 12.5) is impossible. Normalized seats exist for the QUERY, not for tidiness." },
      { title: "Tricks normalized to four rows", text: "A plays table is 'more normalized' but quadruples the largest table for data read only as a whole. Grain should follow read patterns: whole-trick reads → one jsonb row." },
      { title: "Delete vs tombstone", text: "Hard-deleting a game (with cascade) vs soft-deleting with a flag. Soft-delete preserves audit history; hard-delete keeps queries simple. For player-owned game history, hard-delete-with-cascade is the honest 'I want this gone' semantics." },
    ],
    improve: [
      { title: "RECORD_TRICKS replay API", text: "The game_tricks rows are the raw material for a 'watch the replay' feature and for bot calibration (module 2.3's improve). One export endpoint away from both." },
      { title: "Mode denormalized onto seats", text: "game_seats carries mode + finished_at denormalized from games purely for the history index. Document the invariant: both written once in the same transaction, never updated after. That's what makes the copy safe." },
    ],
    activity: {
      type: "quiz",
      q: "Why is the user on game_seats rather than on games?",
      opts: ["It saves space", "Four players can see the same game in their own history with their own score, because the user is on the seat", "The engine requires it", "It's faster to insert"],
      correct: 1,
      explain: "History is per-user; the seat is the join between a game and its four different owners.",
    },
    done: ["You can explain the four-table grain and the cascade rule."],
    refs: ["backend/migrations/0001_init.sql (games, game_seats, game_hands, game_tricks)", "backend/docs/PERSISTENCE.md §2"],
  }),
  C.step("m12s3", "Statistics & scopes", {
    learn: [
      C.h("Counters, not queries"),
      C.p("user_stats holds denormalized counters per (user, scope). The profile screen must not run a five-table aggregate every time it opens, so a single transaction per game maintains the counters. Derived figures (win rate, average score) are deliberately absent — computed on read so the two numbers can never disagree."),
    ],
    do: [
      C.p("Sketch the scope key and the counter groups:"),
      C.code("user_stats\n  PRIMARY KEY (user_id, scope)   -- scope in ('all','bots','private','online','lan')\n\n  games: played, completed, won, lost, best_place\n  hands: hands_played, total_bid, bids_made, bids_failed, highest_bid, total_tricks\n  score: total_score numeric(12,2)\n  record: highest_game_score, lowest_game_score, highest_hand_score  (NULLable)\n  streaks: current_win_streak, best_win_streak, last_played_at", "sql"),
      C.p("Answer two 'why' questions: (1) why denormalize into counters instead of aggregating on read? (2) why are the record columns NULLable and the score columns not?"),
      C.p("Trace one game finishing: how many user_stats rows does it touch, and how is 'all' scope kept consistent with the per-mode scope?"),
    ],
    explain: [
      C.p("Why counters over aggregates: a 'my stats' screen over five tables (games join seats join hands join tricks...) gets expensive the moment a player has 1,000 games — and it recomputes the same answer every open. The counters are maintained once per game, in the same transaction that records the game, so they're always fresh and reads are one row. The cost: two values could theoretically drift — which is why the same transaction writes them (module 12.6's single-writer discipline)."),
      C.p("Why the record columns are NULLable: a Call Break score can be negative, so 0 is a REAL value — it cannot double as 'no data yet'. NULL means 'never set', and Postgres' GREATEST/LEAST ignore NULLs, so the first completed game sets the record with no special-case code. The sentinel trap ('is 0 a score or no data?') is exactly why the schema distinguishes NULL from 0."),
      C.p("Why derived figures are absent: win rate and average score are COMPUTED from stored counters on read. Storing them would let the numerator and denominator drift — two numbers that must agree, maintained in two places. Derive, don't store, whenever the ratio is a pure function of its parts."),
      C.p("Why a scope row per mode AND an 'all' row: the profile can show 'best in quickplay' separately from 'best against bots'. A game updates the 'all' row and its mode row together, in one transaction, so the per-mode counters always sum consistently."),
    ],
    alternatives: [
      { title: "Aggregate on read", text: "Simpler schema, expensive reads, and the answer changes shape as the table grows. Counters are the 'make reads cheap' choice — the same trade as a materialized view, minus the refresh machinery." },
      { title: "A separate analytics store", text: "Shipping stats to a warehouse (ClickHouse/BigQuery) and querying there. Correct for cross-user analytics at scale; overkill when the only consumer is one profile screen." },
      { title: "Compute records with sentinel 0", text: "Storing 0 instead of NULL for 'no data' looks convenient and breaks exactly when a real score is also 0. The NULL/0 distinction is the schema being honest." },
    ],
    improve: [
      { title: "Stats refresh endpoint", text: "A 'recompute from games' admin job that rebuilds user_stats from the game tables is the safety net if a counter ever drifts — the counters are derived data, so they can be regenerated. That property is the backstop that makes denormalization safe." },
      { title: "Per-hand record columns", text: "The record columns track game-level highs; hand-level records are a natural extension when 'my best single hand' becomes a profile feature." },
    ],
    activity: {
      type: "quiz",
      q: "Why are the record columns (highest_game_score) NULLable while total_score is NOT NULL default 0?",
      opts: ["NULL is faster", "A score can be negative, so 0 is a real value — NULL must mean 'never set', and GREATEST/LEAST ignore NULLs for free", "Postgres requires it", "Go structs need pointers"],
      correct: 1,
      explain: "NULL = no data yet; 0 = a real (possibly negative-worthy) score. The distinction is what makes first-game records set without special cases.",
    },
    done: ["You can explain counters-vs-aggregates, the NULL/0 rule, and derived-on-read."],
    refs: ["backend/migrations/0001_init.sql (user_stats)", "backend/docs/PERSISTENCE.md §3"],
  }),
  C.step("m12s4", "Migrations & types", {
    learn: [
      C.h("SQL you can apply yourself"),
      C.p("Migrations are forward-only SQL files, embedded in the binary, applied at startup. The types are chosen for exactness: numeric(6,2) not float8, jsonb for whole-read data, and deliberately no CREATE EXTENSION."),
    ],
    do: [
      C.p("Read the three migration files and note their ordering story: 0001_init (schema), 0002_runtime_settings (admin-tunable defaults), 0003_games_finished_idx (index for the admin history list)."),
      C.p("Answer the type questions:"),
      C.code("-- Why numeric(6,2) instead of float8?\n--   'every score is numeric(6,2), never float. Call Break scores carry\n--    one decimal (bid + 0.1 per overtrick), and 8.3 as a float8 is not\n--    equal to itself across a round trip. Money-style arithmetic wants\n--    exact decimals.'\n\n-- Why jsonb for game_tricks.plays?\n--   a trick's plays are only ever read as a whole, alongside the trick.\n\n-- Why NO CREATE EXTENSION anywhere?\n--   gen_random_uuid() lives in pg_catalog on Postgres 13+. Installing an\n--   extension needs rights Postgres often withholds from the application\n--   role, and a schema the application cannot apply for itself is not\n--   much of a schema.", "sql"),
      C.p("Explain why migrations are embedded in the binary (migrations/embed.go) instead of run from a separate tool."),
    ],
    explain: [
      C.p("numeric(6,2) vs float8 is the exactness argument you already respect in money code: 8.3 as a float is not bit-identical to itself after a round trip, and a scoreboard that can show 4.1 vs 4.1000000000000005 is a bug a player will screenshot. Decimal columns make arithmetic exact. The same reasoning that bans float for prices bans it for scores."),
      C.p("jsonb for trick plays is a read-pattern decision: a trick's four cards are fetched as a whole, always alongside the trick row. Normalizing them into four rows quadruples the largest table for data never queried at card granularity. jsonb gives you the whole trick in one value, with the schema still enforcing the columns you DO query (hand, trick number, winner)."),
      C.p("Why no CREATE EXTENSION: gen_random_uuid() is in pg_catalog on Postgres 13+, but on 12 it would come from pgcrypto — and installing an extension needs database privileges that managed Postgres often withholds from the app role. A migration the app cannot apply for itself isn't portable. Pinning the requirement to Postgres 13+ (README: 'Postgres 13+') keeps migrations self-sufficient."),
      C.p("Embedded migrations (embed.go) mean the binary applies its own schema at startup — one artifact, one version, no out-of-band tooling, no drift between 'the code' and 'the schema it needs'. A deploy is copy-the-binary-and-run. That's the same self-containment discipline as the Go server running with no external deps by default."),
    ],
    alternatives: [
      { title: "ORM-managed schema", text: "Let GORM/golang-migrate with struct tags own the schema. You trade explicit SQL for magic, and the exact-type story (numeric(6,2), jsonb, partial unique indexes) gets buried in tags. Hand-written SQL migrations are the readable, diffable choice." },
      { title: "Float8 for scores", text: "Faster and simpler to read, and wrong at the margins — the round-trip inequality is real. Exact decimals are the non-negotiable." },
      { title: "External migration tooling", text: "A separate migration CLI (goose, atlas) is fine, but embedding means the binary is the truth and a fresh environment bootstraps itself. For one binary, embed wins." },
    ],
    improve: [
      { title: "Down migrations", text: "This repo ships forward-only — no down migrations. That's a deliberate discipline (schema moves forward, fixes are new migrations). Document it so a future you doesn't 'helpfully' add reverses." },
      { title: "Migration smoke test", text: "make test-db runs migrations against a throwaway Postgres container on every CI run — a schema typo is caught before it ever reaches production." },
    ],
    activity: {
      type: "quiz",
      q: "Why does the schema use numeric(6,2) for scores instead of float8?",
      opts: ["It's faster", "A score like 8.3 as a float is not equal to itself across a round trip — money-style arithmetic needs exact decimals", "Postgres forbids float", "It uses less disk"],
      correct: 1,
      explain: "Exact decimals: 4.1 + 0.1 must be exactly 4.2, not 4.2000000000000001.",
    },
    done: ["You can justify numeric, jsonb, embedded migrations, and no extensions."],
    refs: ["backend/migrations/*.sql", "backend/migrations/embed.go", "backend/internal/db/migrate.go"],
  }),
  C.step("m12s5", "Indexes & query design", {
    learn: [
      C.h("Every index exists for one query"),
      C.p("The schema's indexes are the query planner's cheat codes, and each one is commented with the exact query it serves. Read them as a lesson in 'what will the real queries be?' — because an index you can't name a query for is dead weight."),
    ],
    do: [
      C.p("Read each index in the migrations and match it to its query:"),
      C.code("game_seats_history_idx (user_id, finished_at DESC, game_id DESC) WHERE user_id IS NOT NULL\n  -> 'my last 20 games, newest first' — an index scan with NO sort node\n\ngame_seats_history_mode_idx (user_id, mode, finished_at DESC, game_id DESC)\n  -> the same query with ?mode=bots — mode wedged in as an equality prefix\n\ngames_client_game_id_key UNIQUE WHERE client_game_id IS NOT NULL\n  -> the idempotency guarantee: a retried upload collides and is returned\n\ngames_finished_at_idx (finished_at DESC, id DESC)\n  -> the admin history list walks games directly (no user filter)\n\nusers_merged_into_idx partial\n  -> 'everything absorbed into X' — a tiny minority, so partial", "sql"),
      C.p("Explain the trailing game_id in the history index: (1) it makes the keyset cursor work, (2) tuple comparison turns into a single range scan only when the index carries both columns in that order and direction."),
      C.p("Explain why history indexes are PARTIAL on user_id IS NOT NULL: roughly three seats in four are bots, and bot seats are never queried by user."),
    ],
    explain: [
      C.p("Why the whole ORDER BY lives in the index: an index on (user_id) alone would FIND the rows, but Postgres would then fetch every one of a heavy user's games from the heap, sort them, and throw all but 20 away. With (user_id, finished_at DESC, game_id DESC) the index is already sorted the way the query wants — the planner walks the index and reads 20 rows. That's the difference between O(log n + 20) and O(n log n)."),
      C.p("Why game_id trails finished_at: ties on finished_at (two games finishing in the same microsecond are real) need a deterministic tiebreak, AND the keyset cursor compares rows as a TUPLE (finished_at, game_id) — 'give me everything after this point'. A tuple comparison only becomes a single range scan when the index carries both columns in exactly that order and direction. The game_id isn't a nicety; it's what makes pagination a scan instead of a filter."),
      C.p("Why partial indexes: a predicate that's true for a small slice (user_id IS NOT NULL — bot seats are ~75% of rows and never queried by user) means the index covers only the useful rows. Smaller index, cheaper maintenance, same lookup. The merged_into and client_game_id indexes use the same trick for the same reason: index only what's queried."),
      C.p("The mode-filter index is the equality-prefix pattern: wedge the filtered column in front of the sort key. Without it, ?mode=bots degrades to scanning the whole history and discarding — for a filter that keeps a quarter of the rows, that's reading four pages to fill one."),
    ],
    alternatives: [
      { title: "Index everything", text: "An index per column looks safe and costs write amplification + disk on every insert. The discipline here — one index per named query, partial where possible — is the honest budget." },
      { title: "Cursor-free pagination", text: "Page numbers need OFFSET scans and drift on insert. The keyset cursor is the designed answer; the index is its engine." },
      { title: "Covering index", text: "Adding the columns the SELECT returns to the index makes it a covering index (no heap reads at all). A fine next step when the profile query gains more columns — the schema comments mark where." },
    ],
    improve: [
      { title: "EXPLAIN as a habit", text: "Before adding any query, run EXPLAIN ANALYZE on the largest table shape you expect. The schema's comments already model that habit — carry it forward." },
      { title: "Index maintenance monitoring", text: "Track index bloat and unused indexes via pg_stat_user_indexes. A query that stops using its index is either optimized away or a query you forgot you had." },
    ],
    activity: {
      type: "quiz",
      q: "The history index ends with game_id DESC after finished_at DESC. What is game_id's job?",
      opts: ["A tiebreak and the keyset cursor's second component — making pagination a single range scan", "To save space", "A naming convention", "To speed up inserts"],
      correct: 0,
      explain: "Ties on finished_at need a deterministic tiebreak, and the tuple comparison only becomes a range scan when the index carries both columns in that order.",
    },
    done: ["You can explain each index's query and the partial/trailing-column patterns."],
    refs: ["backend/migrations/0001_init.sql", "backend/migrations/0003_games_finished_idx.sql", "backend/docs/API.md (GET /v1/me/games)"],
  }),
  C.step("m12s6", "Optional persistence & the bounded queue", {
    learn: [
      C.h("Degrade, don't fail"),
      C.p("Postgres is optional. With no DATABASE_URL the server runs exactly as it always has — tables work, nothing is recorded, REST answers 503 persistence_disabled. A database that dies mid-game never interrupts play: recording sits behind a bounded queue that drops records rather than stalling a table."),
    ],
    do: [
      C.p("Trace the two failure postures and state them in one sentence each:"),
      C.code("1. No DATABASE_URL at startup\n     -> tables work, nothing recorded, /v1 answers 503 persistence_disabled\n     -> DATABASE_REQUIRED=true flips this into a startup failure instead\n\n2. Database dies MID-game\n     -> play continues without interruption\n     -> recording sits behind a BOUNDED queue: it drops records\n        rather than ever stalling a table\n\n3. Redis dies (module 13)\n     -> routing degrades (more redirects), play never stops", "text"),
      C.p("Explain the difference between 'optional at startup' and 'degrading at runtime' — why are they two different mechanisms?"),
      C.p("Answer: why does the bounded queue DROP records rather than queue unboundedly? What breaks with an unbounded queue?"),
    ],
    explain: [
      C.p("'Optional at startup' and 'degrading at runtime' are two different mechanisms because they protect different things. Startup-optional keeps `make run` and the whole test suite dependency-free — the server is a zero-infrastructure product (module 10.1). Runtime-degrading protects an in-flight game: the moment a table waits on a write, latency becomes gameplay, and a dead database becomes a dead game. Recording behind a queue means the table never touches the database synchronously — it posts to a queue and moves on."),
      C.p("Why DROP rather than queue unboundedly: an unbounded queue under a long database outage grows without limit — memory, then disk, then the server dies, which DOES interrupt play. A bounded queue has a hard ceiling: when it's full, new records are dropped and a counter increments. That's a graceful, observable degradation — you lose some history during an outage, never the game itself. The alternative (unbounded) converts a database outage into a server outage, which is strictly worse."),
      C.p("DATABASE_REQUIRED=true is the operator's choice: for an installation where history is the product, start-up failure beats silent non-recording. The default is lenient; production can opt into strictness. Same posture as JWT_SECRET becoming mandatory under ENV=production (module 15) — defaults are forgiving, production flips the screws."),
      C.p("The queue sits in front of the store, not the game: rooms post completed-game records, the queue flushes to Postgres with retry, and drops are counted. That counting is the observability hook (module 14) — a rising drop counter is an incident signal, not silent data loss."),
    ],
    alternatives: [
      { title: "Require the database", text: "A hard dependency simplifies the story but kills the zero-infra first-run experience and the dependency-free test suite. Optional-with-opt-in-strict is the pragmatic middle." },
      { title: "Queue with infinite retention", text: "Never drop, grow until the disk fills. Turns a DB outage into a server outage — the exact failure mode the bounded queue exists to prevent." },
      { title: "Synchronous writes on the hot path", text: "Record inside the room's apply(). Correct and simple, and one slow database call makes the whole table lag. The queue is the latency-isolation move." },
    ],
    improve: [
      { title: "Expose the drop counter", text: "A metric for records dropped by the bounded queue is the incident's early warning (module 14.3). Wire it before the queue ever drops anything." },
      { title: "Replay from the event log", text: "Because game_tricks/records derive from events (module 2.7), a future 're-record lost games' could replay. The drop is graceful because it's recoverable-by-design." },
    ],
    activity: {
      type: "quiz",
      q: "The database dies mid-game. What happens to a table in progress?",
      opts: ["It stalls until the DB returns", "Play continues; recording drops records rather than stalling", "It crashes", "Players are disconnected"],
      correct: 1,
      explain: "The table never touches the DB synchronously — a bounded queue isolates latency, and full means drop, never stall.",
    },
    done: ["You can state both degradation postures and the bounded-queue argument."],
    refs: ["backend/README.md (Known limitations)", "backend/internal/db", "backend/docs/PERSISTENCE.md"],
  }),
]));

REGISTER(C.module("m13", "🔀", "Redis, Pub/Sub & Scaling", "the registry, the actor, the topology", [
  C.step("m13s1", "Why Redis at all", {
    learn: [
      C.h("The redirect problem"),
      C.p("A room lives in the memory of ONE node. When there are two nodes, a client can connect to the wrong one. Redis is the shared directory that answers 'where does room X live?' — enabling a redirect instead of a dead table. And the crucial design stance: Redis is advisory, not authoritative."),
    ],
    do: [
      C.p("State the problem in one line: with N nodes, which node holds a given table?"),
      C.p("Sketch the two modes of knowing:"),
      C.code("without Redis (single node):\n  every room lives here -> every join routes here -> no problem\n\nwith Redis (N nodes):\n  each node registers the rooms it holds in a shared registry\n  client hits node A for a room on node B\n    -> A looks up the registry -> error { code: 'redirect', endpoint: B }\n    -> client reconnects to B\n\nand the load balancer hashes on ?room= so most joins land\non the right node in the FIRST place — redirects are the fallback, not the norm.", "text"),
      C.p("Explain the phrase 'advisory, not authoritative' in your own words, then read the README's claim: 'an outage degrades routing, it does not stop play.'"),
    ],
    explain: [
      C.p("The problem Redis solves is horizontal-scaling bookkeeping: in-memory rooms are owned by a node, and a shared registry is the only way a wrong-node client can learn the truth. Every node writes 'I hold room X' and reads 'who holds room Y'. Without it, a two-node deployment would fail half of all joins by hitting the wrong node with no way to recover."),
      C.p("Why advisory, not authoritative: the registry is a CACHE of reality, not reality. The rooms themselves live in node memory; the registry only says where. If Redis goes down, the rooms are unaffected — a client that lands on the wrong node just can't be redirected, and (with LB hashing on ?room=) most joins never need the registry at all. Making Redis authoritative would mean Redis downtime stops play — turning a convenience into a failure domain. The one-sentence design stance: the game must never depend on infrastructure it can do without."),
      C.p("Why hash on ?room= in the load balancer: redirects work but cost a connect/reconnect round trip. Consistent hashing on the room code sends the join to the node that most likely holds the table — making redirects rare rather than routine. The registry then catches the misses instead of bearing the whole routing load."),
    ],
    alternatives: [
      { title: "Sticky sessions only", text: "LB stickiness alone can't route a NEW player to an EXISTING room they weren't sticky to. The registry (or hashing) is needed precisely for 'join a room created by someone else'." },
      { title: "Room ownership in the LB", text: "The load balancer could be the registry — but then the LB is a stateful system, exactly what LBs should avoid. Redis keeps state where state belongs." },
      { title: "Broadcast every join to every node", text: "A multicast join would let any node answer for any room without a registry — and doubles all game traffic with noise. The registry is the surgical answer." },
    ],
    improve: [
      { title: "TTL + heartbeat the registry", text: "Registrations need expiry: a node that dies leaves stale entries. Heartbeat-renewed TTLs make the registry self-healing — the standard distributed-dictionary pattern." },
      { title: "Fall back gracefully", text: "When the registry read fails (Redis down), the server should still accept joins with a best-effort local lookup — degrading routing, never refusing play." },
    ],
    activity: {
      type: "quiz",
      q: "Redis goes down in a two-node deployment. What happens?",
      opts: ["All games stop", "Routing degrades (more redirects), play continues — Redis is advisory, not authoritative", "The server crashes", "Rooms are lost"],
      correct: 1,
      explain: "Rooms live in node memory; Redis is only the 'where does room X live' directory. Its absence degrades routing, not play.",
    },
    done: ["You can state the redirect problem and why Redis is advisory."],
    refs: ["backend/README.md (Scaling out)", "backend/internal/store/registry.go"],
  }),
  C.step("m13s2", "The room registry in action", {
    learn: [
      C.h("Register, lookup, redirect"),
      C.p("Three operations, one key-value namespace. Each node registers every room it holds; a join that reaches the wrong node looks up the owner and hands back a redirect frame; the client reconnects to the right node. PUBLIC_URL tells the registry which endpoint to point back at."),
    ],
    do: [
      C.p("Trace the redirect round trip frame by frame:"),
      C.code("client -> LB -> node A   join room 7QF2\nnode A: room 7QF2 local?  no.\nnode A -> redis: GET room:7QF2       -> node B\nnode A -> client: error { code: 'redirect', endpoint: 'ws://nodeB:8080/ws' }\nclient -> node B   join room 7QF2     -> seated, plays on\n\nand with LB hashing on ?room=7QF2, the first join usually\nlands on B directly — no redirect at all.", "text"),
      C.p("Explain what PUBLIC_URL is for: the registry stores an address clients can reach, which may be the internal node address or a public tunnel — the operator controls what redirects point at."),
      C.p("Explain the expiry concern: a registration with a TTL renewed by a live node means a crashed node's rooms age out instead of pointing forever at a dead endpoint."),
    ],
    explain: [
      C.p("The registry is a flat key → endpoint map (room:7QF2 → ws://nodeB:8080/ws). Registration happens when a node creates a room; lookup happens only on the miss path. That asymmetry is why it's cheap: the happy path (hash on ?room=) never touches Redis, and the registry exists to make the rare miss recoverable."),
      C.p("PUBLIC_URL is the address of record: with a tunnel or a public endpoint in front, the redirect must point at something the CLIENT can reach — which is not necessarily the node's internal IP. Separating 'where the room is' (internal) from 'where the client reaches it' (public) is the classic NAT/egress lesson, encoded as one config var."),
      C.p("TTL + heartbeat is the self-healing detail: a crashed node's registrations must not point forever at a dead address. Live nodes renew their rooms' TTLs; stale entries expire on their own. The registry is a cache of liveness, and caches need expiry or they rot."),
    ],
    alternatives: [
      { title: "Registry without TTL", text: "Fixed entries survive crashes as dead pointers. TTL+heartbeat is a few lines that make crash-cleanup automatic — the cheapest self-healing you'll ever buy." },
      { title: "Client-side room table", text: "Ship the room→node map in the lobby frame so clients cache it. It would go stale exactly when you need it (a node just died). Server-side registry + redirect is honest." },
    ],
    improve: [
      { title: "Redirect metrics", text: "Count redirects per node (callbreak_ws_redirects_total). A sudden spike means hashing is missing its mark — either a misconfigured LB or a node that just died." },
      { title: "Registry namespace hygiene", text: "Prefix keys by environment (callbreak:prod:room:7QF2) so a shared Redis across staging/prod can't cross-route a room code." },
    ],
    activity: {
      type: "quiz",
      q: "A client's join reaches the wrong node. What does the wrong node do?",
      opts: ["Silently create a duplicate room", "Look up the registry and return a redirect frame pointing at the owning node", "Drop the connection", "Play the game anyway"],
      correct: 1,
      explain: "Lookup → redirect → the client reconnects to the owner. Never a silent duplicate.",
    },
    done: ["You can trace the redirect round trip and explain PUBLIC_URL + TTL."],
    refs: ["backend/internal/store/registry.go", "backend/internal/ws", "backend/PROTOCOL.md (error redirect)"],
  }),
  C.step("m13s3", "Pub/sub inside the server", {
    learn: [
      C.h("Three different kinds of 'event'"),
      C.p("The project has three event mechanisms, and conflating them is the classic design error: the room's INBOX channel (message to one actor), the engine's EVENT log (facts a host drains), and the socket's FRAME fan-out (redacted views to each seat). None of them is Redis pub/sub — and knowing why is the whole lesson."),
    ],
    do: [
      C.p("Sort the three mechanisms — write one line for each: what carries it, how many consumers, what it's for:"),
      C.code("1. room.inbox (Go channel)\n   carries: inbound frames + timers, one message at a time\n   consumers: ONE — the room goroutine\n   job: serial ownership of all table state (the actor)\n\n2. engine events (the module 2.7 sealed outbox)\n   carries: facts — CardPlayed, TrickWon, HandOver, GameOver\n   consumers: the HOST drains them, once\n   job: pure side effects out of the pure engine\n\n3. socket fan-out (the redacted view)\n   carries: the per-seat redacted GameView to every seat\n   consumers: four sockets\n   job: what a player is allowed to see, when it changes", "text"),
      C.p("Answer the 'why not Redis pub/sub?' question: game state is owned by ONE node — a cross-node bus would fan every move to every node for no reader. Where does cross-node communication actually need to happen?"),
      C.p("Trace one card play through all three: the frame lands in the inbox → the actor applies it to the engine → the engine emits CardPlayed → the host drains it and publishes redacted views → four sockets get their own view."),
    ],
    explain: [
      C.p("The inbox channel is an actor's message queue, not a pub/sub bus: exactly one consumer (the room goroutine) and exactly-once serial delivery. Pub/sub's core feature — many subscribers — would BREAK the actor, because two goroutines reading the same room state is the race the actor exists to prevent. When you hear 'pub/sub' in this codebase, the inbox is the wrong mental model."),
      C.p("The engine event log is a pure-facts outbox (module 2.7): the engine records what happened, the host drains it once. It's one-consumer by design — the purity boundary between 'the rules' and 'everything the rules need to trigger'."),
      C.p("The socket fan-out IS the closest thing to pub/sub — one state change, four receivers — but it's not a broker: the room goroutine itself writes four redacted views (viewFor per seat) to four sockets. The 'pub' is a loop, not a subscription model, and redaction happens in that loop."),
      C.p("Why no Redis pub/sub for game state: the state is owned by one node and read by that node's four sockets. A cross-node bus would broadcast every move to every node — most of which hold zero interested sockets. Redis pub/sub earns its complexity when readers are genuinely distributed (a spectator service, a stats aggregator); here there are none. The registry (module 13.1) is the ONLY cross-node need, and it's a directory, not a bus."),
    ],
    alternatives: [
      { title: "Redis pub/sub for every view", text: "Publishing each view to a channel every node subscribed to would deliver state to idle nodes for nothing — O(nodes) writes per move, O(1) readers. The registry-only design is the honest cross-node surface." },
      { title: "A real message broker", text: "Kafka/NATS for room messages would add delivery guarantees no one reads. The inbox channel already gives the actor its one guarantee: serial order. A broker is the 'better way' only when rooms can migrate nodes (module 13.4's snapshot idea)." },
      { title: "Shared database for state", text: "Storing room state in Postgres would let any node serve any room — and turns every move into a DB round trip with a lost update risk. In-memory actor + registry redirect is the latency-correct choice." },
    ],
    improve: [
      { title: "Event log for analytics", text: "The engine events are already the shape of a replay/analytics stream. A future spectator or bot-calibration pipeline could consume them — at which point a real bus earns its keep." },
      { title: "Room snapshotting (the designed-but-unbuilt)", text: "Snapshotting a room to Redis so another node can rehydrate it is the planned step toward zero-loss restarts — and the one feature that WOULD make a distributed bus meaningful. The README names it; it's your future milestone." },
    ],
    activity: {
      type: "quiz",
      q: "Why is the room's inbox channel NOT pub/sub?",
      opts: ["Channels are slow", "It has exactly one consumer — the room goroutine — and serial delivery is what makes the actor safe. Pub/sub's many-subscribers model would introduce the race it exists to prevent", "Go lacks pub/sub", "It's on the hot path"],
      correct: 1,
      explain: "The actor needs one reader and serial order; pub/sub means many readers. Different tools, different jobs.",
    },
    done: ["You can distinguish the inbox, the event log, and the socket fan-out — and why no Redis pub/sub."],
    refs: ["backend/internal/room/broker.go", "backend/internal/engine", "backend/README.md (A table is an actor)"],
  }),
  C.step("m13s4", "Horizontal scaling topology", {
    learn: [
      C.h("Nodes, LB, drain"),
      C.p("Scaling is: any number of nodes, a load balancer hashing on ?room=, the Redis registry for misses, and graceful drain so a node leaving doesn't yank games mid-hand. One node is a complete product; N nodes is a config change, not a rewrite."),
    ],
    do: [
      C.p("Draw the topology and label each hop:"),
      C.code("players -> LB (hash on ?room=) -> node A | node B | node C\n                                          |     |       |\n                                          +-- Redis registry (advisory)\n\nnode = one binary = many room goroutines + ws edge + REST\nLB   = routes joins by room code; redirects handle the misses\nRedis= 'where does room X live' (module 13.1-13.2)\n\nnew node joins the fleet: start it, it registers itself, LB sends it joins\ndeparting node: SIGTERM -> stop accepting -> tell every table it's going\n  away -> wait SHUTDOWN_GRACE -> exit (module 14.6)", "text"),
      C.p("Answer: why is scaling a config change and not a rewrite? Point at the pieces that don't change (engine, actor, protocol, redaction)."),
      C.p("Answer: what is the ONE thing that limits tables per node, and why?"),
    ],
    explain: [
      C.p("The topology works because the actor model (module 10.1) keeps nodes stateless from each other's perspective: each room is owned by one node, communicates only with its four sockets, and needs nothing from its neighbors. The only cross-node question is 'where does room X live' — answered by the registry. That single question being the ONLY coupling is what makes 'add a node' a config change: the engine, the actor, the protocol, and the redaction are all node-local."),
      C.p("A departing node must drain, not vanish: SIGTERM → stop accepting new connections → tell every table 'going away' (players get server_draining) → wait up to SHUTDOWN_GRACE → exit. Players reconnect to a fresh table rather than resuming mid-hand — the graceful version of a crash. The README is honest about the current ceiling: tables are in-memory only, so a restart ends hosted games; snapshotting rooms (module 13.3's designed-but-unbuilt) is the future step to zero-loss."),
      C.p("Why tables-per-node is capped by websocket fan-out, not game logic: a room is a few kilobytes and one goroutine, so CPU/memory per table is trivial; the real cost is concurrent connections (file descriptors, socket buffers, the event loop's per-connection work). MAX_ROOMS (50,000) is the explicit cap, but the practical ceiling is how many live sockets one node's network stack sustains. The loadtest's 800 concurrent players on one core (module 14.5) is the empirical shape of that ceiling."),
    ],
    alternatives: [
      { title: "Stateless rooms in shared state", text: "Put room state in Postgres/Redis so any node serves any room. Removes redirects and kills latency — every move becomes a distributed write with a lost-update risk. The actor-in-memory + registry-redirect split is the latency-correct trade." },
      { title: "Raft/shared nothing cluster", text: "A consensus-replicated room store (like etcd) would give fault-tolerant rooms. Massive machinery for a game where a reconnect to a fresh table is acceptable. Snapshotting is the proportional step." },
    ],
    improve: [
      { title: "Autoscaling triggers", text: "Scale on websocket count and room count, not CPU: the binding constraint is fan-out (module 13.4). callbreak_players_connected per node is your autoscaler's signal." },
      { title: "Room-code length", text: "The 4-char code (~1M combos) collides ~2% at 200 tables and is guessable by a stranger. Lengthening means changing RoomCodeLength AND the client's _newCode together — a documented, deliberate future change (module 10.6)." },
    ],
    activity: {
      type: "quiz",
      q: "What is the ONE thing that limits tables per node?",
      opts: ["CPU", "RAM", "WebSocket fan-out — a room is a few KB and one goroutine; connections are the real cost", "Database writes"],
      correct: 2,
      explain: "Room logic is trivial; concurrent connections (fds, buffers, per-connection work) are the ceiling. MAX_ROOMS is the explicit guard on top.",
    },
    done: ["You can draw the topology and explain why scaling is a config change."],
    refs: ["backend/README.md (Scaling out, Known limitations)", "backend/internal/match", "backend/cmd/server"],
  }),
  C.step("m13s5", "Ceilings, capacity & the loadtest", {
    learn: [
      C.h("Measure the ceiling, don't guess it"),
      C.p("The loadtest drives real websockets through the real protocol, playing only cards the server said were legal, and reports move→view wall time — the thing a player actually feels. The published numbers are the capacity contract, not a benchmark boast."),
    ],
    do: [
      C.p("Run the loadtest and read the numbers:"),
      C.code("make build\n./bin/loadtest -url ws://localhost:8080/ws -tables 200 -humans 4\n\n200 tables x 4 humans = 800 concurrent players, 55,440 moves,\non ONE laptop core, pacing compressed to 5ms:\n\n  p50 625µs | p90 5.3ms | p99 13.6ms | max 38ms\n  zero dropped connections, zero turn timeouts, 198/200 games finished", "shell"),
      C.p("Interpret every number: what does p99 mean for a player? Why 'zero turn timeouts'? Why 198/200 (and what are the two)?"),
      C.p("Answer the capacity questions: what is the real cost per table, and how does the number of concurrent websockets bound a node before CPU does?"),
    ],
    explain: [
      C.p("The loadtest measures wall time from sending a move to receiving the view that reflects it — not a synthetic internal metric, but the perception loop a player experiences as 'the table responded'. p50 625µs means the median move round-trips in well under a millisecond; p99 13.6ms means even the worst latency tail is imperceptible. The distribution, not the average, is the honest number — p99 is where 'the game feels laggy' actually lives."),
      C.p("'Only cards the server said were legal' is what makes the harness cheat-proof: a bot that sent garbage moves would fail legality checks and never complete a game. The loadtest playing the real protocol end to end means the numbers measure the real server, not a munged simulation."),
      C.p("Why 198/200: two tables collided on random room codes (the ~2% at 200 tables from module 13.4) and the server correctly refused the second table's start. The harness is honest about its own collision, and the server is correct in refusing — that pair of numbers IS the failure analysis. Zero turn timeouts under 800 players on one core is the practical proof of the actor model's efficiency claim."),
      C.p("The capacity story: 800 concurrent players on one laptop core shows the binding constraint is websocket fan-out (file descriptors, per-connection buffers), not CPU. A room is a few KB resident — the actor model's density (module 10.1) is what makes that possible. When you scale (module 13.4), you're adding fan-out headroom, not compute."),
    ],
    alternatives: [
      { title: "General load tools (k6, vegeta)", text: "They can hammer HTTP but don't speak the game protocol or check legality. The bespoke loadtest measures the REAL game surface — a general tool would measure a synthetic approximation." },
      { title: "Simulation with fake time", text: "Driving the engine with fake time (like the client's fake_async) tests logic but not the network stack. The loadtest's real sockets exercise the full path: upgrade, auth, routing, actor, view broadcast." },
    ],
    improve: [
      { title: "Latency regression in CI", text: "Gate on p99: a release that pushes p99 past a threshold fails. That turns the published numbers into a living contract, not a screenshot." },
      { title: "Adversarial load", text: "Add a flood mode (frames over budget, oversize payloads) to verify the rate limits and the 4096-byte cap actually protect the server under attack, not just under load." },
    ],
    activity: {
      type: "quiz",
      q: "Why does the loadtest play only cards the server said were legal?",
      opts: ["To make the bots honest", "So the harness can't cheat the numbers — it measures the real server completing real games, not a munged simulation", "To save CPU", "Because the server requires it"],
      correct: 1,
      explain: "Illegal moves would fail checks and never finish games; legality is what makes the measurement real.",
    },
    done: ["You can interpret the p50/90/99 table and explain the 198/200."],
    refs: ["backend/cmd/loadtest/main.go", "backend/README.md (Measured)", "backend/Makefile"],
  }),
]));

REGISTER(C.module("m14", "📈", "Monitoring, Metrics & Ops", "observe it, prove it, run it", [
  C.step("m14s1", "Observability: logs, metrics, traces", {
    learn: [
      C.h("Three signals, three questions"),
      C.p("Logs answer 'what exactly happened?', metrics answer 'is something trending wrong?', traces answer 'where did the latency go?'. The server ships JSON logs + Prometheus metrics + a health surface; traces are the one it deliberately skips — and knowing why is part of the design."),
    ],
    do: [
      C.p("Classify each of these as logs, metrics, or traces — and say which question it answers:"),
      C.code("\"player 7QF2/seat2 placed bid 3\"     -> a LOG: what happened\ncallbreak_rooms_active at 42            -> a METRIC: is the fleet healthy\njoin -> auth 2ms -> route 1ms -> ...   -> a TRACE: where did the time go", "text"),
      C.p("Explain the server's logging posture: ENV=production switches to JSON logs, and LOG_LEVEL picks the verbosity. Why JSON for machines and not a pretty human format?"),
      C.p("Answer the 'why no traces' question: what would a trace add for a game server where a move's journey is a single node and a few milliseconds?"),
    ],
    explain: [
      C.p("Logs and metrics serve different failure modes: metrics trend (rooms_active rising, p99 climbing) and alert before something breaks; logs explain AFTER it breaks ('which room panicked, what was the last frame'). You can't alert a log line and you can't debug a counter — which is why both exist."),
      C.p("Why JSON logs in production: the logs are consumed by a machine (an aggregator, a dashboard, a grep across nodes), and JSON is the machine format that still keeps one event per line. A pretty human format dies the moment you have three nodes and a log search box. Development keeps human-readable logs because there's no aggregator; production flips to JSON because there is."),
      C.p("Why no distributed traces: a trace's value is following a request across many services. Here a move crosses at most one node — the ws edge into a room goroutine — and the whole journey is a few milliseconds. That's not where latency hides. The honest observability surface for this server is: per-node metrics for trends, JSON logs for post-mortems, and the health endpoints for liveness. Adding a tracing agent would instrument nothing that crosses a boundary."),
      C.p("The principle to carry away: observability is proportional to the failure surface. A distributed system needs distributed tracing; a single-node actor server needs counters + logs + health. Build the instrumentation your topology actually reads."),
    ],
    alternatives: [
      { title: "OpenTelemetry traces", text: "Adds a collector, exporters, and span baggage. Valuable when rooms migrate nodes or a move crosses services (module 13.4's future snapshotting would justify it). Today the journey is one node — traces would be noise." },
      { title: "Metrics-only, no logs", text: "Counters tell you something is wrong, not what. The JSON log of the failing room is what makes an incident fixable. Both signals, always." },
      { title: "Graylog/Splunk-style logging", text: "A log aggregator over the JSON stream is the natural companion when nodes multiply. Start with JSON lines + jq; add a collector when the fleet outgrows grep." },
    ],
    improve: [
      { title: "Correlation ids", text: "Stamp every log line from one room with room + seat, so 'what happened to table 7QF2' is a single grep. Cheap, and the single highest-value logging habit." },
      { title: "Audit the log volume", text: "Game logs at LOG_LEVEL=debug are chatty (every frame). Default to info and treat debug as on-demand — an over-logging server hides the signal it exists to expose." },
    ],
    activity: {
      type: "quiz",
      q: "The server skips distributed tracing. Why is that the right call?",
      opts: ["Tracing is expensive", "A move's journey crosses at most one node in a few milliseconds — there's no cross-service latency for a trace to reveal", "Prometheus can't do it", "The server has no logs"],
      correct: 1,
      explain: "Observability is proportional to the failure surface. Single-node actor server → metrics + logs + health; tracing earns its cost only when requests cross services.",
    },
    done: ["You can classify the three signals and justify the no-traces stance."],
    refs: ["backend/internal/obs/obs.go", "backend/README.md (Configuration: ENV, LOG_LEVEL)"],
  }),
  C.step("m14s2", "Health & readiness", {
    learn: [
      C.h("Two probes, two meanings"),
      C.p("GET /healthz says 'the process is alive'. GET /readyz says 'the process can take traffic' — and goes 503 while draining so the load balancer stops sending new players before the tables are torn down. Splitting liveness from readiness is what makes drains graceful."),
    ],
    do: [
      C.p("Answer the 'why two endpoints' question with a scenario: what breaks if a draining node still answered 200 on readiness?"),
      C.p("Trace a deploy:"),
      C.code("1. operator sends SIGTERM to node B\n2. B stops accepting new connections\n3. /readyz starts returning 503   <- LB stops sending B new joins\n4. B tells every table 'server_draining'  (players get the frame)\n5. B waits up to SHUTDOWN_GRACE\n6. B exits\n\nplayers at B's tables reconnect to a fresh table (module 7.4)\nrather than being cut mid-hand.", "text"),
      C.p("Explain why readiness going 503 BEFORE tables drain matters — what would happen in the reverse order?"),
    ],
    explain: [
      C.p("Liveness and readiness answer different operator questions. /healthz is 'is the process up' — a crash-looping container still 200s healthz if the HTTP server runs. /readyz is 'can it take new work' — during drain it says no. Splitting them means the orchestrator can restart a dead container (healthz) while the load balancer independently stops feeding it (readyz)."),
      C.p("The drain ordering is the subtle part: readiness must flip to 503 BEFORE tables are told to go away, so the LB stops sending new joins into a node that's about to vanish. If you drained tables first, new joins would still arrive during the drain window and immediately be told server_draining — a worse player experience than just routing them elsewhere from the start."),
      C.p("Graceful drain is the difference between 'a deploy' and 'a kick': players at the departing node's tables get a polite server_draining frame and reconnect to a fresh table, instead of a hard socket drop mid-hand. The reconnect flow (module 7.4) is what makes drain survivable — the player's seat was held, then reclaimed."),
    ],
    alternatives: [
      { title: "One health endpoint", text: "A single probe can't distinguish 'alive but draining' from 'healthy'. The LB would either keep sending joins into a dying node or, worse, black-hole a healthy node during a slow drain. Two probes, two semantics." },
      { title: "LB-level drain (remove from pool)", text: "You can drain by telling the LB to stop routing before killing the node. The readiness endpoint does it automatically and in-band — the LB doesn't need to know about the deploy." },
    ],
    improve: [
      { title: "Readiness beyond draining", text: "Make /readyz also reflect dependency health (can it reach Redis/Postgres) so the LB stops sending joins to a node whose registry or store is gone. Degrade routing, never play — the module 12.6 posture, on the probe." },
      { title: "Drain-time budget metrics", text: "Measure how long drains actually take vs SHUTDOWN_GRACE. A grace window that's regularly nearly exhausted is a signal the drain is too slow or the window too tight." },
    ],
    activity: {
      type: "quiz",
      q: "During a deploy, why must /readyz flip to 503 BEFORE tables are told to drain?",
      opts: ["To save CPU", "So the LB stops sending new joins into a node that's about to vanish — new players route elsewhere instead of being told server_draining immediately", "Healthz needs it", "It doesn't matter"],
      correct: 1,
      explain: "Order matters: stop the inflow before the outflow. New joins must not arrive into a node that's already leaving.",
    },
    done: ["You can explain liveness vs readiness and the drain ordering."],
    refs: ["backend/internal/obs/obs.go", "backend/README.md (Operating it)"],
  }),
  C.step("m14s3", "The metrics catalog", {
    learn: [
      C.h("What to count, what to alert on"),
      C.p("The Prometheus endpoint exposes a specific catalog. Almost none of it needs an alert — the art is picking the handful that signal real problems from the noise that describes normal operation."),
    ],
    do: [
      C.p("Group the metrics by what they measure:"),
      C.code("capacity / load\n  callbreak_rooms_active           live tables per node\n  callbreak_players_connected      open sockets per node\n  callbreak_matchmaking_open_tables  quickplay tables waiting to fill\n\ngame correctness\n  callbreak_games_started_total / callbreak_games_finished_total\n  callbreak_turn_timeouts_total    turns lost to clock expiry\n  callbreak_protocol_errors_total  malformed/rejected frames\n  callbreak_autoplay_entered_total / callbreak_bot_takeovers_total\n\ntransport health\n  callbreak_ws_messages_in_total / out_total\n  callbreak_ws_send_drops_total    views dropped because a socket was full\n  callbreak_reconnects_total       how often clients come back\n  callbreak_room_step_seconds      histogram of room actor step latency", "text"),
      C.p("Pick the SIX the README says are 'the ones worth alerting on' and justify each:"),
      C.code("callbreak_rooms_active\ncallbreak_players_connected\ncallbreak_matchmaking_open_tables\ncallbreak_turn_timeouts_total\ncallbreak_ws_send_drops_total\ncallbreak_room_step_seconds", "text"),
      C.p("Explain why the message counters (in/out) are NOT alert-worthy."),
    ],
    explain: [
      C.p("The alertable six share one property: each is a symptom of a problem a player would feel. rooms_active and players_connected are capacity — a node at its fan-out ceiling explains lag. matchmaking_open_tables is the product signal — stuck at zero with players waiting means the matcher broke. turn_timeouts_total is a correctness smell — rising timeouts mean the clock and the actor disagree, a rules-level bug. ws_send_drops_total means views were thrown away because a socket was full — the player is being starved. room_step_seconds is the actor's latency distribution — a slow actor step is the one thing that makes every move at that table slow."),
      C.p("Why the message counters are NOT alert-worthy: ws_messages_in/out_total describe normal traffic — they move with player count and tell you nothing bad until they're wildly off from expectations, which the capacity metrics already capture better. A metric you can't turn into an action ('and then what?') is noise. The discipline of the catalog is naming a threshold and a response for each alertable metric and leaving the rest as telemetry."),
      C.p("The histogram (room_step_seconds) is the closest thing to a trace in this stack: it shows the latency distribution of the room actor's apply step. A rising p99 here is the root-cause signal behind every 'the table felt slow' complaint — one metric that explains the others."),
      C.p("autoplay_entered and bot_takeovers deserve watching even without alerts: a spike means players are abandoning mid-game, which is a product-health signal before it's an ops one."),
    ],
    alternatives: [
      { title: "Alert on everything", text: "Every counter with a threshold = alert fatigue = no alerts read. The six were chosen precisely because each names a felt problem; the rest are telemetry." },
      { title: "SLOs instead of raw counters", text: "Frame alerts as error budgets (e.g. 99.9% of views delivered). SLOs are the mature version of 'alert on the felt symptom'; raw counters are where you start." },
      { title: "RUM (real user monitoring)", text: "Client-side latency telemetry would measure what players ACTUALLY feel across networks. The server p99 is the supply side; RUM is the demand side. A future addition when you want true end-to-end numbers." },
    ],
    improve: [
      { title: "Alert thresholds in the runbook", text: "Each of the six deserves a 'threshold + response' line in the ops doc (module 14.6). A metric without a threshold is a number; with one, it's an alarm." },
      { title: "Dashboard layout", text: "One Grafana row per group (capacity / correctness / transport) turns the catalog into an at-a-glance triage screen." },
    ],
    activity: {
      type: "quiz",
      q: "Why is callbreak_ws_messages_in_total NOT alert-worthy?",
      opts: ["It's hard to measure", "It describes normal traffic that moves with player count — you can't turn it into an action, unlike the six felt-symptom metrics", "Prometheus can't count it", "It's too high"],
      correct: 1,
      explain: "An alert must name a threshold AND a response. Message counters are telemetry; the capacity/correctness metrics are the alarms.",
    },
    done: ["You can name the six alert-worthy metrics and justify each."],
    refs: ["backend/README.md (Operating it)", "backend/internal/obs/obs.go"],
  }),
  C.step("m14s4", "The admin dashboard", {
    learn: [
      C.h("See the tables, twist the knobs"),
      C.p("The token-gated /admin page is the operations cockpit: every live table (phase, seats, bids, tricks, pending clocks, each player's hand), recorded match history with per-hand scoreboards, and runtime pacing knobs (the TablePacing values from module 4.6, editable live and persisted to Postgres)."),
    ],
    do: [
      C.p("Explain why the dashboard is gated by ADMIN_TOKEN and how that differs from player auth:"),
      C.p("List what the 'live tables' view must show to debug a stuck table:"),
      C.code("for each live room:\n  phase (lobby/bidding/playing/handOver/gameOver)\n  seats + who's a bot + connected/autoplay flags\n  current bids, tricks won, running totals\n  every pending clock (whose turn, what deadline)\n  each player's full hand          <- the debugger's x-ray\n  the room's inbox depth            <- a stuck actor is visible as a backlog", "text"),
      C.p("Explain the runtime settings tab: the pacing knobs (BOT_THINK_MIN/EXTRA, TRICK_LINGER, BID_TIMEOUT, PLAY_TIMEOUTS...) are operator-editable and stored in runtime_settings so a restart keeps them."),
    ],
    explain: [
      C.p("The dashboard is observability for a stateful game, which metrics can't express: a stuck table isn't a counter, it's a phase that never advanced. Seeing 'room 7QF2 is in playing, seat 2 holds the turn, its clock expired 40 seconds ago, inbox depth 3' IS the diagnosis. Each player's hand is the x-ray — the one view that turns 'the table is stuck' into 'seat 2 has no legal move because of X'."),
      C.p("Why ADMIN_TOKEN and not player auth: the dashboard is an operator tool, not a user feature. A single strong token (empty by default, which disables the page entirely) is the honest security model — it names who can see every player's hand, and it's off unless you turn it on. Player auth (module 10.3) governs the game; ADMIN_TOKEN governs the view of all games."),
      C.p("The pacing knobs are the tuning loop made operational: instead of a redeploy to change TRICK_LINGER, an operator edits it live and the change persists in runtime_settings. That's the module 12.2 denormalization spirit applied to config — the admin dashboard is the UI, Postgres is the store, and a restart keeps the tuning."),
      C.p("The match-history view reuses the same tables the profile reads (module 12.2) — the dashboard is a second READER of the game grain, which is exactly why the schema normalized the way it did."),
    ],
    alternatives: [
      { title: "Metrics-only operations", text: "Counters tell you a table is stuck, not why. The dashboard's per-table x-ray is the difference between 'alert fires' and 'alert explains'." },
      { title: "SSH + psql", text: "Raw SQL could answer most dashboard questions. The dashboard packages the queries and the pacing edits into a UI any operator can drive — and the runtime_settings table is the durable home those edits need." },
      { title: "A separate admin service", text: "An isolated admin panel would need its own auth, deployment, and a read path into live rooms — which are in-memory. The dashboard lives in the server because the live-table view is a memory walk it can only do from inside." },
    ],
    improve: [
      { title: "A 'nudge' action", text: "A button to advance a stuck room (or cancel its autoplay) turns diagnosis into remediation from the same screen. The knob pattern proves the appetite exists." },
      { title: "Rate-limit the admin path", text: "ADMIN_TOKEN gating is coarse; an IP allowlist or a rate limit on /admin is the defense-in-depth next step for a view this privileged." },
    ],
    activity: {
      type: "quiz",
      q: "Why must the live-tables view show each player's hand?",
      opts: ["For fun", "It's the x-ray — seeing seat 2's hand turns 'the table is stuck' into 'seat 2 has no legal move because of X'", "Players asked for it", "The engine requires it"],
      correct: 1,
      explain: "A stuck table is a phase that never advanced; the hands are what explain why.",
    },
    done: ["You can explain the dashboard's three views and the ADMIN_TOKEN model."],
    refs: ["backend/internal/httpapi/admin.go", "backend/internal/httpapi/admin_ui.html", "backend/README.md (Operating it)"],
  }),
  C.step("m14s5", "Load testing & capacity planning", {
    learn: [
      C.h("The loadtest is a contract, not a script"),
      C.p("The loadtest (module 13.5) is the empirical answer to 'how many tables can one node hold?'. Capacity planning is then: measure the ceiling, add headroom, know your trigger to scale, and keep the contract honest with a regression gate."),
    ],
    do: [
      C.p("Run the numbers through a planning sketch for a target of 1,000 concurrent players:"),
      C.code("measured: 800 players on one core, p99 13.6ms\nper-node headroom rule: run at ~60% of the measured ceiling\n  -> one node serves ~480 players comfortably\n  -> 1,000 players needs 3 nodes (2 for load + 1 for loss)\n  -> scale trigger: callbreak_players_connected > ~450 per node\n  -> plus LB hashing on ?room= so redirects stay rare", "text"),
      C.p("Explain the three rules in the sketch: why 60% headroom, why a +1 node for loss, why scale on connections not CPU."),
      C.p("Add a regression gate: a CI job that fails a release if the loadtest p99 regresses past a threshold — the measured numbers become a living contract."),
    ],
    explain: [
      C.p("Headroom is the difference between capacity and safety: the measured ceiling (800 players) is the point where p99 starts climbing, and operating at 100% of it means any blip — a GC pause, a spike, a noisy neighbor — pushes you over. 60% is the standard comfort line: room to absorb a spike without the p99 moving. It's the same reason you don't run a database at 100% disk."),
      C.p("Why +1 for loss: if 2 nodes carry 1,000 players and one dies, the survivor takes 1,000 alone — instantly over its ceiling. Three nodes means losing one leaves 2 carrying the load under their shared headroom. N+1 is the cheapest insurance in capacity planning, and it's why the 'scale trigger' has to fire BEFORE the node is actually full."),
      C.p("Why scale on connections, not CPU: the loadtest proved the binding constraint is websocket fan-out (module 13.4), so a CPU-based autoscaler would scale late — CPU climbs only after the sockets are already saturated. The metric that predicts the ceiling is callbreak_players_connected; that's the trigger to scale."),
      C.p("A regression gate makes the loadtest a contract: a release that pushes p99 past the threshold fails CI, so latency debt is caught at review time instead of discovered by players. The published p50/90/99 (module 13.5) become the floor, not a footnote."),
    ],
    alternatives: [
      { title: "Synthetic scale math", text: "Estimate tables-per-node from goroutine/CPU theory instead of measuring. The actor's density surprises people (module 10.1); a measurement beats a guess, and the loadtest IS the measurement." },
      { title: "Over-provision and pray", text: "Run fat nodes with no trigger. Wastes money and still fails the day traffic surprises you — a trigger plus headroom turns surprise into process." },
      { title: "Autoscale on CPU only", text: "CPU-based triggers fire late for a fan-out-bound workload. The trigger must match the binding resource — here, connections." },
    ],
    improve: [
      { title: "A soak test", text: "Hours at full load, not minutes — leaks (goroutines, fds, memory) show up over time, and the loadtest at 5ms pacing won't find them. A weekly soak is the leak detector." },
      { title: "Latency budget per move", text: "Split the p99 into budgets (actor step, view broadcast, socket write) so a regression points at a layer, not a number. The room_step_seconds histogram is the first slice of that split." },
    ],
    activity: {
      type: "quiz",
      q: "Why scale on callbreak_players_connected rather than CPU?",
      opts: ["Connections are easier to count", "The loadtest proved websocket fan-out is the binding constraint — CPU-based autoscaling would fire late because CPU climbs only after sockets are already saturated", "CPU metrics are noisy", "Connections are cheaper"],
      correct: 1,
      explain: "The trigger must match the binding resource. Fan-out is the ceiling; connections are its predictor.",
    },
    done: ["You can plan capacity from the loadtest numbers and name the scale trigger."],
    refs: ["backend/cmd/loadtest/main.go", "backend/README.md (Measured)", "backend/internal/obs/obs.go"],
  }),
  C.step("m14s6", "Graceful shutdown & incident response", {
    learn: [
      C.h("Leave politely, recover loudly"),
      C.p("On SIGTERM the server stops accepting, tells every table it is going away, waits up to SHUTDOWN_GRACE, and exits. A panic costs one table, not the process. Incident response is the same reflex one level up: recover, learn, and make the next outage shorter."),
    ],
    do: [
      C.p("Write the shutdown sequence in order and justify each step:"),
      C.code("SIGTERM\n1. stop accepting new connections      (no new joins into a dying node)\n2. /readyz -> 503                       (module 14.2: stop the LB sending joins)\n3. tell every table 'server_draining'    (players get the frame, reconnect flow)\n4. wait up to SHUTDOWN_GRACE             (let in-flight moves finish)\n5. exit\n\nand the panic posture:\n  every room goroutine recovers, tells its players, and closes\n  -> one buggy table degrades, the other 49,999 are untouched", "text"),
      C.p("Write a mini runbook for the two most likely incidents. For each: symptom, likely cause, first action, fix, follow-up:"),
      C.code("INCIDENT 1: p99 climbing, players report lag\n  check: callbreak_room_step_seconds p99, players_connected vs ceiling,\n         ws_send_drops_total rising?\n  likely: a node near its fan-out ceiling (module 14.5)\n  first: scale out / drain the hot node\n  follow-up: add the scale trigger if missing\n\nINCIDENT 2: turn timeouts rising\n  check: turn_timeouts_total, admin dashboard -> a stuck room?\n  likely: actor step blocked or a clock/phase disagreement\n  first: inspect the room on the dashboard (module 14.4)\n  follow-up: fix the rules bug; add the failing case to the engine tests", "text"),
      C.p("Answer the 'why recover per-table' question: what's the trade vs crashing the whole process?"),
    ],
    explain: [
      C.p("The shutdown sequence is graceful exit by construction: stop the inflow before the outflow (module 14.2's ordering), then give in-flight moves a bounded window, then exit. SHUTDOWN_GRACE (20s default) is the budget — long enough for a trick to resolve, short enough that a stuck room can't hold the deploy hostage. The reconnect flow (module 7.4) is what makes this survivable for players."),
      C.p("Recover-per-table is a blast-radius decision: a panic in one room goroutine means that table's four players are told and the room closes — the other 49,999 rooms never notice. Crashing the whole process on any panic converts one bug into a fleet-wide outage and a reconnect storm. The trade is that a subtle memory corruption isn't caught process-wide — but in a language where a panic is a logic bug, not a memory bug, containing it to the table is the right bet."),
      C.p("A runbook is how a metric becomes an action: the alert names the symptom (module 14.3), the runbook names the cause and the first move. Writing the two most likely incidents down is what turns 'p99 is climbing' from a panic into a checklist — and the follow-up column is the loop that makes each outage shorter than the last."),
      C.p("Incident response is the same loop as the loadtest regression gate: measure, act, and add a test that would have caught it. The runbook's 'follow-up' column and the engine's test suite are the same discipline in two languages."),
    ],
    alternatives: [
      { title: "Crash on any panic", text: "Maximum signal per failure, and a reconnect storm plus fleet-wide outage per bug. Per-table recovery is the proportional blast radius for a stateful game server." },
      { title: "Kubernetes-style restart", text: "Let the orchestrator kill and restart on liveness failure. That's the healthz layer (module 14.2); graceful drain is what makes the restart not hurt — they compose, they don't compete." },
      { title: "No runbook, wing it", text: "The first incident will force a runbook anyway — under pressure and without sleep. Writing it in advance costs an hour and buys a calm response." },
    ],
    improve: [
      { title: "Game-day drills", text: "Kill a node, kill Postgres, kill Redis — and time the recovery. The degradation postures (modules 12.6, 13.1) are only real once you've watched them happen." },
      { title: "Post-incident review template", text: "What happened, what was the first signal, what would have caught it earlier. The 'earlier' answer is always a metric or a test — write it down, build it." },
    ],
    activity: {
      type: "quiz",
      q: "Why does a room goroutine recover its own panic instead of crashing the process?",
      opts: ["Panics are cheap", "Blast radius: one buggy table degrades its four players; the other tens of thousands of rooms are untouched", "Go requires it", "It's easier to log"],
      correct: 1,
      explain: "Containing a logic bug to one table beats turning it into a fleet-wide outage and reconnect storm.",
    },
    done: ["You can write the shutdown sequence and a two-incident runbook."],
    refs: ["backend/internal/room", "backend/cmd/server/main.go", "backend/README.md (Operating it)"],
  }),
]));
