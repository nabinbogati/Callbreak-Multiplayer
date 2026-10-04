class_name ConfirmDialog
extends Control

## A centred two-choice card in the app's glass chrome ("Quit game?", "Rejoin
## your game?"). Emits [signal closed] with true for the primary (gold) choice.
## Back dismisses it as the secondary choice.

signal closed(result: bool)

var _done := false


func _init(title: String, message: String, cancel_label: String, ok_label: String, icon := "",
		scrim := Color("#0000008C")) -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = scrim
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var col := UI.vbox(0)
	if not icon.is_empty():
		var badge := Control.new()
		badge.custom_minimum_size = Vector2(48, 48)
		badge.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		badge.draw.connect(func():
			Draw.disc(badge, Vector2(24, 24), 24, Color(Tokens.GOLD, 0.12))
			Draw.circle_border(badge, Vector2(24, 24), 24, Color(Tokens.GOLD_BORDER, 0.5), 1)
			Draw.icon(badge, icon, Rect2(13, 13, 22, 22), Tokens.GOLD))
		col.add_child(badge)
		col.add_child(UI.gap(14))
	col.add_child(UI.label(title, 18, Tokens.TEXT_PRIMARY, "bold", HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.gap(8))
	col.add_child(UI.paragraph(message, 13, Tokens.TEXT_MUTED, "medium", HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(UI.gap(22))
	col.add_child(UI.hbox(12, [UI.expand(UI.ghost_button(cancel_label, func(): _finish(false), "", true)),
			UI.expand(UI.gold_button(ok_label, func(): _finish(true), "", true))]))
	var card := UI.glass_panel(col, Vector4(22, 22, 22, 20))
	card.custom_minimum_size.x = 320
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.add_child(card)
	add_child(center)
	card.ready.connect(func(): UI.pop_in(card))


func _ready() -> void:
	# Never wider than the screen allows, with the design's 32px inset.
	var fit := func():
		var card: Control = get_child(1).get_child(0)
		card.custom_minimum_size.x = minf(320, size.x - 64)
	resized.connect(fit)
	fit.call()


func _finish(result: bool) -> void:
	if _done:
		return
	_done = true
	closed.emit(result)


func dismiss() -> void:
	_finish(false)
