# Call Break — Godot 4 client

A complete rewrite of the original Flutter client (removed from the tree; still
in git history at `f5940e7`) for **Godot 4.5**
(GDScript only, no plugins). Same game, same Go server in `backend/`, same wire
protocol, same design: solo against bots, online quickplay, private rooms
with a code, and LAN play where one phone hosts.

## Run it

1. Install Godot **4.5** (standard build).
2. Open `godot/project.godot` in the editor (the first open imports assets) and press **Play**.

To preview a phone-sized window on desktop:

```sh
godot --path godot --resolution 780x1688 -- --density=2
```

`--density=N` makes the desktop window act like a phone of that pixel density.
Without it, a desktop window gets the scale a tablet would get.

## Tests

```sh
godot --headless --path godot --editor --quit      # first time only: import assets
godot --headless --path godot -s res://tests/test_runner.gd
```

The runner exits non-zero on any failure, and a script error raised during a
test also fails that test. `TEST_FILTER=lan` runs only the matching tests.

| Suite | Covers |
|---|---|
| `test_engine.gd` | Port of the Flutter `engine_test.dart`: 40 simulated games, scoring, legal moves, bid suggestion, view redaction, and decoding the Go server's own golden `view` frames (read from `backend/testdata/`, with a copy in `tests/fixtures/` for standalone use). |
| `test_sessions.gd` | A whole solo game through the real timers. A LAN host and guest playing a full game over a loopback socket. Timeout to autoplay and back. Bots holding their bids until the deal is down, on the solo and LAN tables. LAN discovery over UDP. Identity and uuid. |
| `test_server_e2e.gd` | Against the real Go server: create a private room, join, deal, play, drop the connection and reclaim the same seat, and check that server error messages reach the player. Skipped unless `E2E_SERVER_URL` is set. |
| `test_ui.gd` | Drives every screen of the real app shell. Plays a full game through the table screen, taps and drags cards, opens every sheet, and covers the rejoin prompt and the failure states. |
| `test_table.gd` | The hand fan's gestures (tap, refuse, scrub, drag-to-throw, spring back, off-turn, tap twice), a throw holding on the felt until a slow server confirms it (and returning to the hand if it never does), the refusal hints, the animation budgets: the trick sequence inside the hosts' 1100 ms linger at every speed, and the deal inside the wait before bidding opens. And the table on every phone and tablet either way up, with the felt and without it (Settings → Show table): nothing touching or off screen, the played cards on the felt's centre (or, without it, the screen's, each seat at its own edge), a larger screen drawing it larger. |

End-to-end against the backend:

```sh
(cd backend && ADDR=127.0.0.1:18080 go run ./cmd/server) &
E2E_SERVER_URL=ws://127.0.0.1:18080/ws godot --headless --path godot -s res://tests/test_runner.gd
```

Screenshots of the main screens, which need a display (Xvfb works):

```sh
xvfb-run godot --path godot --rendering-driver opengl3 --resolution 780x1688 \
    -s res://tests/screenshots.gd -- /tmp/shots --density=2
```

## Android export

`export_presets.cfg` has an **Android** preset:

- package `com.callbreak.callbreak`, the same id as the Flutter app
- arm64-v8a and armeabi-v7a
- permissions: `INTERNET`, `ACCESS_NETWORK_STATE`, `ACCESS_WIFI_STATE`,
  `CHANGE_WIFI_MULTICAST_STATE`, which some devices need to receive the LAN
  discovery broadcasts, and `VIBRATE` for the table's touch feedback

To export, install the 4.5 export templates and point the editor at an Android
SDK (*Editor → Editor Settings → Export → Android*). Then run
*Project → Export* or:

```sh
godot --headless --path godot --export-release "Android" build/callbreak.apk
```

The game server address is `DEFAULT_SERVER_URL` in
`scripts/state/app_settings.gd`. Debug builds can override it under
*Settings → Debug*.

## Layout

```
scripts/
  engine/   cards.gd, rules.gd, call_break_game.gd, game_view.gd   ← lib/engine
  bots/     bot_brain.gd                                           ← lib/bots
  net/      game_session.gd (interface), local_session.gd,         ← lib/net
            hosted_session.gd (shared host loop), lan_host_session.gd,
            remote_session.gd, ws_client.gd, lan_discovery.gd,
            lan_broadcaster.gd, api_client.gd, game_recorder.gd,
            game_uploader.gd (autoload "Uploader"), sessions.gd, wire.gd
  state/    app_settings.gd (autoload "Settings"), identity_store.gd ← lib/state
  audio/    audio_controller.gd (autoload "Audio")                 ← lib/audio
  ui/       tokens.gd, motion.gd, ui.gd, draw.gd, haptics.gd     ← lib/design
            table_layout.gd (where everything at the table goes, and
            the one scale it is drawn at on this screen)
            widgets/  cards, seats, hand fan, trick, deal, panels  ← lib/ui/widgets
            screens/  app (shell), home, table, settings, profile, ← lib/ui/screens
                      join/LAN/quick-settings sheets, dialogs
tests/      runner, suites, server fixture, screenshot tour
```

## Notes on the port

- **The UI is built in code.** There are no `.tscn` files except the one-node
  main scene. Cards, felt, avatars and suit glyphs are drawn as vectors, so they
  look the same on every device and don't depend on a symbol font. Icons are
  the design's own Material glyphs, from a 45-glyph subset of the Material
  Icons font (`assets/fonts/MaterialIcons-Subset.otf`, licence alongside it).
- **Motion lives in `motion.gd`.** Every gameplay timing and curve sits in one
  place, because several have to agree: the throw, gather and sweep of a trick
  must finish inside the hosts' 1100 ms linger, and the deal inside the
  3.5 s wait before bidding opens. The tests check both.
- **Antialiasing is one device pixel wide.** Godot's antialiased lines feather
  by a whole canvas unit, which is two or three device pixels on a phone and
  makes every border read thick and soft. `Draw` strokes and fills with its
  own one-device-pixel fringe instead, and shadows are fitted to the falloff of
  the design's blurs.
- **Design pixels.** The viewport is scaled so its short side is the design's
  390, with the same 0.78×–1.4× clamp the Flutter `Metrics` class used.
  Layouts use the design's numbers directly.
- **`WsClient` instead of `WebSocketPeer`.** The server sends its fatal error
  (for example "That room code is not valid.") and closes the socket straight
  after. When the error and the close arrive in the same read,
  `WebSocketPeer` (tested on 4.3 and 4.5.1) drops the error, and the player
  would only see a generic "couldn't connect". `ws_client.gd` is a small
  RFC 6455 client over `StreamPeerTCP`/`StreamPeerTLS` that keeps every frame.
  `test_server_fatal_error_reaches_the_player` covers this.
- **Renderer.** The project uses the Compatibility renderer (OpenGL ES 3)
  because it runs on the widest range of Android devices. That renderer has no
  2D MSAA, so polygon edges are smoothed with a thin antialiased outline.
- **Settings persist.** The Flutter app kept display settings in memory.
  Here they are saved to `user://settings.cfg`, including Vibration and Tap
  twice to play. Identity (device id, session, rejoin record) and the offline
  upload queue persist as before.
- **LAN lobby.** When a guest leaves before the deal, their chair is freed
  for someone else rather than kept as a disconnected seat.
- The one sound that was a 24-bit WAVE (which Godot can't import) was
  converted to Ogg Vorbis.
