class_name WinnerScreen
extends Control

## The final-game screen: a podium (1st tallest and centre-most, 2nd and 3rd
## flanking, 4th apart and lowest), the full round history, and the next
## move — another game, or home.

signal play_again
signal go_home

const VISUAL_ORDER := [1, 0, 2, 3]
const PEDESTAL_HEIGHTS := [96.0, 66.0, 52.0, 40.0]
const AVATAR_SIZES := [82.0, 68.0, 64.0, 58.0]
const STAGGER := [0.15, 0.0, 0.25, 0.35]
const PLACE_LABEL := {1: "1st", 2: "2nd", 3: "3rd", 4: "4th"}
const PEDESTALS := {
	1: [Color("#F5D78A"), Color("#C9922A")],
	2: [Color("#DCE3EA"), Color("#97A3B0")],
	3: [Color("#D8996A"), Color("#8C5A34")],
	4: [Color("#3B4A44"), Color("#1D2622")],
}


func _init(view: GameView) -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var bg := ColorRect.new()
	bg.color = Color(0.0157, 0.0706, 0.051, 0.94)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var ranked := view.rankings.duplicate()
	ranked.sort_custom(func(a, b): return a["place"] < b["place"])
	var col := UI.vbox(0)
	col.add_child(UI.gold_text("Game over", UI.sc(24, 20)))
	col.add_child(UI.gap(UI.sc(4, 2)))
	if not ranked.is_empty():
		col.add_child(UI.label("%s wins" % view.player(ranked[0]["seat"]).get("name", ""), UI.sc(13, 11),
				Tokens.TEXT_FAINT, "medium", HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.gap(UI.sc(26, 14)))
	if ranked.size() == 4:
		col.add_child(_podium(view, ranked))
	col.add_child(UI.gap(UI.sc(26, 16)))

	var history := UI.vbox(8, [UI.label("Round history", 15, Tokens.TEXT_PRIMARY, "bold")])
	var table := RoundHistory.table(view)
	table.custom_minimum_size.y = UI.sc(220, 160)
	history.add_child(table)
	col.add_child(UI.panel(UI.flat(Tokens.DIALOG, 16, Color(Tokens.GOLD_BORDER, 0.3), 1, Vector4(18, 14, 18, 16)), history))
	col.add_child(UI.gap(UI.sc(22, 14)))

	var home := UI.pressable(UI.panel(UI.flat(Color.TRANSPARENT, UI.sc(14, 12), Color(Tokens.TEXT_MUTED, 0.4), 1,
			UI.pad_hv(0, UI.sc(14, 10))), UI.label("Home", UI.sc(14, 13), Tokens.TEXT_MUTED, "bold",
			HORIZONTAL_ALIGNMENT_CENTER)), func(): go_home.emit())
	var again := UI.button("Play again", true, func(): play_again.emit(), UI.sc(14, 13), UI.pad_hv(0, UI.sc(14, 10)))
	col.add_child(UI.hbox(12, [UI.expand(home), UI.expand(again)]))

	var scroller := UI.scroll(UI.margin(col, Vector4(20, UI.sc(24, 14), 20, 20)))
	scroller.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scroller)

	# Fade and rise in.
	modulate.a = 0.0
	var t := create_tween()
	t.tween_property(self, "modulate:a", 1.0, 0.35)


func _podium(view: GameView, ranked: Array) -> Control:
	var row := UI.hbox(UI.sc(8, 6))
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	for rank_index in VISUAL_ORDER:
		var r: Dictionary = ranked[rank_index]
		var column := _column(view, r, rank_index)
		column.size_flags_vertical = Control.SIZE_SHRINK_END
		row.add_child(column)
		# Each column rises in on its own beat.
		column.modulate.a = 0.0
		var t := column.create_tween()
		t.tween_interval(STAGGER[rank_index] * 0.7)
		t.tween_property(column, "modulate:a", 1.0, 0.42).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	return row


