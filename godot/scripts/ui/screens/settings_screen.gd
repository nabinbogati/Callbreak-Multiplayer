class_name SettingsScreen
extends Control

## Settings as a full page: Profile (name, table theme, card style), Gameplay
## (bot difficulty, play conveniences, sound, animation speed) and — in debug
## builds only — Debug (server override, the "Go offline" tool).

var _tab := "profile"
var _pane: VBoxContainer
var _tabs_row: HBoxContainer
var _content: Control


func _ready() -> void:
	add_child(Backdrop.new("background"))
	App.instance.layout_changed.connect(_build)
	_build()


func handle_back() -> void:
	App.instance.pop()


func _tabs() -> Array:
	var out := [["Profile", "profile"], ["Gameplay", "gameplay"]]
	if OS.is_debug_build():
		out.append(["Debug", "debug"])
	return out


func _build() -> void:
	if _content != null:
		_content.queue_free()
	var back := UI.glass_pill(UI.icon("back", 20, Tokens.TEXT_ON_DARK), handle_back, 18, UI.pad_all(9))
	var head := UI.hbox(12, [back, UI.label("Settings", 20, Tokens.TEXT_PRIMARY, "bold")])
	_tabs_row = UI.hbox(8)
	for t in _tabs():
		var selected: bool = t[1] == _tab
		_tabs_row.add_child(UI.pressable(UI.panel(UI.flat(Color(Tokens.GOLD, 0.16) if selected else Tokens.PANEL, 12,
				Tokens.GOLD_BORDER if selected else Tokens.HAIRLINE, 1, UI.pad_hv(16, 9)),
				UI.label(t[0], 13, Tokens.GOLD if selected else Tokens.TEXT_ON_DARK, "semibold")),
				_select_tab.bind(t[1]), 0.94))
	_pane = UI.vbox(UI.sc(16, 12))
	match _tab:
		"profile": _profile_pane()
		"gameplay": _gameplay_pane()
		"debug": _debug_pane()
	var col := UI.vbox(0, [head, UI.gap(16), _tabs_row, UI.gap(18), UI.expand_v(UI.scroll(_pane))])
	var width := minf(size.x, 560.0) if not UI.portrait else size.x
	_content = UI.margin(col, Vector4(20 + UI.safe.x, 10 + UI.safe.y, 20 + UI.safe.z, 10 + UI.safe.w))
	_content.set_anchors_preset(Control.PRESET_FULL_RECT)
	if not UI.portrait and size.x > width:
		_content.offset_left = (size.x - width) / 2.0
		_content.offset_right = -(size.x - width) / 2.0
	add_child(_content)


func _select_tab(tab: String) -> void:
	_tab = tab
	_build()


func _pick(key: String, value) -> void:
	Settings.set(key, value)
	_build()


func _set_name_quietly(text: String) -> void:
	Settings.set_block_signals(true)
	Settings.player_name = text
	Settings.set_block_signals(false)


func _section(text: String) -> Label:
	return UI.label(text, 12, Tokens.TEXT_MUTED, "semibold")


func _profile_pane() -> void:
	_pane.add_child(_section("Your name"))
	var name := UI.line_edit(Settings.player_name, "Your name", 15)
	name.max_length = 20
	# Saved as typed, but announced (and the home screen rebuilt) only once
	# editing ends, not on every keystroke.
	name.text_changed.connect(_set_name_quietly)
	name.focus_exited.connect(func(): Settings.changed.emit())
	name.text_submitted.connect(func(_t): name.release_focus())
	_pane.add_child(name)

	_pane.add_child(_section("Table theme"))
	var themes := UI.hbox(10)
	for theme in Tokens.THEMES:
		themes.add_child(_theme_swatch(theme))
	_pane.add_child(themes)
	_pane.add_child(UI.label(Tokens.palette(Settings.theme)["label"], 12, Tokens.TEXT_ON_DARK, "semibold"))

	_pane.add_child(_section("Card style"))
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 10)
	flow.add_theme_constant_override("v_separation", 10)
	for style in Tokens.CARD_STYLES:
		flow.add_child(_card_swatch(style))
	_pane.add_child(flow)
	_pane.add_child(UI.label(Tokens.card_face(Settings.card_style)["label"], 12, Tokens.TEXT_ON_DARK, "semibold"))
	_pane.add_child(_card_preview())


