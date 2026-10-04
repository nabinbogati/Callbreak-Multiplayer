extends TestBase

## The table's touch and motion: the hand fan's gestures, a thrown card
## holding on the felt until the table confirms it, the refusal hint, and the
## animation budget every host's trick linger depends on.

const HAND: Array[String] = ["AS", "9H", "5H", "QC", "3C"]


func _before() -> void:
	Settings.use_memory_storage()
	Settings.server_url = "ws://127.0.0.1:9/ws"
	Settings.music_enabled = false
	Uploader.use_memory_storage()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _button(fan: Control, pos: Vector2, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = pos
	fan._gui_input(e)


func _move(fan: Control, pos: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	fan._gui_input(e)


func _tap(fan: Control, pos: Vector2) -> void:
	_button(fan, pos, true)
	_button(fan, pos, false)


## A point on [param card]'s visible strip — its left edge, which the next
## card in the fan does not cover.
func _strip(fan: HandFan, card: String) -> Vector2:
	var i := fan._laid.find(card)
	return Vector2(fan._lefts[i] + 8, fan._tops[i] + 30)


## A hand fan on its own, logging what it reports.
func _fan(legal: Array = HAND, interactive := true, hidden: Array = []) -> Array:
	var fan := HandFan.new()
	fan.card_width = 60
	fan.size = Vector2(360, fan.fan_height())
	add_child(fan)
	var log := {"played": [], "refused": [], "waited": 0}
	fan.card_thrown.connect(func(card, _c, _s, _a): log["played"].append(card))
	fan.illegal.connect(func(card): log["refused"].append(card))
	fan.not_your_turn.connect(func(): log["waited"] += 1)
	fan.set_hand(HAND, legal, interactive, HAND.size(), hidden)
	await _frames(2)
	return [fan, log]


# ------------------------------------------------------------- gestures

func test_a_tap_plays_a_legal_card() -> void:
	_before()
	var r := await _fan()
	_tap(r[0], _strip(r[0], "9H"))
	expect_eq(r[1]["played"], ["9H"])
	r[0].queue_free()


func test_an_illegal_card_is_refused_not_played() -> void:
	_before()
	var r := await _fan(["9H", "5H"])
	_tap(r[0], _strip(r[0], "QC"))
	expect_eq(r[1]["played"], [], "nothing played")
	expect_eq(r[1]["refused"], ["QC"], "the refusal is reported")
	r[0].queue_free()


func test_sliding_across_the_fan_previews_but_never_plays() -> void:
	_before()
	var r := await _fan()
	var fan: HandFan = r[0]
	var at := _strip(fan, "AS")
	_button(fan, at, true)
	for i in 8:
		at += Vector2(14, 0)
		_move(fan, at)
		await _frames(1)
	expect_true(fan._selected != "AS", "the preview followed the finger")
	_button(fan, at, false)
	expect_eq(r[1]["played"], [], "letting go after a slide plays nothing")
	fan.queue_free()


func test_dragging_a_card_up_past_the_threshold_throws_it() -> void:
	_before()
	var r := await _fan()
	var fan: HandFan = r[0]
	var at := _strip(fan, "5H")
	_button(fan, at, true)
	for i in 6:
		at += Vector2(0, -12)
		_move(fan, at)
		await _frames(1)
	expect_eq(r[1]["played"], ["5H"], "thrown as soon as it crosses the line")
	_button(fan, at, false)
	expect_eq(r[1]["played"], ["5H"], "lifting the finger does not throw twice")
	fan.queue_free()


func test_a_short_slow_drag_springs_back_without_playing() -> void:
	_before()
	var r := await _fan()
	var fan: HandFan = r[0]
	var at := _strip(fan, "5H")
	_button(fan, at, true)
	_move(fan, at + Vector2(0, -12))
	await _seconds(0.2)
	_move(fan, at + Vector2(0, -18))
	await _seconds(0.2)
	_button(fan, at + Vector2(0, -18), false)
	expect_eq(fan._returning, "5H", "the card springs home")
	await _seconds(0.6)
	expect_eq(r[1]["played"], [], "nothing played")
	expect_eq(fan._returning, "", "and settles")
	fan.queue_free()


func test_off_turn_cards_preview_but_a_throw_only_says_to_wait() -> void:
	_before()
	var r := await _fan(HAND, false)
	var fan: HandFan = r[0]
	_tap(fan, _strip(fan, "9H"))
	expect_eq(r[1]["played"], [])
	var at := _strip(fan, "9H")
	_button(fan, at, true)
	for i in 8:
		at += Vector2(0, -14)
		_move(fan, at)
		await _frames(1)
	_button(fan, at, false)
	expect_eq(r[1]["played"], [], "nothing played off turn")
	expect_eq(r[1]["waited"], 1, "told to wait, once")
	fan.queue_free()


func test_tap_twice_to_play_raises_first_then_plays() -> void:
	_before()
	Settings.tap_twice_to_play = true
	var r := await _fan()
	var fan: HandFan = r[0]
	_tap(fan, _strip(fan, "9H"))
	expect_eq(r[1]["played"], [], "the first tap only raises the card")
	expect_eq(fan._armed, "9H")
	_tap(fan, _strip(fan, "9H"))
	expect_eq(r[1]["played"], ["9H"])
	Settings.tap_twice_to_play = false
	fan.queue_free()


func test_a_thrown_card_awaiting_confirmation_leaves_the_fan() -> void:
	_before()
	var r := await _fan(HAND, true, ["QC"])
	var fan: HandFan = r[0]
	expect_true(not fan._nodes.has("QC"), "the held-back card is not drawn")
	expect_eq(fan._nodes.size(), HAND.size() - 1)
	fan.queue_free()


# ------------------------------------------------------- throw hand-off

## Behaves like a networked table: a play is only sent, and the view changes
## only when the test (standing in for the server) says so.
class ServerLike:
	extends GameSession

	var played: Array = []

	func _init(v: GameView) -> void:
		view = v
		mode = "online"
		status = READY

	func play(card: String) -> void:
		played.append(card)

	func confirm(v: GameView) -> void:
		view = v
		changed.emit()


const LEAD := {"seat": 1, "card": "9H"}


static func _view(hand: Array[String], trick: Array, turn := 0) -> GameView:
	var v := GameView.new()
	v.phase = GameView.PLAYING
	v.hands_per_game = 5
	v.dealer = 3
	v.turn = turn
	v.players = [GameView.make_player(0, "You", "human"), GameView.make_player(1, "Bina", "human"),
			GameView.make_player(2, "Kamal", "bot"), GameView.make_player(3, "Sita", "bot")]
	v.you = 0
	v.hand = hand
	if turn == 0:
		v.legal_move_ids = Rules.legal_moves(hand, trick)
	v.hand_counts.assign([hand.size(), 12, 13, 13])
	v.bids.assign([3, 3, 3, 3])
	v.trick = trick
	return v


func _table() -> Array:
	_before()
	var app: App = load("res://scenes/main.tscn").instantiate()
	add_child(app)
	await _frames(2)
	var session := ServerLike.new(_view(["2H", "5H", "3C"], [LEAD]))
	var table := TableScreen.new(session)
	app.push(table)
	await _seconds(0.4)
	return [app, table, session]


func test_a_throw_waits_landed_for_a_slow_server_and_then_hands_off() -> void:
	var r := await _table()
	var table: TableScreen = r[1]
	var session: ServerLike = r[2]
	var fan := table._hand
	_tap(fan, _strip(fan, "5H"))
	expect_eq(session.played, ["5H"])
	expect_true(table._trick.pending_ids().has("5H"), "the card is in the air")
	expect_true(not fan._nodes.has("5H"), "never both in the air and in the hand")

	# Well past the flight's own length: still no word from the server.
	await _seconds(0.7)
	expect_true(table._trick.pending_ids().has("5H"), "the landed card holds until confirmed")

	var confirmed: Array[String] = ["2H", "3C"]
	session.confirm(_view(confirmed, [LEAD, {"seat": 0, "card": "5H"}], 2))
	await _frames(1)
	expect_true(table._trick.pending_ids().is_empty(), "nothing left waiting")
	expect_true(table._trick._cards.has("5H"), "the card stays on the felt")
	r[0].queue_free()


func test_a_throw_the_server_never_confirms_comes_back_to_the_hand() -> void:
	var r := await _table()
	var table: TableScreen = r[1]
	var fan := table._hand
	_tap(fan, _strip(fan, "5H"))
	expect_true(not fan._nodes.has("5H"))
	await _seconds(TrickCluster.CONFIRM_TIMEOUT + 0.3)
	expect_true(table._trick.pending_ids().is_empty(), "the flight is gone")
	expect_true(not table._trick._cards.has("5H"), "and off the felt")
	expect_true(fan._nodes.has("5H"), "back in the hand")
	r[0].queue_free()


func test_a_refused_card_says_why() -> void:
	var r := await _table()
	var table: TableScreen = r[1]
	var session: ServerLike = r[2]
	var fan := table._hand
	_tap(fan, _strip(fan, "3C"))
	await _frames(1)
	expect_eq(session.played, [], "nothing sent")
	expect_eq(table._hint.shown_text(), "Follow suit — play a heart")
	await _seconds(TableScreen.HINT_TIME + 0.3)
	expect_eq(table._hint.shown_text(), "Your turn", "the hint clears back to the turn prompt")
	r[0].queue_free()


func test_refusal_hints_explain_the_rule() -> void:
	var trick := [{"seat": 1, "card": "9H"}]
	var hand: Array[String] = ["2H", "QC", "4S"]
	expect_eq(HintLine.illegal(_view(hand, trick), "QC")["text"], "Follow suit — play a heart")
	var no_hearts: Array[String] = ["QC", "4S"]
	expect_eq(HintLine.illegal(_view(no_hearts, trick), "QC")["text"], "No hearts left — you must play a spade")
	var trumped := [{"seat": 1, "card": "9H"}, {"seat": 2, "card": "8S"}]
	expect_eq(HintLine.illegal(_view(no_hearts, trumped), "QC")["text"], "Overtrump — play a higher spade")
	var low := [{"seat": 1, "card": "9H"}]
	var hearts: Array[String] = ["2H", "KH"]
	expect_eq(HintLine.illegal(_view(hearts, low), "2H")["text"], "Beat the trick — play a higher heart")


# --------------------------------------------------------------- motion

## Every host — the Go server, the LAN host and the solo table — leaves a
## finished trick on the felt for 1100 ms before clearing it. The throw,
## gather and sweep must all be over by then, at every animation speed, or the
## cards vanish mid-flight.
func test_the_trick_sequence_fits_the_host_linger_at_every_speed() -> void:
	for speed in Settings.ANIMATION_SCALE:
		var scale: float = Settings.ANIMATION_SCALE[speed]
		expect_true(Motion.TRICK_ANIMATION_MS * Motion.trick_scale(scale) < GameSession.TRICK_LINGER * 1000.0,
				"%s must finish before the trick is cleared" % speed)
		expect_true(Motion.trick_scale(scale) <= scale, "the cap only ever shortens it (%s)" % speed)
	expect_eq(Motion.trick_scale(1.0), 1.0, "normal speed is untouched")


func test_the_deal_animation_fits_before_bidding_opens() -> void:
	expect_true(GameSession.DEAL_GRACE >= Motion.DEAL_TOTAL, "the grace covers the whole deal")
