extends TestBase

## Drives every screen of the real app shell headlessly. Any script error on
## the way fails the test (the runner captures them), so this is what proves
## the UI code paths actually run, not just compile.

var app: App


func _start_app() -> App:
	Settings.use_memory_storage()
	Settings.server_url = "ws://127.0.0.1:9/ws"
	Uploader.use_memory_storage()
	var scene: PackedScene = load("res://scenes/main.tscn")
	app = scene.instantiate()
	add_child(app)
	await get_tree().process_frame
	await get_tree().process_frame
	return app


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


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


func test_home_settings_and_profile_screens() -> void:
	await _start_app()
	expect_true(app.top_screen() is HomeScreen, "home is the first screen")
	await _frames(3)

	app.push(SettingsScreen.new())
	await _frames(2)
	var settings: SettingsScreen = app.top_screen()
	for tab in ["gameplay", "debug", "profile"]:
		settings._select_tab(tab)
		await _frames(2)
	settings._pick("theme", "sapphire")
	settings._pick("card_style", "midnight")
	expect_eq(Settings.theme, "sapphire")
	app.pop()
	await _frames(2)

	app.push(ProfileScreen.new())
	await _frames(2)
	var profile: ProfileScreen = app.top_screen()
	# The server is unreachable here, so every tab must land on a calm message.
	expect_true(await wait_until(func(): return profile._stats_error != null, 20.0), "stats fail gracefully")
	profile._select_tab("history")
	expect_true(await wait_until(func(): return profile._games_error != null, 20.0), "history fails gracefully")
	profile._select_tab("account")
	await _frames(2)
	app.pop()
	await _frames(2)
	expect_eq(ProfileScreen.format_played_at(""), "Unknown date")
	expect_true(Wire.parse_iso("2026-01-02T03:04:05.123Z") == 1767323045, "RFC 3339 with fraction")
	expect_eq(Wire.parse_iso("2026-01-02T05:04:05+02:00"), 1767323045, "offsets honoured")
	Settings.theme = "emerald"
	Settings.card_style = "classic"
	app.queue_free()


func test_sheets_open_and_close() -> void:
	await _start_app()
	for mode in ["bots", "online", "private"]:
		var sheet := app.sheet(JoinSheet.new(mode))
		await _frames(2)
		expect_true(app.has_overlay(), "%s sheet open" % mode)
		sheet.dismiss()
		await _frames(2)
	var join := JoinSheet.new("private")
	var s := app.sheet(join)
	await _frames(1)
	join._set_creating(false)
	join._submit()
	expect_true(not join._error.is_empty(), "empty join code is explained")
	s.dismiss()
	var lan := app.sheet(LanSheet.new())
	await _frames(2)
	(lan.content as LanSheet)._switch(false)
	await _frames(2)
	lan.dismiss()
	app.sheet(QuickSettings.new()).dismiss()
	await _frames(2)
	expect_true(not app.has_overlay(), "all closed")
	app.queue_free()


func test_full_game_through_the_table_screen() -> void:
	await _start_app()
	var session := LocalSession.new("Tester", "hard", 3, 0.02, 7)
	var table := TableScreen.new(session)
	session.changed.connect(func(): _autopilot.call_deferred(session))
	app.push(table)
	expect_true(await wait_until(func(): return table._dealing, 5.0), "the deal animates")
	expect_true(await wait_until(func(): return not table._dealing, 10.0), "the deal finishes")
	var done := await wait_until(func(): return session.view != null and session.view.phase == GameView.GAME_OVER, 90.0)
	expect_true(done, "game over reached through the real table")
	await _frames(3)
	var winner := table._overlay.find_children("*", "WinnerScreen", true, false)
	expect_eq(winner.size(), 1, "winner screen shown")
	table._toggle_history()
	await _frames(2)
	table._toggle_history()
	table._play_again()
	expect_true(await wait_until(func(): return session.view.phase == GameView.BIDDING or session.view.phase == GameView.PLAYING, 5.0), "play again re-deals")
	# Landscape: everything re-lays out without errors.
	get_tree().root.content_scale_size = Vector2i(844, 390)
	await _frames(4)
	get_tree().root.content_scale_size = Vector2i(390, 844)
	await _frames(2)
	app.pop_to_root()
	await _frames(2)
	expect_true(app.top_screen() is HomeScreen, "home again")
	app.queue_free()


