class_name QuickSettings
extends MarginContainer

## The compact settings sheet opened from the table's HUD: just the gameplay
## and sound toggles worth flipping mid-game.

signal finished(result)

var _col: VBoxContainer


func _init() -> void:
	add_theme_constant_override("margin_left", 22)
	add_theme_constant_override("margin_right", 22)
	add_theme_constant_override("margin_top", int(UI.sc(20, 14)))
	add_theme_constant_override("margin_bottom", int(UI.sc(22, 14) + UI.safe.w))
	_col = UI.vbox(UI.sc(14, 9))
	add_child(_col)
	_build()


func _build() -> void:
	UI.free_children(_col)
	var close := UI.pressable(UI.margin(UI.icon("close", 18, Tokens.TEXT_MUTED), UI.pad_all(4)),
			func(): finished.emit(null), 0.9)
	_col.add_child(UI.hbox(0, [UI.expand(UI.label("Settings", 18, Tokens.TEXT_PRIMARY, "bold")), close]))
	_toggle("Drag to play", "drag_to_play")
	_toggle("Auto throw last card", "auto_throw_last_card")
	_toggle("Auto throw last suit card", "auto_throw_last_suit_card")
	_toggle("Background music", "music_enabled")
	_toggle("Sound effects", "sfx_enabled")


func _toggle(text: String, key: String) -> void:
	_col.add_child(UI.setting_row(text, UI.choices([["On", true], ["Off", false]], Settings.get(key), func(v):
		Settings.set(key, v)
		_build())))
