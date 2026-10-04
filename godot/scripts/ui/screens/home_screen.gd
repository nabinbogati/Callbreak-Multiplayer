class_name HomeScreen
extends Control

## The front door: the player's name (their way into the profile), settings,
## the hero card fan and wordmark, and the four ways to start a table.

const MODES := [
	{"mode": "bots", "accent": Color("#5B9BD5"), "letter": "v", "badge": "Solo",
		"subtitle": "Practice against AI opponents"},
	{"mode": "online", "accent": Color("#E85A4F"), "letter": "v", "badge": "Online",
		"subtitle": "Quickplay or a full match"},
	{"mode": "private", "accent": Color("#E8B84A"), "letter": "P", "badge": "Friends",
		"subtitle": "Invite-only room with a code"},
	{"mode": "lan", "accent": Color("#3DDC84"), "letter": "L", "badge": "Local",
		"subtitle": "Play on the same Wi‑Fi network"},
]

var _backdrop := Backdrop.new("background")
var _content: Control
var _built_portrait := -1
var _checked_rejoin := false


func _ready() -> void:
	add_child(_backdrop)
	App.instance.layout_changed.connect(_rebuild_if_needed)
	Settings.changed.connect(_rebuild)
	_rebuild()
	_offer_rejoin.call_deferred()


func on_shown() -> void:
	_rebuild()


func _rebuild_if_needed() -> void:
	if int(UI.portrait) != _built_portrait:
		_rebuild()
	elif _content != null:
		_apply_safe_area()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	_built_portrait = int(UI.portrait)
	if _content != null:
		_content.queue_free()
	_backdrop.glow_alignment_portrait = Vector2(-0.85, 0.0)
	_backdrop.glow_alignment_landscape = Vector2(-0.55, -0.1)
	_backdrop.queue_redraw()
	_content = _portrait() if UI.portrait else _landscape()
	add_child(_content)
	_apply_safe_area()


func _apply_safe_area() -> void:
	_content.set_anchors_preset(Control.PRESET_FULL_RECT)
	_content.offset_left = UI.safe.x
	_content.offset_top = UI.safe.y
	_content.offset_right = -UI.safe.z
	_content.offset_bottom = -UI.safe.w


func _portrait() -> Control:
	var list := UI.vbox(12, [UI.label("Choose how to play", 13, Tokens.TEXT_MUTED, "semibold")])
	for spec in MODES:
		list.add_child(_mode_row(spec))
	var col := UI.vbox(0, [
		UI.margin(_top_bar(), Vector4(20, 8, 20, 0)),
		UI.gap(12),
		_hero(false),
		UI.gap(16),
		UI.expand_v(UI.scroll(UI.margin(list, Vector4(20, 0, 20, 8)))),
		UI.margin(UI.label("Spades trump · Best of 5 hands", 11, Tokens.TEXT_FAINT, "medium",
				HORIZONTAL_ALIGNMENT_CENTER), Vector4(0, 0, 0, 10)),
	])
	return col


func _landscape() -> Control:
	var grid := UI.vbox(0, [UI.label("Choose how to play", 12, Tokens.TEXT_MUTED, "semibold"), UI.gap(10)])
	for r in 2:
		grid.add_child(UI.hbox(10, [UI.expand(_mode_tile(MODES[r * 2])), UI.expand(_mode_tile(MODES[r * 2 + 1]))]))
		if r == 0:
			grid.add_child(UI.gap(24))
	grid.alignment = BoxContainer.ALIGNMENT_CENTER
	var hero := UI.center(_hero(true))
	var row := UI.hbox(0, [UI.expand(hero, 40), UI.expand(UI.margin(grid, Vector4(8, 0, 28, 8)), 52)])
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return UI.vbox(0, [UI.margin(_top_bar(), Vector4(28, 6, 28, 0)), row])


func _top_bar() -> Control:
	var dot := Control.new()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.draw.connect(func(): dot.draw_circle(Vector2(5, 5), 5, Tokens.SUCCESS, true, -1.0, true))
	var name := UI.label(Settings.player_name, 14, Tokens.TEXT_ON_DARK, "semibold")
	var profile := UI.glass_pill(UI.hbox(7, [dot, name, UI.icon("chevron_right", 18, Tokens.TEXT_MUTED)]),
			func(): App.instance.push(ProfileScreen.new()), 22, Vector4(15, 10, 15, 10))
	var settings := UI.glass_pill(UI.icon("tune", 22, Tokens.TEXT_ON_DARK),
			func(): App.instance.push(SettingsScreen.new()), 22, UI.pad_all(11))
	return UI.hbox(0, [profile, UI.spacer(), settings])


