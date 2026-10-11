extends Node

## The benchmark itself; loaded at runtime by bench.gd so the app's classes
## compile after the autoloads exist.
##
## Plays the table's busiest moments on their real widgets and times every
## frame, start to finish: everything the main thread does in that frame
## (scripts, rebuilding drawings, layout). Run with --fixed-fps 60 so each
## frame moves the animations on by 1/60 s, as on a phone. Headless rendering is
## a stub, so this measures the CPU side, not the GPU. Run under a display
## (xvfb-run, --rendering-driver opengl3) and it also counts the draw calls
## in each frame that was drawn.

const HAND: Array[String] = ["AS", "10S", "8S", "5S", "AH", "KH", "QH", "3H", "AD", "4D", "9C", "8C", "2C"]

var _host: Control
var _rows: Array = []


func run() -> void:
	var settings := get_node("/root/Settings")
	settings.use_memory_storage()
	settings.sfx_enabled = false
	settings.music_enabled = false
	_host = Control.new()
	_host.size = Vector2(390, 844)
	add_child(_host)
	await _frames(5)

	await _idle()
	await _deal()
	await _turn_changes()
	await _your_turn()
	await _trick()
	await _solo_hand()

	var drawn := DisplayServer.get_name() != "headless"
	print(("Whole-frame time, drawing included (a software renderer such as llvmpipe draws on the CPU)" if drawn
			else "Script and layout time per frame (headless: nothing is drawn)") + ", 60 fps steps:")
	print("  %-44s %6s %8s %8s %8s %10s" % ["scenario", "frames", "mean ms", "p95 ms", "max ms", "total ms"]
			+ ("  %9s %9s" % ["draws avg", "draws max"] if drawn else ""))
	for r in _rows:
		print("  %-44s %6d %8.2f %8.2f %8.2f %10.1f" % r.slice(0, 6)
				+ ("  %9.1f %9d" % [r[6], r[7]] if drawn else ""))


## Times [param count] frames, or until [param done] holds.
func _measure(label: String, count: int, done := Callable()) -> void:
	var times: Array[float] = []
	var draws: Array[int] = []
	for i in count:
		var t := Time.get_ticks_usec()
		await get_tree().process_frame
		times.append((Time.get_ticks_usec() - t) / 1000.0)
		# The last frame drawn; 0 when the engine skipped drawing an idle frame.
		var calls := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
		if calls > 0:
			draws.append(calls)
		if done.is_valid() and done.call():
			break
	var sorted := times.duplicate()
	sorted.sort()
	var total := 0.0
	for x in times:
		total += x
	var draw_total := 0
	for d in draws:
		draw_total += d
	_rows.append([label, times.size(), total / times.size(), sorted[int(sorted.size() * 0.95)], sorted[-1], total,
			float(draw_total) / maxi(draws.size(), 1), draws.max() if not draws.is_empty() else 0, draws.size()])


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _idle() -> void:
	await _measure("nothing moving", 60)


func _deal() -> void:
	var deal := DealOverlay.new()
	_host.add_child(deal)
	deal.start = Vector2(195, 380)
	deal.seat_targets = {0: Vector2(195, 760), 1: Vector2(30, 380), 2: Vector2(195, 60), 3: Vector2(360, 380)}
	var targets := []
	for i in 13:
		targets.append([Vector2(60 + i * 22, 740), 0.0])
	deal.hand_targets = targets
	deal.begin(0, 0)
	await _measure("a whole deal", 600, func(): return not deal.is_processing())
	deal.queue_free()
	await _frames(2)


func _player(seat: int) -> Dictionary:
	return GameView.make_player(seat, "Player %d" % seat, "human")


## An opponent's turn starting and ending, twice: the second after each
## change, as the player sees it.
func _turn_changes() -> void:
	var seat := SeatView.new(SeatView.Slot.TOP)
	_host.add_child(seat)
	seat.update(_player(2), 3, 1, false, false, false, 0, 13)
	seat.size = seat.get_combined_minimum_size()
	await _frames(90)
	for k in 4:
		seat.update(_player(2), 3, 1, k % 2 == 0, false, false, 0, 13)
		await _measure("opponent's turn starts/ends (1 s after)" if k == 0 else "", 60)
	_merge_last(4)
	seat.queue_free()
	await _frames(2)


## The player's own turn coming round: thirteen cards, five playable.
func _your_turn() -> void:
	var fan := HandFan.new()
	_host.add_child(fan)
	fan.card_width = 58
	fan.size = Vector2(390, fan.fan_height())
	fan.set_hand(HAND, [], false, 13)
	await _frames(60)
	fan.set_hand(HAND, ["AS", "10S", "8S", "5S"], true, 13)
	await _measure("your turn comes round (0.5 s after)", 30)
	fan.queue_free()
	await _frames(2)


## Four cards thrown in, then the trick decided and taken.
func _trick() -> void:
	var trick := TrickCluster.new()
	_host.add_child(trick)
	trick.size = _host.size
	var anchors := {SeatView.Slot.BOTTOM: Vector2(195, 760), SeatView.Slot.LEFT: Vector2(30, 380),
			SeatView.Slot.TOP: Vector2(195, 60), SeatView.Slot.RIGHT: Vector2(360, 380)}
	var center := Vector2(195, 380)
	var plays := []
	var cards := ["KH", "3H", "QH", "AH"]
	for i in 4:
		plays.append({"seat": (i + 1) % 4, "card": cards[i]})
		trick.sync(plays, 0, -1, anchors, {}, center, 56)
		await _measure("a trick: four throws, then the take" if i == 0 else "", 30)
	trick.sync(plays, 0, 0, anchors, {}, center, 56)
	await _measure("", 90)
	_merge_last(5)
	trick.queue_free()
	await _frames(2)


## A whole hand at a solo table in the real app, deal to scoreboard, the bots
## at their normal pace and the player playing their first legal card.
func _solo_hand() -> void:
	var app: App = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(app)
	await _frames(3)
	var session := LocalSession.new("Bench", "normal", 3, 1.0, 7)
	var table := TableScreen.new(session)
	session.changed.connect(func():
		var v := session.view
		if v == null or not v.is_my_turn():
			return
		if v.phase == GameView.BIDDING and not v.i_have_bid():
			session.place_bid.call_deferred(Rules.suggest_bid(v.hand))
		elif v.phase == GameView.PLAYING and not v.legal_move_ids.is_empty():
			session.play.call_deferred(v.legal_move_ids[0]))
	app.push(table)
	await _measure("one solo hand on the real table", 20000,
			func(): return session.view != null and session.view.phase == GameView.HAND_OVER)
	app.queue_free()
	await _frames(2)


## Folds the last [param n] rows into the first of them.
func _merge_last(n: int) -> void:
	var rows := _rows.slice(_rows.size() - n)
	_rows.resize(_rows.size() - n)
	var frames := 0
	var total := 0.0
	var p95 := 0.0
	var top := 0.0
	var drawn := 0
	var draw_sum := 0.0
	var draw_top := 0
	for r in rows:
		frames += r[1]
		total += r[5]
		p95 = maxf(p95, r[3])
		top = maxf(top, r[4])
		drawn += r[8]
		draw_sum += r[6] * r[8]
		draw_top = maxi(draw_top, r[7])
	_rows.append([rows[0][0], frames, total / frames, p95, top, total, draw_sum / maxi(drawn, 1), draw_top, drawn])
