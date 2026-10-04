class_name Scoreboard
extends PanelContainer

## The between-hands summary: standings so far, and Next round — or, on a
## table that will not wait, a bar counting down to the next deal.

signal continue_pressed


func _init(view: GameView, deadline_ms := 0) -> void:
	add_theme_stylebox_override("panel", UI.with_shadow(UI.flat(Tokens.PANEL_SOLID, 18, Color(Tokens.GOLD_BORDER, 0.35), 1,
			Vector4(UI.sc(22, 16), UI.sc(20, 14), UI.sc(22, 16), UI.sc(18, 12))), Color(0, 0, 0, 0.6), 30, Vector2(0, 12)))
	var final := view.phase == GameView.GAME_OVER
	var col := UI.vbox(0)
	col.add_child(UI.gold_text("Game over" if final else "Round %d of %d" % [view.hand_number(), view.hands_per_game],
			UI.sc(20, 16)))
	col.add_child(UI.gap(UI.sc(4, 2)))
	if not final:
		col.add_child(UI.label("Scores so far", UI.sc(12, 10), Tokens.TEXT_FAINT, "medium", HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.gap(UI.sc(16, 8)))

	var place_of := {}
	for r in view.rankings:
		place_of[r["seat"]] = r["place"]
	var seats := [0, 1, 2, 3]
	seats.sort_custom(func(a, b): return view.totals[a] > view.totals[b])
	for seat in seats:
		col.add_child(_row(view.player(seat).get("name", ""), view.totals[seat], place_of.get(seat, 0) if final else 0))
		col.add_child(UI.gap(UI.sc(8, 6)))
	col.add_child(UI.gap(UI.sc(10, 6)))

	if deadline_ms <= 0 or final:
		col.add_child(UI.button("Play again" if final else "Next round", true, func(): continue_pressed.emit(),
				UI.sc(14, 13), Vector4(0, UI.sc(14, 10), 0, UI.sc(14, 10))))
	if not final and deadline_ms > 0:
		col.add_child(UI.gap(UI.sc(12, 8)))
		col.add_child(DeadlineBar.new("Next round", deadline_ms))
	add_child(UI.scroll(col) if not UI.portrait else col)


func _row(name: String, total: float, place: int) -> Control:
	var medals := {1: "1st", 2: "2nd", 3: "3rd", 4: "4th"}
	var row := UI.hbox(UI.sc(10, 8))
	if place > 0:
		row.add_child(UI.label(medals.get(place, str(place)), UI.sc(14, 12), Tokens.GOLD, "semibold"))
	var n := UI.label(name, UI.sc(14, 12), Tokens.TEXT_PRIMARY, "semibold")
	n.clip_text = true
	n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(UI.expand(n))
	row.add_child(UI.label("%.1f" % total, UI.sc(16, 14), Tokens.GOLD, "bold"))
	return UI.panel(UI.flat(Color("#0A2119"), UI.sc(11, 9), Tokens.HAIRLINE, 1,
			UI.pad_hv(UI.sc(14, 12), UI.sc(10, 7))), row)
