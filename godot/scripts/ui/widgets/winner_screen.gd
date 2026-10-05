class_name WinnerScreen
extends Control

## The final-game screen: a burst of confetti, a trophy, the podium (1st
## tallest and centre-most, 2nd and 3rd flanking, 4th apart and lowest), and
## the player's next move — another game or home. The round history is a tap
## away, behind the same pill as on the table, so it all fits on one screen.

signal play_again
signal go_home

const VISUAL_ORDER := [1, 0, 2, 3]
const PEDESTAL_HEIGHTS := [100.0, 70.0, 54.0, 40.0]
const AVATAR_SIZES := [76.0, 62.0, 58.0, 52.0]
const STAGGER := [0.2, 0.05, 0.3, 0.4]
const PLACE_LABEL := {1: "1st", 2: "2nd", 3: "3rd", 4: "4th"}
const PEDESTALS := {
	1: [Color("#FFE7A3"), Color("#F0C75E"), Color("#C9922A")],
	2: [Color("#F2F5F8"), Color("#C3CCD6"), Color("#8995A2")],
	3: [Color("#F0B78C"), Color("#C98552"), Color("#8C5A34")],
	4: [Color("#52625B"), Color("#34413B"), Color("#1D2622")],
}
const ENTRANCE := 0.9

var _t := 0.0
var _view: GameView
var _history: Control
var _trophy: Control
var _headline: Control
var _columns: Array = []


