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


# ---------------------------------------------------------- every screen

## Phones and tablets, in dp: a fold's cover screen, small and tall phones, a
## 7" tablet, an open fold, an iPad mini and a 12.9" iPad Pro.
const DEVICES := [Vector2(280, 653), Vector2(320, 568), Vector2(360, 640), Vector2(360, 800), Vector2(390, 844),
		Vector2(412, 915), Vector2(600, 960), Vector2(673, 841), Vector2(768, 1024), Vector2(1024, 1366)]
const FULL_HAND: Array[String] = ["AS", "10S", "8S", "5S", "AH", "KH", "QH", "3H", "AD", "4D", "9C", "8C", "2C"]
const FULL_TRICK := [{"seat": 1, "card": "KS"}, {"seat": 2, "card": "3S"}, {"seat": 3, "card": "QS"},
		{"seat": 0, "card": "JS"}]


## [param dp] in design pixels, the way [App] sizes the screen.
static func _design(dp: Vector2) -> Vector2i:
	var m := clampf(minf(dp.x, dp.y) / App.DESIGN_SHORT_SIDE, App.MIN_SCALE, App.MAX_SCALE)
	return Vector2i((dp / m).round())


## A table mid-hand: long names, double-figure scores and a dealer's badge.
static func _busy_view(hand: Array[String], trick: Array, turn: int) -> GameView:
	var v := _view(hand, trick, turn)
	v.players = [GameView.make_player(0, "Nabin", "human"), GameView.make_player(1, "Bishnu Prasad", "human"),
			GameView.make_player(2, "Kamal", "bot"), GameView.make_player(3, "Sita", "bot")]
	v.hand_counts.assign([hand.size(), 12, 12, 12])
	v.bids.assign([4, 3, 12, 2])
	v.tricks_won.assign([2, 1, 10, 0])
	return v


## Every phone and tablet either way up, with a full hand and a full trick:
## nothing at the table touches anything it must not or leaves the screen, the
## played cards gather on the felt's centre, and a larger screen draws the
## whole table larger.
func test_the_table_fits_every_screen() -> void:
	var scales := await _every_screen(true)
	# A phone draws it at (or, for the longest name, all but at) its design size.
	expect_true(scales[Vector2i(390, 844)] >= 0.99 and scales[Vector2i(390, 844)] <= 1.0,
			"a phone draws the table at its design size, got %s" % scales[Vector2i(390, 844)])
	expect_near(scales[Vector2i(844, 390)], 1.0, 0.001, "and on its side")
	var ipad := _design(Vector2(1024, 1366))
	expect_true(scales[ipad] > 1.2 and scales[Vector2i(ipad.y, ipad.x)] > 1.2, "a tablet draws it larger")


## The same with the table put away (Settings → Show table off): nothing
## touches or leaves the screen, every seat keeps to its own edge, centred
## along it, and the played cards gather on the screen's centre.
func test_without_the_table_the_seats_keep_to_the_edges() -> void:
	var scales := await _every_screen(false)
	var ipad := _design(Vector2(1024, 1366))
	expect_true(scales[ipad] > 1.2 and scales[Vector2i(ipad.y, ipad.x)] > 1.2, "a tablet draws it larger")


## Plays a busy table on every device either way up, with the table shown or
## put away, checking each screen; gives back each screen's scale.
func _every_screen(show_table: bool) -> Dictionary:
	_before()
	Settings.show_table = true
	var root := get_tree().root
	var headless := [root.size, root.content_scale_size]
	var app: App = load("res://scenes/main.tscn").instantiate()
	add_child(app)
	await _frames(2)
	var after_mine: Array[String] = FULL_HAND.filter(func(c): return c != "10S")
	var session := ServerLike.new(_busy_view(FULL_HAND, FULL_TRICK.slice(0, 3), 0))
	var table := TableScreen.new(session)
	app.push(table)
	await _seconds(0.4)
	# Put away (or kept) mid-game, from the settings sheet.
	Settings.show_table = show_table
	await _frames(2)
	expect_eq(table._felt.visible, show_table, "the felt drawn only with the table shown")
	var scales := {}
	for dp in DEVICES:
		var standing := _design(dp)
		for shape in [standing, Vector2i(standing.y, standing.x)]:
			root.size = shape
			root.content_scale_size = shape
			# The player's turn, with the widest thing the hint ever says.
			session.confirm(_busy_view(FULL_HAND, FULL_TRICK.slice(0, 3), 0))
			table._hint.hint = HintLine._beat(Cards.Suit.DIAMONDS)
			await _seconds(0.5)
			_expect_clear(table, "%s on the player's turn" % shape)
			session.confirm(_busy_view(after_mine, FULL_TRICK, 1))
			table._hint.hint = {}
			await _seconds(0.6)
			_expect_clear(table, "%s with a full trick" % shape)
			var trick := _bounds(_items(table).filter(func(it): return it[0] == "trick"))
			if show_table:
				var felt := table._felt.get_global_rect()
				expect_near(trick.get_center().distance_to(felt.get_center()), 0.0, 2.0,
						"the played cards gather on the felt's centre at %s" % shape)
				expect_true(felt.encloses(trick), "the played cards lie on the felt at %s" % shape)
			else:
				_expect_at_edges(table, trick, shape)
			expect_eq(table._body.scale.x, table._body.scale.y, "one scale for the whole table at %s" % shape)
			scales[shape] = table._body.scale.x
	root.size = headless[0]
	root.content_scale_size = headless[1]
	Settings.show_table = true
	app.queue_free()
	await _frames(1)
	return scales


