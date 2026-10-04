class_name QuickSettings
extends MarginContainer

## The compact settings sheet opened from the table's HUD: just the gameplay
## and sound toggles worth flipping mid-game. Tapping outside it or Back
## closes it.

signal finished(result)

var _col: VBoxContainer


func _init() -> void:
	for side in ["left", "right", "top"]:
		add_theme_constant_override("margin_" + side, 20)
	add_theme_constant_override("margin_bottom", int(20 + UI.safe.w))
	_col = UI.vbox(0)
	add_child(_col)
	_build()


func _build() -> void:
	UI.free_children(_col)
	var tune := UI.icon("tune", 18, Tokens.GOLD)
	tune.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var head := UI.hbox(8, [tune, UI.label("Settings", 18, Tokens.TEXT_PRIMARY, "bold")])
	head.alignment = BoxContainer.ALIGNMENT_CENTER
	_col.add_child(head)
	_col.add_child(UI.gap(18))
	_toggle("Drag to play", "drag_to_play")
	_toggle("Tap twice to play", "tap_twice_to_play")
	_toggle("Auto throw last card", "auto_throw_last_card")
	_toggle("Auto throw last suit card", "auto_throw_last_suit_card")
	# Sound sits a little apart from play.
	_toggle("Background music", "music_enabled", 18)
	_toggle("Sound effects", "sfx_enabled")
	_toggle("Vibration", "haptics_enabled")


func _toggle(text: String, key: String, gap_above := 14.0) -> void:
	if _col.get_child_count() > 2:
		_col.add_child(UI.gap(gap_above))
	_col.add_child(UI.setting_row(text, UI.choices([["On", true], ["Off", false]], Settings.get(key), func(v):
		Settings.set(key, v)
		_build()), 10))