func _init(view: GameView) -> void:
	_view = view
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := Control.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.draw.connect(func():
		var r := Rect2(Vector2.ZERO, bg.size)
		var pts := PackedVector2Array([r.position, Vector2(r.end.x, 0), r.end, Vector2(0, r.end.y)])
		Draw.fill_radial(bg, pts, Draw.align(r, Vector2(0, -0.6)), 1.2 * minf(r.size.x, r.size.y),
				[Color("#163A2CF2"), Color("#040F0BF8")]))
	bg.resized.connect(bg.queue_redraw)
	add_child(bg)
	var confetti := Confetti.new()
	confetti.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(confetti)

	var ranked := view.rankings.duplicate()
	ranked.sort_custom(func(a, b): return a["place"] < b["place"])
	var you_won: bool = not ranked.is_empty() and ranked[0]["seat"] == view.you
	var headline := "Game over"
	if not ranked.is_empty():
		headline = "You win!" if you_won else "%s wins" % view.player(ranked[0]["seat"]).get("name", "")

	var col := UI.vbox(0)
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	_trophy = _make_trophy(UI.sc(64, 36))
	col.add_child(_trophy)
	col.add_child(UI.gap(UI.sc(10, 6)))
	var word := UI.gold_text(headline, UI.sc(28, 22))
	var fv := FontVariation.new()
	fv.base_font = Tokens.font("display")
	fv.spacing_glyph = int(round(UI.sc(28, 22) * 0.04))
	word.add_theme_font_override("font", fv)
	_headline = word
	col.add_child(word)
	col.add_child(UI.label("Game over · %d rounds played" % view.hands_per_game, UI.sc(12, 11), Tokens.TEXT_FAINT,
			"medium", HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.gap(UI.sc(22, 8)))
	if ranked.size() == 4:
		col.add_child(_podium(view, ranked))
	col.add_child(UI.gap(UI.sc(28, 12)))
	# Landscape leaves little height: the buttons go dense to keep the column
	# clear of a gesture bar.
	var dense := not UI.portrait
	col.add_child(UI.hbox(12, [UI.expand(UI.ghost_button("Home", func(): go_home.emit(), "home_rounded", dense)),
			UI.expand(UI.gold_button("Play again", func(): play_again.emit(), "replay_rounded", dense))]))

	var padded := UI.margin(col, Vector4(20, UI.sc(20, 12), 20, UI.sc(20, 12)))
	padded.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(padded)

	# Where the table's round pill sits, so the history is found where it was.
	var chart := UI.icon("leaderboard_rounded", 15, Color(Tokens.GOLD, 0.8))
	chart.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var pill := UI.glass_pill(UI.hbox(4, [UI.label("Round history", 12, Tokens.GOLD, "bold"), chart]), _toggle_history,
			14, Vector4(UI.sc(12, 14), 9, UI.sc(12, 14), 9), Color(Tokens.GOLD_BORDER, 0.45))
	add_child(pill)
	# Never wider than 560, centred. Upright, the column starts below the pill,
	# which would sit over the trophy on a narrow screen. A window too short
	# for it all (a desktop one only just taller than wide) shrinks it whole
	# rather than scroll.
	var fit := func():
		pill.reset_size()
		pill.position = Vector2(size.x - UI.safe.z - UI.sc(12, 22) - pill.size.x, UI.safe.y + UI.sc(8, 10))
		var w := minf(size.x, 560 + 40)
		var top := pill.position.y + pill.size.y if UI.portrait else UI.safe.y
		padded.offset_left = (size.x - w) / 2.0 + UI.safe.x
		padded.offset_right = -(size.x - w) / 2.0 - UI.safe.z
		padded.offset_top = top
		padded.offset_bottom = -UI.safe.w
		padded.pivot_offset = Vector2(padded.size.x / 2.0, 0)
		padded.scale = Vector2.ONE * minf((size.y - top - UI.safe.w) / padded.get_combined_minimum_size().y, 1.0)
	resized.connect(fit)
	padded.minimum_size_changed.connect(fit)
	_apply(0.0)


## Opens the round history over the podium, or closes it. Kept here rather
## than in the table's overlay, whose rebuild would replay the entrance.
func _toggle_history() -> void:
	if _history != null:
		_history.queue_free()
		_history = null
		return
	_history = RoundHistory.overlay(_view, _toggle_history)
	add_child(_history)


func _process(delta: float) -> void:
	if _t >= 1.0:
		return
	_t = minf(_t + delta / ENTRANCE, 1.0)
	_apply(_t)


func _apply(t: float) -> void:
	# The trophy springs in; the headline fades up with the entrance.
	var spring := Motion.elastic_out(clampf(t / 0.9, 0.0, 1.0))
	_trophy.pivot_offset = _trophy.size / 2.0
	_trophy.scale = Vector2.ONE * (0.4 + 0.6 * spring)
	_headline.modulate.a = t
	for entry in _columns:
		var start: float = entry[1]
		var local := clampf((t - start) / (minf(start + 0.55, 1.0) - start), 0.0, 1.0)
		var e := Motion.ease_out_back(local)
		var column: Control = entry[0]
		column.modulate.a = clampf(e, 0.0, 1.0)
		column.position.y = column.size.y * 0.25 * (1.0 - e)


func _make_trophy(size_px: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(size_px, size_px) * 1.5
	c.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func():
		var mid := c.size / 2.0
		Draw.fill_radial(c, Draw.ellipse_points(mid, mid, 48), mid, size_px * 0.75,
				[Color(Tokens.GOLD, 0.35), Color(Tokens.GOLD, 0.0)])
		Draw.icon(c, "emoji_events_rounded", Rect2(mid - Vector2.ONE * size_px / 2.0, Vector2.ONE * size_px), Tokens.GOLD))
	return c


func _podium(view: GameView, ranked: Array) -> Control:
	var row := UI.hbox(UI.sc(10, 8))
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	for rank_index in VISUAL_ORDER:
		var r: Dictionary = ranked[rank_index]
		var column := _column(view, r, rank_index)
		var wrap := Control.new()
		wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wrap.size_flags_vertical = Control.SIZE_SHRINK_END
		wrap.add_child(column)
		wrap.custom_minimum_size = column.get_combined_minimum_size()
		column.minimum_size_changed.connect(func(): wrap.custom_minimum_size = column.get_combined_minimum_size())
		wrap.resized.connect(func(): column.size = wrap.size)
		row.add_child(wrap)
		_columns.append([column, STAGGER[rank_index]])
	return row


func _column(view: GameView, r: Dictionary, rank_index: int) -> Control:
	var seat: int = r["seat"]
	var place: int = r["place"]
	var player := view.player(seat)
	var is_you := seat == view.you
	var first := place == 1
	var colors: Array = PEDESTALS.get(place, PEDESTALS[4])
	var avatar_size: float = UI.sc(AVATAR_SIZES[rank_index], AVATAR_SIZES[rank_index] * 0.8)
	var pedestal_h: float = UI.sc(PEDESTAL_HEIGHTS[rank_index], PEDESTAL_HEIGHTS[rank_index] * 0.7)

	var avatar := Control.new()
	avatar.custom_minimum_size = Vector2(avatar_size, avatar_size)
	avatar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	avatar.draw.connect(func():
		var rect := Rect2(Vector2.ZERO, Vector2.ONE * avatar_size)
		var c := rect.get_center()
		Draw.box_shadow(avatar, rect, avatar_size / 2.0,
				Tokens.glow(Tokens.GOLD, 1.2, 22) if first else Tokens.SHADOW_LOW)
		var stops: Array = [Tokens.GOLD_LIGHT, Tokens.GOLD_MID, Tokens.GOLD_DEEP] if is_you else colors
		Draw.fill_linear(avatar, Draw.ellipse_points(c, Vector2.ONE * avatar_size / 2.0, 48), rect.position, rect.end,
				stops)
		Draw.circle_border(avatar, c, avatar_size / 2.0,
				Color(Tokens.GOLD_LIGHT, 0.95) if first or is_you else Color(Tokens.TEXT_MUTED, 0.35), 2.5 if first else 1.5)
		if GameView.is_bot(player):
			var icon := avatar_size * 0.42
			Draw.icon(avatar, "robot", Rect2(c - Vector2.ONE * icon / 2.0, Vector2.ONE * icon), Tokens.ON_GOLD)
		else:
			SeatView.centered_text(avatar, GameView.initial(player.get("name", "")), c, avatar_size * 0.4, "bold",
					Tokens.ON_GOLD))

	var name := UI.label("You" if is_you else str(player.get("name", "")), UI.sc(12, 11), Tokens.TEXT_PRIMARY,
			"semibold", HORIZONTAL_ALIGNMENT_CENTER)
	name.clip_text = true
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name.custom_minimum_size.x = minf(Tokens.font("semibold").get_string_size(name.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			int(round(UI.sc(12, 11)))).x + 1, 78)
	name.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var score := UI.label("%.1f" % r["total"], UI.sc(13, 11), Tokens.GOLD, "bold", HORIZONTAL_ALIGNMENT_CENTER)

	var pedestal := Control.new()
	pedestal.custom_minimum_size = Vector2(68, pedestal_h)
	pedestal.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pedestal.draw.connect(func():
		var rect := Rect2(Vector2.ZERO, pedestal.size)
		var pts := Draw.top_rounded_rect_points(rect, 10)
		Draw.box_shadow(pedestal, rect, 10, Tokens.SHADOW_LOW)
		Draw.fill_linear(pedestal, pts, Vector2.ZERO, Vector2(0, rect.size.y), colors)
		var fs := UI.sc(15, 12)
		SeatView.centered_text(pedestal, PLACE_LABEL.get(place, str(place)),
				Vector2(rect.size.x / 2.0, UI.sc(8, 5) + fs * 1.25 / 2.0), fs, "bold",
				Tokens.ON_GOLD if place <= 3 else Tokens.TEXT_ON_DARK))

	var parts: Array = []
	if first:
		parts.append(UI.center(UI.icon("crown", UI.sc(22, 16), Tokens.GOLD)))
	parts.append_array([avatar, UI.gap(UI.sc(8, 4)), name, score, UI.gap(UI.sc(8, 4)), pedestal])
	return UI.vbox(0, parts)


## A single burst of paper: pieces launched from the top, fluttering down with
## a sway and a spin. Positions are a pure function of time and a fixed seed,
## so one clock drives it all — and it stops for good once it has fallen.
class Confetti:
	extends Control

	const DURATION := 3.2
	const COUNT := 70
	const COLORS := [Color("#F5D78A"), Color("#FFF6D8"), Color("#3DDC84"), Color("#7CC4FF"), Color("#FF6F61"),
			Color("#E8B84A")]

	static var _pieces: Array = []
	var _t := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		if _pieces.is_empty():
			var rng := RandomNumberGenerator.new()
			rng.seed = 42
			for i in COUNT:
				_pieces.append({"x": rng.randf(), "delay": rng.randf() * 0.35, "fall": 0.75 + rng.randf() * 0.5,
						"sway": 0.02 + rng.randf() * 0.05, "spin": (rng.randf() - 0.5) * 18.0,
						"size": 5.0 + rng.randf() * 6.0, "color": COLORS[i % COLORS.size()]})

	func _process(delta: float) -> void:
		_t = minf(_t + delta / DURATION, 1.0)
		queue_redraw()
		if _t >= 1.0:
			set_process(false)

	func _draw() -> void:
		if _t >= 1.0:
			return
		for p in _pieces:
			var local := clampf((_t - p["delay"]) / (1.0 - p["delay"]), 0.0, 1.0)
			if local <= 0.0:
				continue
			var y: float = -0.1 + Motion.enter(local) * p["fall"] * 1.1
			var x: float = p["x"] + sin(local * PI * 4.0 + p["x"] * 9.0) * p["sway"]
			var fade := (1.0 - local) / 0.25 if local > 0.75 else 1.0
			# A tumbling rectangle reads as paper: squash it with the spin.
			var squash := 0.35 + 0.65 * absf(cos(local * p["spin"]))
			var s: float = p["size"]
			draw_set_transform(Vector2(x * size.x, y * size.y), p["spin"] * local, Vector2.ONE)
			draw_rect(Rect2(-s / 2.0, -s * 0.55 * squash / 2.0, s, s * 0.55 * squash), Color(p["color"], 0.9 * fade))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