## With the table put away: the side seats at the screen's left and right
## edges and level with its centre, the top seat and the player's own plate at
## its top and bottom edges and centred across it, the played cards on its
## centre.
func _expect_at_edges(table: TableScreen, trick: Rect2, shape: Vector2i) -> void:
	var view := table.get_viewport_rect()
	var mid := view.get_center()
	var k := table._body.scale.x
	var left := table._seats[SeatView.Slot.LEFT].get_global_rect() as Rect2
	var right := table._seats[SeatView.Slot.RIGHT].get_global_rect() as Rect2
	var top := table._seats[SeatView.Slot.TOP].get_global_rect() as Rect2
	var plate := table._seats[SeatView.Slot.BOTTOM].get_global_rect() as Rect2
	expect_near(trick.get_center().distance_to(mid), 0.0, 2.0, "the played cards on the screen's centre at %s" % shape)
	# The side seats stand in a column as wide as the wider of them can grow,
	# against the screen's side.
	var column: float = table._seats[SeatView.Slot.LEFT].reserved_size().x
	column = maxf(column, table._seats[SeatView.Slot.RIGHT].reserved_size().x)
	var from_side := UI.sc(0, 8) + (TableLayout.EDGE + column / 2.0) * k
	expect_near(left.get_center().x, from_side, 1.0, "the left seat at the left edge at %s" % shape)
	expect_near(view.end.x - right.get_center().x, from_side, 1.0, "the right seat at the right edge at %s" % shape)
	expect_near(left.get_center().y, mid.y, 1.0, "the left seat level with the centre at %s" % shape)
	expect_near(right.get_center().y, mid.y, 1.0, "the right seat level with the centre at %s" % shape)
	expect_near(top.get_center().x, mid.x, 1.0, "the top seat centred at %s" % shape)
	expect_true(top.position.y <= table._hud.get_global_rect().end.y + (TableLayout.GAP + 1.0) * k,
			"the top seat at the top edge, only the HUD above it, at %s" % shape)
	expect_near(plate.get_center().x, mid.x, 1.0, "the player's plate centred at %s" % shape)
	expect_true(plate.end.y >= view.end.y - (UI.sc(14, 4) + 1.0) * k, "the player's plate at the bottom edge at %s" % shape)


## Nothing on screen leaves it, and nothing touches anything of anyone else's.
## The player's hand reaching over their own plate is the one overlap meant.
func _expect_clear(table: TableScreen, what: String) -> void:
	var items := _items(table)
	var view := table.get_viewport_rect().grow(0.5)
	for it in items:
		expect_true(view.encloses(it[2]), "%s:%s on screen at %s: %s" % [it[0], it[1], what, it[2]])
	for i in items.size():
		for j in range(i + 1, items.size()):
			var a: Array = items[i]
			var b: Array = items[j]
			if a[0] == b[0] or ([a[0], b[0]] as Array).has("hand") and ([a[0], b[0]] as Array).has("plate"):
				continue
			var shared: Rect2 = a[2].intersection(b[2])
			expect_true(shared.size.x <= 1.5 or shared.size.y <= 1.5,
					"%s:%s clear of %s:%s at %s" % [a[0], a[1], b[0], b[1], what])


## Everything at the table that stays put through a trick, as
## `[owner, part, screen rect]`.
func _items(table: TableScreen) -> Array:
	var items := []
	var names := ["back", "tune", "spacer", "round"]
	for i in table._hud.get_child_count():
		if names[i] != "spacer":
			items.append(["hud", names[i], (table._hud.get_child(i) as Control).get_global_rect()])
	for slot in table._seats:
		var seat: SeatView = table._seats[slot]
		var owner := "plate" if slot == SeatView.Slot.BOTTOM else "seat %d" % slot
		items.append([owner, "name", seat._name_chip.get_global_rect()])
		items.append([owner, "avatar", seat.avatar.get_global_rect()])
		items.append([owner, "score", seat._bid_chip.get_global_rect()])
		var fan := seat.avatar.fan_rect()
		if fan.has_area():
			items.append([owner, "fan", _on_screen(seat.avatar, fan)])
	for id in table._hand._nodes:
		var card: CardView = table._hand._nodes[id]
		if card.visible:
			items.append(["hand", id, _on_screen(card, Rect2(Vector2.ZERO, card.size))])
	for id in table._trick._cards:
		var card: CardView = table._trick._cards[id].node
		items.append(["trick", id, _on_screen(card, Rect2(Vector2.ZERO, card.size))])
	if not table._hint.shown_text().is_empty():
		items.append(["hint", table._hint.shown_text(), table._hint.get_global_rect()])
	return items


## [param local] in [param node]'s coordinates, turned and scaled onto the
## screen: the box around it.
static func _on_screen(node: CanvasItem, local: Rect2) -> Rect2:
	var xf := node.get_global_transform()
	return _bounds_of([xf * local.position, xf * Vector2(local.end.x, local.position.y), xf * local.end,
			xf * Vector2(local.position.x, local.end.y)])


static func _bounds_of(points: Array) -> Rect2:
	var out := Rect2(points[0], Vector2.ZERO)
	for p in points:
		out = out.expand(p)
	return out


static func _bounds(items: Array) -> Rect2:
	var out: Rect2 = items[0][2]
	for it in items:
		out = out.merge(it[2])
	return out
