class_name Scoreboard
extends PanelContainer

## Between-hands summary: what everyone bid and took this hand, what it was
## worth, and the running totals — leader first, with a trophy. On a table
## that will not wait, a bar counts down to the next deal instead of the
## button.

signal continue_pressed

const PLACE := {1: "1st", 2: "2nd", 3: "3rd", 4: "4th"}


## [param max_height] is the most of the screen the panel may take; past it the
## content scrolls.
func _init(view: GameView, deadline_ms := 0, max_height := INF) -> void:
	var pad := Vector4(UI.sc(18, 14), UI.sc(18, 12), UI.sc(18, 14), UI.sc(16, 10))
	add_theme_stylebox_override("panel", UI.glass_box(pad))
	var final := view.phase == GameView.GAME_OVER
	var col := UI.vbox(0)
	col.add_child(UI.gold_text("Game over" if final else "Round %d of %d" % [view.hand_number(), view.hands_per_game],
			UI.sc(21, 16)))
	col.add_child(UI.label("Final standings" if final else "Round results", UI.sc(12, 10), Tokens.TEXT_FAINT, "medium",
			HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.gap(UI.sc(14, 8)))
	col.add_child(UI.margin(UI.hbox(0, [UI.expand(_header("Player", HORIZONTAL_ALIGNMENT_LEFT)),
			_cell(_header("Bid/Won"), UI.sc(52, 46)), _cell(_header("Round"), UI.sc(50, 44)),
			_cell(_header("Total", HORIZONTAL_ALIGNMENT_RIGHT), UI.sc(52, 46))]), UI.pad_hv(UI.sc(12, 10), 0)))
	col.add_child(UI.gap(UI.sc(6, 4)))

	var place_of := {}
	for r in view.rankings:
		place_of[r["seat"]] = r["place"]
	var seats := [0, 1, 2, 3]
	seats.sort_custom(func(a, b): return view.totals[a] > view.totals[b])
	for i in seats.size():
		var seat: int = seats[i]
		var scores: Array = view.round_scores[seat]
		var row := _row(view, seat, i == 0 and view.totals[seats[0]] > view.totals[seats[1]],
				scores.back() if not scores.is_empty() else null, place_of.get(seat, 0) if final else 0)
		# Rows slide in one after another.
		col.add_child(UI.rise_in(row, (320 + 70 * i) / 1000.0, 10))
		col.add_child(UI.gap(UI.sc(6, 4)))
	col.add_child(UI.gap(UI.sc(10, 6)))

	# Networked tables deal the next hand on their own once the deadline runs
	# out, so the button only shows where nobody is timing the wait.
	if deadline_ms <= 0 or final:
		col.add_child(UI.gold_button("Play again" if final else "Next round", func(): continue_pressed.emit(),
				"replay_rounded" if final else "arrow_forward_rounded", not UI.portrait))
	if not final and deadline_ms > 0:
		col.add_child(UI.gap(UI.sc(6, 4)))
		col.add_child(DeadlineBar.new("Next round", deadline_ms))
	add_child(UI.fit_scroll(col, max_height - pad.y - pad.w))


func _header(text: String, align := HORIZONTAL_ALIGNMENT_CENTER) -> Label:
	var l := UI.label(text.to_upper(), UI.sc(9.5, 8.5), Tokens.TEXT_FAINT, "semibold", align)
	var fv := FontVariation.new()
	fv.base_font = Tokens.font("semibold")
	fv.spacing_glyph = 1
	l.add_theme_font_override("font", fv)
	return l


func _cell(node: Control, width: float) -> Control:
	node.custom_minimum_size.x = width
	return node


func _row(view: GameView, seat: int, leader: bool, delta, place: int) -> Control:
	var player := view.player(seat)
	var is_you := seat == view.you
	var bid: int = view.bids[seat]
	var won: int = view.tricks_won[seat]
	var made := bid >= 0 and won >= bid
	var total: float = view.totals[seat]

	var initial := GameView.initial(str(player.get("name", "")))
	var d := UI.sc(28, 22)
	var avatar := Control.new()
	avatar.custom_minimum_size = Vector2(d, d)
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	avatar.draw.connect(func():
		var r := Rect2(Vector2.ZERO, Vector2(d, d))
		if is_you:
			Draw.rounded_rect(avatar, r, d / 2.0, Tokens.GOLD_BUTTON, true, Color.TRANSPARENT, 0, Tokens.GOLD_BUTTON_STOPS)
		else:
			Draw.disc(avatar, r.get_center(), d / 2.0, Color("#FFFFFF26"))
		SeatView.centered_text(avatar, initial, r.get_center(), UI.sc(12, 10), "bold",
				Tokens.ON_GOLD if is_you else Tokens.TEXT_ON_DARK))

	var name := UI.label(str(player.get("name", "")), UI.sc(13.5, 12), Tokens.TEXT_PRIMARY, "semibold")
	name.clip_text = true
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# As wide as the name needs, so the trophy sits right after it; long names
	# trim instead of pushing the score columns out.
	name.custom_minimum_size.x = minf(Tokens.font("semibold").get_string_size(name.text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			int(round(UI.sc(13.5, 12)))).x + 1, UI.sc(110, 120))
	var who := UI.hbox(4, [name])
	if leader:
		var cup := UI.icon("emoji_events_rounded", UI.sc(15, 13), Tokens.GOLD)
		cup.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		who.add_child(cup)
	if place > 0:
		who.add_child(UI.label(PLACE.get(place, str(place)), UI.sc(11, 10), Tokens.GOLD, "bold"))
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var bid_text := "–" if bid < 0 else "%d / %d" % [bid, won]
	var bid_cell := _cell(UI.label(bid_text, UI.sc(12, 11), Tokens.SUCCESS if made else Tokens.TEXT_MUTED, "semibold",
			HORIZONTAL_ALIGNMENT_CENTER), UI.sc(52, 46))
	var delta_cell := _cell(Control.new(), UI.sc(50, 44))
	if delta != null:
		var dv: float = delta
		delta_cell = _cell(UI.label("%s%.1f" % ["+" if dv > 0 else "", dv], UI.sc(12.5, 11),
				Tokens.DANGER if dv < 0 else Tokens.SUCCESS, "bold", HORIZONTAL_ALIGNMENT_CENTER), UI.sc(50, 44))
	var total_label := UI.label("%.1f" % total, UI.sc(16, 13.5), Tokens.GOLD, "bold", HORIZONTAL_ALIGNMENT_RIGHT)
	var total_cell := _cell(total_label, UI.sc(52, 46))
	# The total counts up from last round's to this one's.
	var from: float = total - (delta if delta != null else 0.0)
	total_label.text = "%.1f" % from
	total_label.create_tween().tween_method(func(t: float):
		total_label.text = "%.1f" % lerpf(from, total, Motion.ease_out_cubic(t)), 0.0, 1.0, 0.7)

	for c in [bid_cell, delta_cell, total_cell]:
		c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := UI.hbox(0, [avatar, UI.gap(0, UI.sc(9, 7)), who, bid_cell, delta_cell, total_cell])
	var style := UI.flat(Color(Tokens.GOLD, 0.1) if is_you else Color("#FFFFFF0F"), UI.sc(12, 10),
			Color(Tokens.GOLD_BORDER, 0.6) if leader else Tokens.HAIRLINE, 1, UI.pad_hv(UI.sc(12, 10), UI.sc(9, 6)))
	return UI.panel(style, row)