func _column(view: GameView, r: Dictionary, rank_index: int) -> Control:
	var seat: int = r["seat"]
	var place: int = r["place"]
	var player := view.player(seat)
	var is_you := seat == view.you
	var avatar_size: float = AVATAR_SIZES[rank_index] * (1.0 if UI.portrait else 0.75)
	var pedestal_h: float = PEDESTAL_HEIGHTS[rank_index] * (1.0 if UI.portrait else 0.7)

	var avatar := Control.new()
	avatar.custom_minimum_size = Vector2(avatar_size, avatar_size) + Vector2(8, 8)
	avatar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	avatar.draw.connect(func():
		var c := avatar.size / 2.0
		if place == 1:
			var t := (sin(Time.get_ticks_msec() / 1900.0 * TAU) + 1.0) / 2.0
			for i in 4:
				avatar.draw_circle(c, avatar_size / 2.0 + 2.0 + i * (2.0 + 2.0 * t),
						Color(Tokens.GOLD, (0.16 + 0.14 * t) * (1.0 - i / 4.0)), true, -1.0, true)
		var rect := Rect2(c - Vector2.ONE * avatar_size / 2.0, Vector2.ONE * avatar_size)
		Draw.shadow(avatar, rect, avatar_size / 2.0, Vector2(0, 3), 10, Color(0, 0, 0, 0.45))
		Draw.rounded_rect(avatar, rect, avatar_size / 2.0,
				[Tokens.GOLD, Tokens.GOLD_DEEP] if is_you else Settings.palette()["avatar"], true,
				Color(Tokens.GOLD_LIGHT, 0.9) if is_you else Color(Tokens.TEXT_MUTED, 0.3), 2.0 if is_you else 1.5)
		if GameView.is_bot(player):
			Draw.icon(avatar, "robot", Rect2(c - Vector2.ONE * avatar_size * 0.21, Vector2.ONE * avatar_size * 0.42),
					Tokens.TEXT_ON_DARK)
		else:
			var font := Tokens.font("bold")
			var fs := int(avatar_size * 0.37)
			var initial := GameView.initial(player.get("name", ""))
			var tw := font.get_string_size(initial, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			avatar.draw_string(font, c + Vector2(-tw / 2.0, fs * 0.36), initial, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
					Tokens.ON_GOLD if is_you else Tokens.TEXT_ON_DARK))
	if place == 1:
		var pulse := Timer.new()
		pulse.wait_time = 1.0 / 30.0
		pulse.autostart = true
		pulse.timeout.connect(avatar.queue_redraw)
		avatar.add_child(pulse)

	var name := UI.label(player.get("name", ""), UI.sc(12, 11), Tokens.TEXT_PRIMARY, "semibold",
			HORIZONTAL_ALIGNMENT_CENTER)
	name.clip_text = true
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name.custom_minimum_size.x = 64
	var score := UI.label("%.1f" % r["total"], UI.sc(12, 11), Tokens.GOLD, "bold", HORIZONTAL_ALIGNMENT_CENTER)

	var pedestal := UI.panel(GradientBox.new(PEDESTALS.get(place, PEDESTALS[4]), 8, true),
			UI.label(PLACE_LABEL.get(place, str(place)), UI.sc(14, 12),
			Tokens.ON_GOLD if place <= 2 else Tokens.TEXT_ON_DARK, "bold", HORIZONTAL_ALIGNMENT_CENTER))
	pedestal.custom_minimum_size = Vector2(64, pedestal_h)
	(pedestal.get_child(0) as Label).vertical_alignment = VERTICAL_ALIGNMENT_TOP
	pedestal.get_theme_stylebox("panel").content_margin_top = UI.sc(8, 6)
	pedestal.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	return UI.vbox(0, [avatar, UI.gap(UI.sc(8, 5)), name, UI.gap(UI.sc(2, 1)), score, UI.gap(UI.sc(8, 5)), pedestal])
