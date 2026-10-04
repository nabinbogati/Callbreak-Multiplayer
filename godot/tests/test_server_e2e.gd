extends TestBase

## End-to-end against the real Go server in backend/. Skipped unless
## `E2E_SERVER_URL` is set, e.g.:
##
##   (cd backend && go run ./cmd/server) &
##   E2E_SERVER_URL=ws://127.0.0.1:8080/ws godot --headless -s res://tests/test_runner.gd


func _server() -> String:
	return OS.get_environment("E2E_SERVER_URL")


func _client(room: String, name: String, creating := false) -> RemoteSession:
	var s := RemoteSession.new(_server(), room, name, "private")
	s.creating = creating
	s.hands_per_game = 3 if creating else 0
	s.device_id = IdentityStore.uuid_v4().replace("-", "")
	add_child(s)
	return s


func _autopilot(session: GameSession) -> void:
	var v := session.view
	if v == null:
		return
	if v.phase == GameView.BIDDING and v.is_my_turn() and not v.i_have_bid():
		session.place_bid(Rules.suggest_bid(v.hand))
	elif v.phase == GameView.PLAYING and v.is_my_turn() and not v.legal_move_ids.is_empty():
		session.play(v.legal_move_ids[0])


func test_private_room_lobby_deal_play_and_reconnect() -> void:
	if _server().is_empty():
		print("    (skipped: set E2E_SERVER_URL to run against backend/)")
		return
	var room := "G" + "".join(range(3).map(func(_i): return "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"[randi() % 32]))
	var a := _client(room, "Alice", true)
	expect_true(await wait_until(func(): return not a.lobby().is_empty(), 8.0), "creator lands in the lobby")
	if a.lobby().is_empty():
		a.shutdown()
		return
	expect_true(a.lobby()["isHost"], "creator hosts")
	expect_eq(a.lobby()["handsPerGame"], 3, "match length sent on create")

	var b := _client(room, "Bob")
	expect_true(await wait_until(func(): return b.lobby().get("seats", []).size() == 2, 8.0), "joiner sees both seats")
	expect_true(await wait_until(func(): return a.lobby().get("canStart", false), 8.0), "host may start")

	a.changed.connect(func(): _autopilot.call_deferred(a))
	b.changed.connect(func(): _autopilot.call_deferred(b))
	a.start_game()
	expect_true(await wait_until(func(): return a.view != null and b.view != null, 8.0), "both dealt in")
	if a.view == null or b.view == null:
		a.shutdown(); b.shutdown()
		return
	expect_eq(a.view.hand.size(), 13, "13 cards dealt")
	expect_true(a.view.you != b.view.you, "distinct seats")
	expect_true(not a.resume_token.is_empty(), "resume token issued")

	# Play reaches the second trick, proving bids and plays are accepted.
	expect_true(await wait_until(func(): return b.view != null and b.view.trick_number >= 1, 60.0), "tricks are being played")

	# Drop Bob's connection and bring it back: same seat, same hand.
	var seat_before := b.view.you
	b.simulate_offline(true)
	expect_true(await wait_until(func(): return b.is_resuming(), 3.0), "drop noticed — reconnecting")
	b.simulate_offline(false)
	expect_true(await wait_until(func(): return b.status == GameSession.READY and not b.is_resuming(), 10.0), "seat reclaimed")
	expect_eq(b.view.you, seat_before, "same seat after reconnect")

	a.shutdown()
	b.shutdown()


func test_unreachable_server_reports_friendly_error() -> void:
	var s := RemoteSession.new("ws://127.0.0.1:9/ws", "NOPE", "Nobody", "private")
	add_child(s)
	expect_true(await wait_until(func(): return s.status == GameSession.ERROR, 10.0), "fails fast")
	expect_true(s.error_message.begins_with("We couldn't reach the game server"), "friendly copy: " + s.error_message)
	s.shutdown()


func test_server_fatal_error_reaches_the_player() -> void:
	# The server sends its error and closes in the same breath; the message
	# must survive (WebSocketPeer would drop it — see WsClient).
	if _server().is_empty():
		print("    (skipped: set E2E_SERVER_URL to run against backend/)")
		return
	var s := _client("ZZ1", "Typo", true)
	expect_true(await wait_until(func(): return s.status == GameSession.ERROR, 8.0), "join rejected")
	expect_eq(s.error_message, "That room code is not valid.", "server's own copy shown")
	s.shutdown()

	var guest := _client("QQQQ", "Lost")
	expect_true(await wait_until(func(): return guest.status == GameSession.ERROR, 8.0), "joining a missing room fails")
	expect_true(not guest.error_message.begins_with("We couldn't reach"), "specific reason: " + guest.error_message)
	guest.shutdown()