func _hero(compact: bool) -> Control:
	var cw := 64.0 if compact else 72.0
	var fan := Control.new()
	fan.custom_minimum_size = Vector2(168 if compact else 184, 108 if compact else 122)
	fan.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var tilt := deg_to_rad(12.0 if compact else 14.0)
	var specs := [[0.0, 18.0, tilt], [52.0 if compact else 56.0, 8.0, 0.0], [96.0 if compact else 104.0, 0.0, -tilt]]
	for s in specs:
		var card := CardView.back(cw, true)
		card.position = Vector2(s[0], s[1])
		card.rotation = s[2]
		fan.add_child(card)
	var word := UI.gold_text("CALL BREAK", 36 if compact else 42)
	var fv := FontVariation.new()
	fv.base_font = Tokens.font("display")
	fv.spacing_glyph = int((36 if compact else 42) * 0.04)
	word.add_theme_font_override("font", fv)
	var tag_font := FontVariation.new()
	tag_font.base_font = Tokens.font("medium")
	tag_font.spacing_glyph = 1
	var tag := UI.label("Bid. Break. Win.", 14 if compact else 16, Tokens.TEXT_SUBTLE, "medium", HORIZONTAL_ALIGNMENT_CENTER)
	tag.add_theme_font_override("font", tag_font)
	return UI.vbox(0, [fan, UI.gap(10), word, UI.gap(4), tag])


func _surface(spec: Dictionary, inner: Control) -> Control:
	var accent: Color = spec["accent"]
	var card := UI.panel(UI.with_shadow(UI.flat(Color(0.0235, 0.102, 0.0784, 0.5), 14, Color(accent, 0.4), 1),
			Color(0, 0, 0, 0.35), 18, Vector2(0, 6)), inner)
	card.add_child(RunningGlow.new(accent, 14))
	return UI.pressable(card, func(): start_table(spec["mode"]))


func _mode_icon(spec: Dictionary, size: float, font_size: float, radius: float) -> Control:
	var accent: Color = spec["accent"]
	var box := UI.panel(UI.flat(Color(accent, 0.18), radius, Color(accent, 0.55), 1),
			UI.label(spec["letter"], font_size, accent, "bold", HORIZONTAL_ALIGNMENT_CENTER))
	(box.get_child(0) as Label).vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	box.custom_minimum_size = Vector2(size, size)
	box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return box


func _badge(spec: Dictionary, font_size: float) -> Control:
	var accent: Color = spec["accent"]
	var b := UI.panel(UI.flat(Color(accent, 0.2), 8, Color.TRANSPARENT, 0, UI.pad_hv(8, 3)),
			UI.label(spec["badge"], font_size, accent, "semibold"))
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return b


func _mode_row(spec: Dictionary) -> Control:
	var title := UI.label(GameSession.mode_label(spec["mode"]), 15, Tokens.TEXT_PRIMARY, "bold")
	var text := UI.vbox(3, [UI.hbox(8, [title, _badge(spec, 10)]),
			UI.label(spec["subtitle"], 12, Tokens.TEXT_MUTED, "medium")])
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	var chevron := UI.icon("chevron_right", 24, Tokens.TEXT_MUTED)
	chevron.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := UI.hbox(12, [_mode_icon(spec, 44, 18, 12), text, chevron])
	return _surface(spec, UI.margin(row, Vector4(16, 18, 16, 18)))


func _mode_tile(spec: Dictionary) -> Control:
	var title := UI.label(GameSession.mode_label(spec["mode"]), 14, Tokens.TEXT_PRIMARY, "bold")
	title.clip_text = true
	var head := UI.hbox(8, [_mode_icon(spec, 28, 13, 8), UI.expand(title), _badge(spec, 9)])
	var col := UI.vbox(6, [head, UI.label(spec["subtitle"], 11, Tokens.TEXT_MUTED, "medium")])
	(col.get_child(1) as Label).clip_text = true
	(col.get_child(1) as Label).text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return _surface(spec, UI.margin(col, UI.pad_all(16)))


# ----------------------------------------------------------------- routing

## Opens a table for [param mode]. Offline play starts once a match length is
## picked; networked modes first collect where to connect.
func start_table(mode: String) -> void:
	if mode == "lan":
		App.instance.sheet(LanSheet.new())
		return
	var details = await App.instance.sheet(JoinSheet.new(mode)).closed
	if details == null:
		return
	if mode == "bots":
		App.instance.push(TableScreen.new(Sessions.local(details["handsPerGame"])))
		return
	var session := Sessions.remote(details["serverUrl"], details["roomCode"], mode, details.get("handsPerGame", 0),
			details.get("creating", false))
	App.instance.push(TableScreen.new(session))


## A table found still marked active from before the app last closed — the
## process dying mid-game never got to tell the server goodbye, so the seat
## may still be waiting out its grace window.
func _offer_rejoin() -> void:
	if _checked_rejoin:
		return
	_checked_rejoin = true
	var active := Settings.identity.active_game()
	if active.is_empty():
		return
	var rejoin := await App.instance.confirm("Rejoin your game?",
			"You still have a seat held at table %s." % active["roomCode"], "Discard", "Rejoin")
	if not rejoin:
		Settings.identity.clear_active_game()
		return
	var session := Sessions.remote(active["serverUrl"], active["roomCode"], active.get("mode", "private"), 0, false,
			active["resumeToken"], active.get("playerName", Settings.player_name))
	App.instance.push(TableScreen.new(session))
