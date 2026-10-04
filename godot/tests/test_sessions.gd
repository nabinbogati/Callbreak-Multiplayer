extends TestBase

## Session-level tests: a whole solo game through [LocalSession]'s real
## timers, a LAN host and guest talking over a real loopback socket, and LAN
## discovery over UDP.


func _before() -> void:
	Settings.use_memory_storage()
	# Nothing in these tests should reach a real server.
	Settings.server_url = "ws://127.0.0.1:9/ws"
	Uploader.use_memory_storage()


## Plays whatever this seat is asked for, the way a fast human would.
func _autopilot(session: GameSession) -> void:
	var v := session.view
	if v == null:
		return
	if v.phase == GameView.BIDDING and v.is_my_turn() and not v.i_have_bid():
		session.place_bid(Rules.suggest_bid(v.hand))
	elif v.phase == GameView.PLAYING and v.is_my_turn() and not v.legal_move_ids.is_empty():
		session.play(v.legal_move_ids[0])
	elif v.phase == GameView.HAND_OVER:
		session.continue_to_next_hand()


func test_local_session_plays_a_full_game_and_queues_the_upload() -> void:
	_before()
	var session := LocalSession.new("Tester", "hard", 3, 0.01, 42)
	var events := []
	session.game_event.connect(func(e): events.append(e["event"]))
	session.changed.connect(func(): _autopilot.call_deferred(session))
	add_child(session)

	var finished := await wait_until(func(): return session.view != null and session.view.phase == GameView.GAME_OVER, 60.0)
	expect_true(finished, "game reached game over")
	if not finished:
		session.shutdown()
		return
	expect_eq(session.view.rankings.size(), 4, "four rankings")
	expect_eq(events.count("handStart"), 3, "three hands dealt")
	expect_eq(events.count("trickWon"), 39, "39 tricks")
	expect_eq(events.count("gameOver"), 1)
	expect_eq(session.view.hands_per_game, 3)
	# The finished game went to the upload queue with exactly one `isYou`.
	expect_true(Uploader.pending() <= 1, "at most the one game queued")
	session.shutdown()


func test_game_recorder_builds_an_idempotent_payload() -> void:
	var recorder := GameRecorder.new("bots", 0)
	expect_eq(recorder.build([], [], [], 5), {}, "nothing before a hand")
	recorder.record_hand(0, [3, 2, 4, 1], [3, 1, 6, 3], [3.0, -2.0, 4.2, 1.2])
	var players := []
	for seat in 4:
		players.append(GameView.make_player(seat, "P%d" % seat, "human" if seat == 0 else "bot"))
	var payload := recorder.build(players, [3.0, -2.0, 4.2, 1.2],
			[{"seat": 2, "place": 1}, {"seat": 0, "place": 2}, {"seat": 3, "place": 3}, {"seat": 1, "place": 4}], 5)
	expect_eq(payload["clientGameId"], recorder.client_game_id, "id minted up front")
	expect_eq(payload["hands"].size(), 4)
	expect_eq(payload["seats"].filter(func(s): return s["isYou"]).size(), 1, "exactly one isYou")
	expect_eq(payload["seats"][1]["botDifficulty"], "normal")
	expect_eq(payload["seats"][2]["place"], 1)
	expect_eq(payload["seats"][1]["handsMade"], 0, "short bid not made")
	expect_true(GameRecorder.new("online", 0).build(players, [0, 0, 0, 0], [], 5).is_empty(), "online not uploadable")


func test_lan_host_and_guest_play_over_loopback() -> void:
	_before()
	var host := LanHostSession.new("Host", "ABCD", "hard", 3, 0.01)
	add_child(host)
	expect_eq(host.start_hosting(), OK, "server listening")
	var port := host.ws_port()
	expect_true(port > 0, "ephemeral port assigned")
	expect_true(not host.can_start(), "a host alone cannot start")

	var guest := RemoteSession.new("ws://127.0.0.1:%d" % port, "ABCD", "Guest", "lan")
	var guest_events := []
	guest.game_event.connect(func(e): guest_events.append(e["event"]))
	add_child(guest)

	expect_true(await wait_until(func(): return not guest.lobby().is_empty(), 5.0), "guest sees the lobby")
	expect_eq(guest.seat, 1, "guest seated at 1")
	expect_eq(guest.lobby()["seats"].size(), 2, "lobby lists both")
	expect_true(not guest.lobby()["isHost"], "guest is not host")
	expect_true(host.can_start(), "host can start with a guest")

	# The host changes the match length from the lobby; the guest hears it.
	host.set_hands_per_game(5)
	expect_true(await wait_until(func(): return guest.lobby().get("handsPerGame") == 5, 3.0), "length reaches guest")
	host.set_hands_per_game(3)

	host.changed.connect(func(): _autopilot.call_deferred(host))
	guest.changed.connect(func(): _autopilot.call_deferred(guest))
	host.start_game()

	expect_true(await wait_until(func(): return guest.view != null, 5.0), "guest receives a view")
	if guest.view != null:
		expect_eq(guest.view.you, 1, "guest's own view")
		expect_eq(guest.view.host_seat, 0, "host seat stamped on the view")
		expect_eq(guest.view.players[1]["name"], "Guest")
		expect_eq(guest.view.players[2]["kind"], "bot", "empty seat became a bot")

	var done := await wait_until(func():
		return guest.view != null and guest.view.phase == GameView.GAME_OVER \
				and host.view.phase == GameView.GAME_OVER, 120.0)
	expect_true(done, "both reached game over")
	expect_eq(guest_events.count("handStart"), 3, "guest heard three deals")
	expect_eq(guest_events.count("gameOver"), 1)
	if done:
		expect_eq(guest.view.totals, host.view.totals, "guest and host agree on the score")

	guest.shutdown()
	host.shutdown()


