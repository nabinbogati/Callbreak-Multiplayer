class_name ConfirmDialog
extends Control

## A centred two-choice card ("Quit game?", "Rejoin your game?"). Emits
## [signal closed] with true for the primary (gold) choice. Back dismisses it
## as the secondary choice.

signal closed(result: bool)

var _done := false


func _init(title: String, message: String, cancel_label: String, ok_label: String) -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.35)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scrim)
	var cancel := UI.pressable(UI.panel(UI.flat(Tokens.PANEL, 14, Tokens.HAIRLINE_STRONG, 1, UI.pad_hv(0, 13)),
			UI.label(cancel_label, 13, Tokens.TEXT_ON_DARK, "semibold", HORIZONTAL_ALIGNMENT_CENTER)), func(): _finish(false))
	var ok := UI.pressable(UI.panel(UI.gold(14, UI.pad_hv(0, 13)),
			UI.label(ok_label, 13, Tokens.ON_GOLD, "bold", HORIZONTAL_ALIGNMENT_CENTER)), func(): _finish(true))
	var col := UI.vbox(0, [
		UI.label(title, 16, Tokens.TEXT_PRIMARY, "bold", HORIZONTAL_ALIGNMENT_CENTER),
		UI.gap(8),
		UI.paragraph(message, 13, Tokens.TEXT_MUTED, "medium", HORIZONTAL_ALIGNMENT_CENTER),
		UI.gap(20),
		UI.hbox(12, [UI.expand(cancel), UI.expand(ok)]),
	])
	var card := UI.panel(UI.with_shadow(UI.flat(Tokens.DIALOG, 18, Color(Tokens.GOLD_BORDER, 0.35), 1, UI.pad_all(20)),
			Color(0, 0, 0, 0.6), 30, Vector2(0, 12)), col)
	card.custom_minimum_size.x = 300
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.add_child(card)
	add_child(center)


func _finish(result: bool) -> void:
	if _done:
		return
	_done = true
	closed.emit(result)


func dismiss() -> void:
	_finish(false)
