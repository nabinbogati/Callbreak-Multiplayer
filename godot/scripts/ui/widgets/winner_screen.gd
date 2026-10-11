class_name WinnerScreen
extends Control

## The final-game screen: a trophy, the podium (1st tallest and
## centre-most, 2nd and 3rd flanking, 4th apart and lowest), and
## the player's next move — another game or home. The round history is a tap
## away, behind the same pill as on the table, so it all fits on one screen.

signal play_again
signal go_home

const VISUAL_ORDER := [1, 0, 2, 3]
const PEDESTAL_HEIGHTS := [100.0, 70.0, 54.0, 40.0]
const AVATAR_SIZES := [76.0, 62.0, 58.0, 52.0]
const PLACE_LABEL := {1: "1st", 2: "2nd", 3: "3rd", 4: "4th"}
const PEDESTALS := {
	1: [Color("#FFE7A3"), Color("#F0C75E"), Color("#C9922A")],
	2: [Color("#F2F5F8"), Color("#C3CCD6"), Color("#8995A2")],
	3: [Color("#F0B78C"), Color("#C98552"), Color("#8C5A34")],
	4: [Color("#52625B"), Color("#34413B"), Color("#1D2622")],
}

var _view: GameView
var _history: Control
var _trophy: Control


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


## Opens the round history over the podium, or closes it. Kept here rather
## than in the table's overlay, whose rebuild would replay the entrance.
func _toggle_history() -> void:
	if _history != null:
		_history.queue_free()
		_history = null
		return
	_history = RoundHistory.overlay(_view, _toggle_history)
	add_child(_history)


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