func test_lan_guest_timeout_hands_seat_to_autoplay_and_back() -> void:
	_before()
	var host := LanHostSession.new("Host", "WXYZ", "hard", 3, 0.01)
	add_child(host)
	host.start_hosting()
	var guest := RemoteSession.new("ws://127.0.0.1:%d" % host.ws_port(), "WXYZ", "Sleepy", "lan")
	var autoplay_events := []
	guest.game_event.connect(func(e):
		if e["event"] == "autoplay": autoplay_events.append(e["autoplay"]))
	add_child(guest)
	expect_true(await wait_until(func(): return host.can_start(), 5.0), "guest joined")
	# Only the host plays; the guest never acts.
	host.changed.connect(func(): _autopilot.call_deferred(host))
	host.start_game()

	# The guest bids late (auto-bid, seat kept) and then, the first time it is
	# on the clock to play, times out into autoplay.
	expect_true(await wait_until(func(): return guest.view != null and guest.view.phase == GameView.PLAYING, 20.0), "bidding finished for the sleeper")
	var on := await wait_until(func(): return autoplay_events.has(true), 30.0)
	expect_true(on, "sleeper put on autoplay")
	if on:
		expect_true(await wait_until(func(): return guest.view.players[1]["autoplay"], 3.0), "view carries the autoplay flag")
		guest.wake_up()
		expect_true(await wait_until(func(): return autoplay_events.has(false), 5.0), "a tap takes the seat back")
	guest.shutdown()
	host.shutdown()


func test_lan_discovery_finds_a_broadcast_table() -> void:
	var discovery := LanDiscovery.new()
	add_child(discovery)
	var broadcaster := LanBroadcaster.new("QRST", "Hosty", 4242)
	broadcaster.target_address = "127.0.0.1"
	add_child(broadcaster)
	var found := await wait_until(func(): return not discovery.games().is_empty(), 5.0)
	expect_true(found, "advert received")
	if found:
		var g: Dictionary = discovery.games()[0]
		expect_eq(g["roomCode"], "QRST")
		expect_eq(g["hostName"], "Hosty")
		expect_eq(g["wsUrl"], "ws://127.0.0.1:4242")
	broadcaster.queue_free()
	discovery.queue_free()


func test_origin_from_socket_url() -> void:
	expect_eq(ApiClient.origin_from_socket_url("ws://192.168.1.20:8080/ws"), "http://192.168.1.20:8080")
	expect_eq(ApiClient.origin_from_socket_url("wss://cb.example.com/ws"), "https://cb.example.com")
	expect_eq(ApiClient.origin_from_socket_url("wss://cb.example.com/game/ws?x=1"), "https://cb.example.com/game")
	expect_eq(ApiClient.origin_from_socket_url("foo://host"), "https://host", "unknown scheme stays secure")


func test_uuid_and_device_id() -> void:
	var id := IdentityStore.uuid_v4()
	var re := RegEx.create_from_string("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
	expect_true(re.search(id) != null, "v4 shape: " + id)
	var store := IdentityStore.new(false)
	expect_eq(store.device_id.length(), 32, "device id is a hyphenless uuid")
	expect_true(store.needs_session(), "fresh store needs a session")
	store.save_session("tok", int(Time.get_unix_time_from_system()) + 3600)
	expect_true(not store.needs_session(), "valid token kept")
	store.save_active_game({"serverUrl": "ws://x/ws", "roomCode": "ABCD", "mode": "private", "resumeToken": "r", "playerName": "P"})
	expect_eq(store.active_game()["roomCode"], "ABCD")
	store.clear_active_game()
	expect_true(store.active_game().is_empty())
