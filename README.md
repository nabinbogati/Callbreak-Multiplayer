# Call Break — multiplayer

Call Break, the four-player trick-taking card game with spades as permanent
trump. You can play solo against bots, online quickplay, private rooms with a
code, or on a LAN where one phone hosts.

| Folder | What it is |
|---|---|
| [`godot/`](godot/README.md) | The client: a Godot 4.5 app (GDScript), built for Android. |
| [`backend/`](backend/README.md) | The authoritative Go game server: WebSocket play, matchmaking, and the optional REST/Postgres history and stats. |
| `docs/`, `tutorial/` | A step-by-step course on building the project. It teaches the original Flutter client, which was replaced by `godot/` and is still in git history at `f5940e7`. |

## Quick start

```sh
# server
cd backend && go run ./cmd/server          # ws://localhost:8080/ws

# client: open godot/project.godot in Godot 4.5 and press Play
```

For a debug build, point the app at your machine under *Settings → Debug →
Game server*, for example `ws://<your-lan-ip>:8080/ws`.

## Tests

```sh
cd backend && go test ./...
godot --headless --path godot --import
godot --headless --path godot -s res://tests/test_runner.gd
```

CI (`.github/workflows/ci.yml`) runs both. The client job also starts the real
server and runs the end-to-end client tests against it.
