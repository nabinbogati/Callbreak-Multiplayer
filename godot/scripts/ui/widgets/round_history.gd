class_name RoundHistory
extends RefCounted

## The round-by-round scorecard: every finished hand's score per seat, the hand
## in progress (bids and tricks so far), and the running totals. Shared by the
## in-game overlay (opened from the HUD's round pill) and the winner screen.


## The table itself, without chrome. The viewer's column is tinted.
static func table(view: GameView) -> Control:
	var rounds: int = view.round_scores[0].size() if not view.round_scores.is_empty() else 0
	var live := view.phase == GameView.BIDDING or view.phase == GameView.PLAYING
	if rounds == 0 and not live:
		return UI.margin(UI.paragraph("No rounds completed yet — check back after round 1.", 13, Tokens.TEXT_FAINT,
				"medium", HORIZONTAL_ALIGNMENT_CENTER), Vector4(0, 28, 0, 28))

	var col := UI.vbox(0)
	var header := ["Rnd"]
	for seat in 4:
		header.append(view.player(seat).get("name", ""))
	col.add_child(_row(header, func(i):
		return [11, Tokens.GOLD if i > 0 and i - 1 == view.you else Tokens.TEXT_FAINT, "semibold"]))
	col.add_child(UI.gap(6))
	col.add_child(_rule())

	var body := UI.vbox(0)
	for r in rounds:
		body.add_child(UI.gap(8))
		var cells := [str(r + 1)]
		for seat in 4:
			cells.append("%.1f" % view.round_scores[seat][r])
		body.add_child(_row(cells, func(i):
			if i == 0:
				return [12, Tokens.TEXT_MUTED, "medium"]
			var d: float = view.round_scores[i - 1][r]
			return [12, Tokens.DANGER if d < 0 else (Tokens.GOLD if d > 0 else Tokens.TEXT_MUTED), "semibold"]))
	if live:
		body.add_child(UI.gap(8))
		body.add_child(_live_row(view))
	var scroller := UI.scroll(body)
	scroller.custom_minimum_size.y = 40
	col.add_child(scroller)

	col.add_child(UI.gap(8))
	col.add_child(_rule())
	col.add_child(UI.gap(8))
	var totals := ["Total"]
	for seat in 4:
		totals.append("%.1f" % view.totals[seat])
	col.add_child(_row(totals, func(i): return [12, Tokens.TEXT_PRIMARY, "bold"] if i == 0 else [13, Tokens.GOLD, "bold"]))
	return _with_you_column(col, view.you)


## The hand being bid or played, beneath the finished rows: bids and tricks so
## far, in a gold-tinted row since it is not a result yet.
static func _live_row(view: GameView) -> Control:
	var cells := [""]
	for seat in 4:
		var bid: int = view.bids[seat]
		cells.append("%s / %d" % [str(bid) if bid >= 0 else "–", view.tricks_won[seat]])
	var title := UI.hbox(6, [_dot(), UI.label("Round %d — live" % view.hand_number(), 11, Tokens.GOLD, "bold")])
	var col := UI.vbox(6, [title, _row(cells, func(i):
		return [12, Tokens.TEXT_MUTED, "medium"] if i == 0 else [12, Tokens.TEXT_ON_DARK, "semibold"])])
	return UI.panel(UI.flat(Color(Tokens.GOLD, 0.05), 8, Color(Tokens.GOLD, 0.3), 1, UI.pad_all(8)), col)


static func _dot() -> Control:
	var d := Control.new()
	d.custom_minimum_size = Vector2(6, 6)
	d.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	d.draw.connect(func(): d.draw_circle(Vector2(3, 3), 3, Tokens.GOLD, true, -1.0, true))
	return d


static func _rule() -> Control:
	var r := ColorRect.new()
	r.color = Tokens.HAIRLINE
	r.custom_minimum_size.y = 1
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## One grid row: a 2-flex lead column and four 3-flex seat columns.
## [param style_for] returns `[size, color, weight]` for a cell index.
static func _row(cells: Array, style_for: Callable) -> HBoxContainer:
	var row := UI.hbox(0)
	for i in cells.size():
		var s: Array = style_for.call(i)
		var l := UI.label(str(cells[i]), s[0], s[1], s[2],
				HORIZONTAL_ALIGNMENT_LEFT if i == 0 else HORIZONTAL_ALIGNMENT_CENTER)
		l.clip_text = true
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.custom_minimum_size.x = 1
		row.add_child(UI.expand(l, 2.0 if i == 0 else 3.0))
	return row


## A continuous band behind the viewer's column, so it reads as a real column.
## A MarginContainer stacks the band under the grid and takes its size from
## the grid, so a caller can still give the whole table a minimum height.
static func _with_you_column(content: Control, you: int) -> Control:
	if you < 0:
		return content
	var holder := MarginContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var band := Control.new()
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.draw.connect(func():
		var total := 2.0 + 3.0 * 4
		var left := (2.0 + 3.0 * you) / total * band.size.x
		var right := (2.0 + 3.0 * (you + 1)) / total * band.size.x
		band.draw_style_box(UI.flat(Color(Tokens.GOLD, 0.08), 6), Rect2(left, -4, right - left, band.size.y + 8)))
	band.resized.connect(band.queue_redraw)
	holder.add_child(band)
	holder.add_child(content)
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return holder


## The in-game overlay: a dismissable scrim over a scorecard card. It never
## blocks the game — tap the scrim or ✕ and play continues.
static func overlay(view: GameView, on_close: Callable) -> Control:
	var scrim := ColorRect.new()
	scrim.color = Tokens.SCRIM
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			on_close.call())
	var close := UI.pressable(UI.margin(UI.label("✕", 15, Tokens.TEXT_MUTED, "semibold"), UI.pad_all(4)), on_close, 0.9)
	var title := UI.label("Round history", 17, Tokens.TEXT_PRIMARY, "bold")
	var head := UI.hbox(0, [UI.expand(title), close])
	var col := UI.vbox(4, [head, UI.expand_v(table(view))])
	var card := UI.panel(UI.with_shadow(UI.flat(Tokens.DIALOG, 18, Color(Tokens.GOLD_BORDER, 0.35), 1,
			Vector4(20, 18, 20, 18)), Color(0, 0, 0, 0.6), 30, Vector2(0, 12)), col)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	var frame := UI.margin(card, UI.pad_all(20))
	scrim.add_child(frame)
	scrim.resized.connect(func():
		var w := minf(420.0, scrim.size.x)
		var h := minf(520.0, scrim.size.y)
		frame.size = Vector2(w, h)
		frame.position = (scrim.size - frame.size) / 2.0)
	return scrim