func test_lan_host_lobby_and_connection_states() -> void:
	await _start_app()
	var host := LanHostSession.new("Host", "LMNP", "normal", 3, 0.02)
	var table := TableScreen.new(host)
	app.push(table)
	host.start_hosting()
	await _frames(3)
	expect_eq(table._overlay.find_children("*", "LobbyPanel", true, false).size(), 1, "host sees the lobby")
	host.set_hands_per_game(5)
	await _frames(2)
	app.pop()
	await _frames(2)

	var remote := Sessions.remote("ws://127.0.0.1:9/ws", "ABCD", "private")
	var failing := TableScreen.new(remote)
	app.push(failing)
	expect_true(await wait_until(func(): return remote.status == GameSession.ERROR, 10.0), "connect fails")
	await _frames(2)
	expect_true(failing._overlay.get_child_count() > 0, "failure card shown")
	app.pop()
	await _frames(2)
	app.queue_free()


func _click(target: Control, local: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = local
	target._gui_input(e)


func _wait_my_play_turn(session: GameSession) -> bool:
	return await wait_until(func():
		var v := session.view
		if v != null and v.phase == GameView.BIDDING and v.is_my_turn() and not v.i_have_bid():
			session.place_bid(Rules.suggest_bid(v.hand))
		return v != null and v.phase == GameView.PLAYING and v.is_my_turn() and not v.awaiting_trick_clear, 20.0)


func test_tap_and_drag_throw_cards_from_the_hand() -> void:
	await _start_app()
	Settings.auto_throw_last_suit_card = false
	var session := LocalSession.new("Tester", "hard", 3, 0.02, 21)
	var table := TableScreen.new(session)
	app.push(table)
	expect_true(await wait_until(func(): return not table._dealing and session.view != null, 10.0), "dealt")
	expect_true(await _wait_my_play_turn(session), "my turn to play")
	await _frames(2)
	var fan := table._hand
	var legal: String = session.view.legal_move_ids[0]
	var node: CardView = fan._nodes[legal]
	var spot := node.position + Vector2(6, 12)
	_click(fan, spot, true)
	_click(fan, spot, false)
	expect_true(await wait_until(func(): return not session.view.hand.has(legal), 2.0), "a tap throws the card")

	expect_true(await _wait_my_play_turn(session), "my next turn")
	await _frames(2)
	legal = session.view.legal_move_ids[0]
	node = fan._nodes[legal]
	spot = node.position + Vector2(6, 12)
	_click(fan, spot, true)
	var drag := InputEventMouseMotion.new()
	drag.position = spot + Vector2(0, -fan.card_height() * 0.5)
	fan._gui_input(drag)
	expect_true(await wait_until(func(): return not session.view.hand.has(legal), 2.0), "a drag past 30% throws it")
	Settings.auto_throw_last_suit_card = true
	app.queue_free()


func test_pressable_emits_on_release_inside() -> void:
	var hits := [0]
	var p := UI.button("Go", true, func(): hits[0] += 1)
	add_child(p)
	await _frames(1)
	_click(p, p.size / 2.0, true)
	_click(p, p.size / 2.0, false)
	expect_eq(hits[0], 1, "tap registers")
	_click(p, p.size / 2.0, true)
	_click(p, p.size + Vector2(50, 50), false)
	expect_eq(hits[0], 1, "release outside cancels")
	p.queue_free()


func test_rejoin_prompt_offers_a_held_seat() -> void:
	Settings.use_memory_storage()
	Settings.identity.save_active_game({"serverUrl": "ws://127.0.0.1:9/ws", "roomCode": "WXYZ", "mode": "private",
			"resumeToken": "tok", "playerName": "P"})
	var scene: PackedScene = load("res://scenes/main.tscn")
	app = scene.instantiate()
	add_child(app)
	expect_true(await wait_until(func(): return app.has_overlay(), 3.0), "rejoin dialog shown")
	app.close_overlays()
	expect_true(await wait_until(func(): return Settings.identity.active_game().is_empty(), 3.0), "discard clears the record")
	app.queue_free()
