extends Node

## The screenshot tour itself; loaded at runtime by screenshots.gd so the app's
## classes compile after the autoloads exist.

var out := "user://shots"


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if not arg.begins_with("--"):
			out = arg
	DirAccess.make_dir_recursive_absolute(out)
	_run.call_deferred()


func _shot(name: String) -> void:
	for i in 6:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_tree().root.get_texture().get_image().save_png("%s/%s.png" % [out, name])
	print("saved ", name)


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _run() -> void:
	var settings = get_node("/root/Settings")
	settings.use_memory_storage()
	settings.server_url = "ws://127.0.0.1:9/ws"
	settings.music_enabled = false
	settings.player_name = "Nabin"
	var app: App = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child(app)
	await _shot("01_home")

	app.sheet(JoinSheet.new("private"))
	await _shot("02_join_private")
	app.close_overlays()

	var session := LocalSession.new("Nabin", "normal", 3, 1.0, 11)
	var table := TableScreen.new(session)
	app.push(table)
	await _wait(1.2)
	await _shot("03_dealing")
	await _wait(3.5)
	await _shot("04_bidding")
	var v := session.view
	if v.phase == GameView.BIDDING and v.is_my_turn():
		session.place_bid(Rules.suggest_bid(v.hand))
	# Let the bots bid, then play until a trick is on the felt.
	var guard := 0
	while guard < 400:
		guard += 1
		await get_tree().process_frame
		v = session.view
		if v.phase == GameView.BIDDING and v.is_my_turn() and not v.i_have_bid():
			session.place_bid(Rules.suggest_bid(v.hand))
		if v.phase == GameView.PLAYING and v.trick.size() >= 2 and v.is_my_turn():
			break
	await _wait(0.8)
	await _shot("05_playing")
	table._toggle_history()
	await _shot("06_history")
	table._toggle_history()

	app.pop_to_root()
	await _wait(0.3)

	app.push(SettingsScreen.new())
	await _shot("09_settings")
	app.pop()

	var host := LanHostSession.new("Nabin", "K7QM", "normal", 3, 1.0)
	app.push(TableScreen.new(host))
	host.start_hosting()
	await _shot("10_lan_lobby")
	app.pop()

	var finished := LocalSession.new("Nabin", "hard", 3, 0.01, 5)
	var t2 := TableScreen.new(finished)
	finished.changed.connect(func():
		var fv := finished.view
		if fv == null:
			return
		if fv.phase == GameView.BIDDING and fv.is_my_turn() and not fv.i_have_bid():
			finished.place_bid.call_deferred(Rules.suggest_bid(fv.hand))
		elif fv.phase == GameView.PLAYING and fv.is_my_turn() and not fv.legal_move_ids.is_empty():
			finished.play.call_deferred(fv.legal_move_ids[0])
		elif fv.phase == GameView.HAND_OVER:
			finished.continue_to_next_hand.call_deferred())
	app.push(t2)
	while finished.view == null or finished.view.phase != GameView.GAME_OVER:
		await get_tree().process_frame
	await _wait(1.0)
	await _shot("11_winner")
	get_tree().quit()
