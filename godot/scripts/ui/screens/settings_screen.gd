class_name SettingsScreen
extends Control

## Settings as a full page: a back button, the tab pills and a scrolling pane —
## Profile (display name, table colour, card colour), Gameplay (bot
## difficulty, play conveniences, sound, vibration, animation speed) and, in
## debug builds only, Debug (server override, the "Go offline" tool). Being a
## full page it is always one size: switching tabs never resizes anything.

var _tab := "profile"
var _pane: VBoxContainer
var _content: Control


func _ready() -> void:
	var backdrop := Backdrop.new("background")
	backdrop.glow_alignment_portrait = Vector2(-0.7, 0.1)
	backdrop.glow_alignment_landscape = Vector2(-0.7, 0.1)
	add_child(backdrop)
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
	var back := UI.glass_pill(UI.icon("back", UI.sc(16, 19), Tokens.TEXT_ON_DARK), handle_back, UI.sc(16, 15),
			UI.pad_all(UI.sc(8, 9)))
	var title := UI.label("Settings", UI.sc(18, 16), Tokens.TEXT_PRIMARY, "bold")
	title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var head := UI.hbox(12, [back, title])
	# Tab pills stay pinned; only the active pane scrolls.
	var tabs := UI.hbox(8)
	for t in _tabs():
		var selected: bool = t[1] == _tab
		var pill := UI.glass_pill(UI.label(t[0], UI.sc(13, 11), Tokens.ON_GOLD if selected else Tokens.TEXT_ON_DARK,
				"semibold", HORIZONTAL_ALIGNMENT_CENTER), _select_tab.bind(t[1]), UI.sc(10, 8),
				UI.pad_hv(0, UI.sc(10, 6)), Tokens.GOLD if selected else Tokens.HAIRLINE,
				Tokens.GOLD if selected else Tokens.PANEL)
		tabs.add_child(UI.expand(pill))
	_pane = UI.vbox(0)
	match _tab:
		"profile": _profile_pane()
		"gameplay": _gameplay_pane()
		"debug": _debug_pane()
	_content = UI.vbox(0, [
		UI.margin(head, Vector4(16, 8, 16, 0)),
		UI.margin(tabs, Vector4(20, 14, 20, 0)),
		UI.gap(6),
		UI.expand_v(UI.scroll(UI.margin(_pane, Vector4(20, 16, 20, 20)))),
	])
	_content.set_anchors_preset(Control.PRESET_FULL_RECT)
	_content.offset_left = UI.safe.x
	_content.offset_top = UI.safe.y
	_content.offset_right = -UI.safe.z
	_content.offset_bottom = -UI.safe.w
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


func _label(text: String) -> Label:
	return UI.label(text, UI.sc(12, 10), Tokens.TEXT_MUTED, "semibold", HORIZONTAL_ALIGNMENT_CENTER)


func _field(text: String, placeholder: String) -> LineEdit:
	var e := UI.line_edit(text, placeholder, 14)
	e.alignment = HORIZONTAL_ALIGNMENT_CENTER
	return e


# ---------------------------------------------------------------- profile

func _profile_pane() -> void:
	_pane.add_child(_label("Display name"))
	_pane.add_child(UI.gap(8))
	var name := _field(Settings.player_name, "Your name")
	name.max_length = 20
	# Saved as typed, but announced (and the home screen rebuilt) only once
	# editing ends, not on every keystroke.
	name.text_changed.connect(_set_name_quietly)
	name.focus_exited.connect(func(): Settings.changed.emit())
	name.text_submitted.connect(func(_t): name.release_focus())
	_pane.add_child(name)
	_pane.add_child(UI.gap(18))

	_pane.add_child(_label("Table colour"))
	_pane.add_child(UI.gap(10))
	# Each swatch carries its trailing gap, as the design lays them out.
	var themes := UI.hbox(0)
	themes.alignment = BoxContainer.ALIGNMENT_CENTER
	for theme in Tokens.THEMES:
		themes.add_child(_theme_swatch(theme))
		themes.add_child(UI.gap(0, 12))
	_pane.add_child(themes)
	_pane.add_child(UI.gap(18))

	_pane.add_child(_label("Card colour"))
	_pane.add_child(UI.gap(10))
	var cards := UI.hbox(12)
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	for style in Tokens.CARD_STYLES:
		cards.add_child(_card_swatch(style))
	_pane.add_child(cards)
	_pane.add_child(UI.gap(16))
	_pane.add_child(_card_preview(52.0, ["AS", "KH"]))
	_pane.add_child(UI.gap(8))
	_pane.add_child(_label(Tokens.card_face(Settings.card_style)["label"]))