func _theme_swatch(theme: String) -> Control:
	var palette := Tokens.palette(theme)
	var selected := theme == Settings.theme
	var dot := Control.new()
	dot.custom_minimum_size = Vector2(46, 46)
	dot.draw.connect(func():
		var r := Rect2(Vector2(3, 3), Vector2(40, 40))
		Draw.rounded_rect(dot, r, 20, palette["felt"], true)
		if selected:
			dot.draw_arc(Vector2(23, 23), 22, 0, TAU, 40, Tokens.GOLD, 2.0, true))
	return UI.pressable(dot, _pick.bind("theme", theme), 0.9)


func _card_swatch(style: String) -> Control:
	var face := Tokens.card_face(style)
	var selected := style == Settings.card_style
	var tile := Control.new()
	tile.custom_minimum_size = Vector2(40, 54)
	tile.draw.connect(func():
		var r := Rect2(Vector2(2, 2), Vector2(36, 50))
		Draw.rounded_rect(tile, r, 6, [face["face"]], true, Tokens.GOLD if selected else face["edge"],
				2.0 if selected else 1.0)
		var font := Tokens.font("bold")
		tile.draw_string(font, Vector2(8, 22), "A", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, face["red"])
		Draw.suit(tile, Cards.Suit.HEARTS, Vector2(13, 33), 10, face["red"]))
	return UI.pressable(tile, _pick.bind("card_style", style), 0.9)


## A small fan in the current style, so a swatch shows the real paint — black
## ink, red ink and the trump edge — before leaving settings.
func _card_preview() -> Control:
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(0, 92)
	var cards := ["AS", "KH", "QD", "10C"]
	for i in cards.size():
		var c := CardView.face(cards[i], 50)
		c.position = Vector2(8 + i * 36, 8 + absf(i - 1.5) * 3)
		c.rotation = deg_to_rad((i - 1.5) * 5)
		holder.add_child(c)
	return holder


func _gameplay_pane() -> void:
	_row("Bot difficulty", [["Easy", "easy"], ["Normal", "normal"], ["Hard", "hard"]], "difficulty")
	_row("Drag to play", [["On", true], ["Off", false]], "drag_to_play")
	_row("Tap twice to play", [["On", true], ["Off", false]], "tap_twice_to_play")
	_row("Auto throw last card", [["On", true], ["Off", false]], "auto_throw_last_card")
	_row("Auto throw last suit card", [["On", true], ["Off", false]], "auto_throw_last_suit_card")
	_row("Background music", [["On", true], ["Off", false]], "music_enabled")
	_row("Sound effects", [["On", true], ["Off", false]], "sfx_enabled")
	_row("Vibration", [["On", true], ["Off", false]], "haptics_enabled")
	_row("Animation speed", [["Slow", "slow"], ["Normal", "normal"], ["Fast", "fast"]], "animation_speed")


func _row(text: String, options: Array, key: String) -> void:
	_pane.add_child(UI.setting_row(text, UI.choices(options, Settings.get(key), func(v):
		Settings.set(key, v)
		_build())))


func _debug_pane() -> void:
	_pane.add_child(_section("Game server"))
	var server := UI.line_edit(Settings.server_url, Settings.DEFAULT_SERVER_URL, 14)
	server.text_changed.connect(func(t): Settings.server_url = t)
	server.text_submitted.connect(func(_t): server.release_focus())
	_pane.add_child(server)
	_pane.add_child(UI.paragraph("Overrides %s for this debug build. Leave empty to use the default. REST and the socket follow it together." %
			Settings.DEFAULT_SERVER_URL, 11, Tokens.TEXT_FAINT))
	_row("Debug mode", [["On", true], ["Off", false]], "debug_mode")
	_pane.add_child(UI.paragraph("Arms the \"Go offline\" button on networked tables, to exercise reconnection on demand.",
			11, Tokens.TEXT_FAINT))
	_pane.add_child(UI.paragraph("Device id: " + Settings.identity.device_id, 11, Tokens.TEXT_FAINT))