func _theme_swatch(theme: String) -> Control:
	var palette := Tokens.palette(theme)
	var selected := theme == Settings.theme
	var dot := Control.new()
	dot.custom_minimum_size = Vector2(44, 44)
	dot.draw.connect(func():
		var c := Vector2(22, 22)
		Draw.fill_linear(dot, Draw.ellipse_points(c, Vector2(22, 22), 64), Vector2.ZERO, Vector2(44, 44), palette["felt"])
		Draw.circle_border(dot, c, 22, Tokens.GOLD if selected else Tokens.HAIRLINE, 2.5 if selected else 1.0))
	return UI.pressable(dot, _pick.bind("theme", theme))


func _card_swatch(style: String) -> Control:
	var face := Tokens.card_face(style)
	var selected := style == Settings.card_style
	var tile := Control.new()
	tile.custom_minimum_size = Vector2(36, 46)
	tile.draw.connect(func():
		var r := Rect2(Vector2.ZERO, Vector2(36, 46))
		Draw.fill(tile, Draw.rounded_rect_points(r, 7, 8), face["face"])
		Draw.stroke_rounded_rect(tile, r, 7, Tokens.GOLD if selected else Tokens.HAIRLINE, 2.5 if selected else 1.0)
		SeatView.centered_text(tile, "A", r.get_center(), 14, "bold", face["red"]))
	return UI.pressable(tile, _pick.bind("card_style", style))


## A small fan in the current style, so a swatch shows the real paint — black
## ink, red ink and the trump edge — before leaving settings.
func _card_preview(width: float, cards: Array) -> Control:
	var overlap := width * 0.65
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(width + (cards.size() - 1) * overlap, width * CardView.FACE_ASPECT)
	holder.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mid := (cards.size() - 1) / 2.0
	for i in cards.size():
		var c := CardView.face(cards[i], width)
		c.position = Vector2((holder.custom_minimum_size.x - width) / 2.0 + (i - mid) * overlap, 0)
		c.rotation = (i - mid) * 0.09
		holder.add_child(c)
	return holder


# --------------------------------------------------------------- gameplay

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
	if _pane.get_child_count() > 0:
		_pane.add_child(UI.gap(14))
	_pane.add_child(UI.setting_row(text, UI.choices(options, Settings.get(key), func(v): _pick(key, v), 8)))


# ------------------------------------------------------------------ debug

func _debug_pane() -> void:
	_pane.add_child(_label("Developer"))
	_pane.add_child(UI.gap(8))
	var server := _field(Settings.server_url, "Override server (debug only)")
	server.text_changed.connect(func(t): Settings.server_url = t)
	server.text_submitted.connect(func(_t): server.release_focus())
	_pane.add_child(server)
	_pane.add_child(UI.gap(18))
	_pane.add_child(_label("Debug mode"))
	_pane.add_child(UI.gap(10))
	var chips := UI.choices([["On", true], ["Off", false]], Settings.debug_mode, func(v): _pick("debug_mode", v), 8)
	chips.alignment = BoxContainer.ALIGNMENT_CENTER
	_pane.add_child(chips)
	_pane.add_child(UI.gap(10))
	# Arming Debug mode puts a "Go offline" button on networked tables. It lives
	# on the table, not here — this page is never open while a table plays.
	_pane.add_child(UI.paragraph("Shows a \"Go offline\" button on networked tables.", 11, Tokens.TEXT_MUTED, "medium",
			HORIZONTAL_ALIGNMENT_CENTER))
