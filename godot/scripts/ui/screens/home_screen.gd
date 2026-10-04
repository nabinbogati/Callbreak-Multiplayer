class_name HomeScreen
extends Control

## The front door: the player's name (their way into the profile), settings,
## the hero card fan and wordmark, and the ways to start a table — solo
## against bots as the featured card (it works with no connection at all),
## the other three as icon tiles beside each other.

const MODES := [
	{"mode": "bots", "accent": Color("#5B9BD5"), "icon": "smart_toy_rounded", "badge": "Solo",
		"subtitle": "Practice against AI opponents"},
	{"mode": "online", "accent": Color("#E85A4F"), "icon": "public_rounded", "badge": "Online",
		"subtitle": "Quickplay or a full match"},
	{"mode": "private", "accent": Color("#E8B84A"), "icon": "group_rounded", "badge": "Friends",
		"subtitle": "Invite-only room with a code"},
	{"mode": "lan", "accent": Color("#3DDC84"), "icon": "wifi_rounded", "badge": "Local",
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
	_backdrop.glow_alignment_portrait = Vector2(0, -0.55)
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
	var list := UI.vbox(0, [
		_hero(false),
		UI.gap(26),
		_section_label("Choose how to play"),
		UI.gap(12),
		_staggered(0, _featured(MODES[0], false)),
		UI.gap(12),
		_tiles(false),
		UI.gap(16),
	])
	list.alignment = BoxContainer.ALIGNMENT_CENTER
	# Centred in whatever height the phone has, scrolling only if it genuinely
	# runs out.
	var padded := UI.margin(list, Vector4(20, 4, 20, 8))
	var scroller := UI.scroll(padded)
	scroller.resized.connect(func(): padded.custom_minimum_size.y = scroller.size.y - 12)
	return UI.vbox(0, [
		UI.margin(_top_bar(), Vector4(20, 8, 20, 0)),
		scroller,
		_footer(),
	])


func _landscape() -> Control:
	var col := UI.vbox(0, [
		_section_label("Choose how to play"),
		UI.gap(8),
		_staggered(0, _featured(MODES[0], true)),
		UI.gap(10),
		_tiles(true),
	])
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	var right := UI.margin(col, Vector4(8, 0, 28, 6))
	var scroller := UI.scroll(right)
	scroller.resized.connect(func(): right.custom_minimum_size.y = scroller.size.y)
	var row := UI.hbox(0, [UI.expand(UI.center(_hero(true)), 40), UI.expand(scroller, 56)])
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return UI.vbox(0, [UI.margin(_top_bar(), Vector4(28, 6, 28, 0)), row])


# ------------------------------------------------------------- components

func _section_label(text: String) -> Control:
	var bar := Control.new()
	bar.custom_minimum_size = Vector2(3, 14)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.draw.connect(func(): Draw.rounded_rect(bar, Rect2(Vector2.ZERO, bar.size), 2, Tokens.GOLD_BUTTON, true,
			Color.TRANSPARENT, 0, Tokens.GOLD_BUTTON_STOPS))
	return UI.hbox(8, [bar, UI.label(text, 13, Tokens.TEXT_SUBTLE, "semibold")])


func _footer() -> Control:
	var row := UI.hbox(6, [UI.suit_glyph(Cards.Suit.SPADES, 11, Tokens.TEXT_FAINT),
			UI.label("Spades are trump · 3 or 5 hands", 11, Tokens.TEXT_FAINT, "medium")])
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	return UI.margin(row, Vector4(0, 4, 0, 10))


func _top_bar() -> Control:
	var name := Settings.player_name.strip_edges()
	var initial := "?" if name.is_empty() else name.substr(0, 1).to_upper()
	var avatar := Control.new()
	avatar.custom_minimum_size = Vector2(32, 32)
	avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	avatar.draw.connect(func():
		Draw.rounded_rect(avatar, Rect2(0, 0, 32, 32), 16, Tokens.GOLD_BUTTON, true, Color.TRANSPARENT, 0,
				Tokens.GOLD_BUTTON_STOPS)
		var font := Tokens.font("bold")
		var tw := font.get_string_size(initial, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		avatar.draw_string(font, Vector2(16 - tw / 2.0, 16 + 14 * 0.36), initial, HORIZONTAL_ALIGNMENT_LEFT, -1, 14,
				Tokens.ON_GOLD)
		# The presence lamp, ringed in the backdrop's own colour.
		Draw.disc(avatar, Vector2(28, 28), 5, Color("#061A14"))
		Draw.disc(avatar, Vector2(28, 28), 3, Tokens.SUCCESS))
	var chevron := UI.icon("chevron_right", 18, Tokens.TEXT_MUTED)
	chevron.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var row := UI.hbox(0, [avatar, UI.gap(0, 9), UI.label(Settings.player_name, 14, Tokens.TEXT_ON_DARK, "semibold"),
			UI.gap(0, 4), chevron])
	row.get_child(2).size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# The player's own name is the natural door to their profile.
	var profile := UI.glass_pill(row, func(): App.instance.push(ProfileScreen.new()), 24, Vector4(5, 5, 12, 5))
	var settings := UI.glass_pill(UI.icon("tune", 20, Tokens.TEXT_ON_DARK),
			func(): App.instance.push(SettingsScreen.new()), 22, UI.pad_all(11))
	return UI.hbox(0, [profile, UI.spacer(), settings])


func _hero(compact: bool) -> Control:
	var hero := HeroFan.new(62.0 if compact else 78.0, 190.0 if compact else 230.0, 26.0 if compact else 30.0,
			14.0 if compact else 16.0)
	hero.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var size := 36.0 if compact else 46.0
	var word := UI.gold_text("CALL BREAK", size)
	var fv := FontVariation.new()
	fv.base_font = Tokens.font("display")
	fv.spacing_glyph = int(round(size * 0.04))
	word.add_theme_font_override("font", fv)
	var tag_font := FontVariation.new()
	tag_font.base_font = Tokens.font("medium")
	tag_font.spacing_glyph = int(round(1.4 if compact else 2.0))
	var tag := UI.label("Bid. Break. Win.", 14 if compact else 15, Tokens.TEXT_SUBTLE, "medium",
			HORIZONTAL_ALIGNMENT_CENTER)
	tag.add_theme_font_override("font", tag_font)
	return UI.vbox(0, [hero, UI.gap(8), _shadowed(word, fv, size), UI.gap(2), tag])


## The wordmark lifted off the felt by a soft dark shadow beneath it.
func _shadowed(word: Label, font: Font, size: float) -> Control:
	var shadow := UI.label(word.text, size, Color(0, 0, 0, 0.32), "display", HORIZONTAL_ALIGNMENT_CENTER)
	shadow.add_theme_font_override("font", font)
	shadow.add_theme_constant_override("outline_size", 10)
	shadow.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.14))
	shadow.set_anchors_preset(Control.PRESET_FULL_RECT)
	shadow.offset_top = 4
	shadow.offset_bottom = 4
	shadow.show_behind_parent = true
	word.add_child(shadow)
	return word


## A one-shot rise-and-fade, staggered by [param index], for the mode cards.
func _staggered(index: int, node: Control) -> Control:
	return UI.rise_in(node, (420 + index * 90) / 1000.0, 16, index, 0.25)


func _mode_icon(spec: Dictionary, size: float) -> Control:
	var accent: Color = spec["accent"]
	var c := Control.new()
	c.custom_minimum_size = Vector2(size, size)
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	c.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(func():
		var mid := Vector2(size, size) / 2.0
		Draw.fill_radial(c, Draw.ellipse_points(mid, mid, 48), mid, size / 2.0, [Color(accent, 0.42), Color(accent, 0.16)])
		Draw.circle_border(c, mid, size / 2.0, Color(accent, 0.7), 1.0)
		Draw.icon(c, spec["icon"], Rect2(mid - Vector2.ONE * size * 0.26, Vector2.ONE * size * 0.52), Color.WHITE))
	return c


func _badge(spec: Dictionary) -> Control:
	var accent: Color = spec["accent"]
	var b := UI.panel(UI.flat(Color(accent, 0.22), 8, Color.TRANSPARENT, 0, UI.pad_hv(7, 2)),
			UI.label(spec["badge"], 9.5, accent, "semibold"))
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	b.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return b


## A rounded card filled with the mode's accent fading into the felt.
func _mode_box(accent: Color, radius: float, strength: float, pad: float) -> GradientBox:
	var box := GradientBox.new([Color(accent, strength), Color("#061A14CC") if strength > 0.25 else Color("#061A14B3")],
			radius)
	box.from_align = Vector2(-1, -1)
	box.to_align = Vector2(1, 1)
	box.border_color = Color(accent, 0.55 if strength > 0.25 else 0.42)
	box.border_width = 1
	box.content_margin_left = pad
	box.content_margin_right = pad
	box.content_margin_top = pad
	box.content_margin_bottom = pad
	return box


## The headline way in, as a wide card with a play button.
func _featured(spec: Dictionary, dense: bool) -> Control:
	var accent: Color = spec["accent"]
	var box := _mode_box(accent, 18, 0.32, 14 if dense else 16)
	box.shadows = Tokens.SHADOW_LOW + Tokens.glow(accent, 0.5, 24)
	var title := UI.label(GameSession.mode_label(spec["mode"]), 16 if dense else 18, Tokens.TEXT_PRIMARY, "bold")
	var subtitle := UI.label(spec["subtitle"], 12.5, Tokens.TEXT_MUTED, "medium")
	subtitle.clip_text = true
	subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var text := UI.vbox(3, [UI.hbox(8, [title, _badge(spec)]), subtitle])
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var play_size := 40.0 if dense else 46.0
	var play := Control.new()
	play.custom_minimum_size = Vector2(play_size, play_size)
	play.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	play.draw.connect(func():
		var r := Rect2(Vector2.ZERO, Vector2(play_size, play_size))
		Draw.box_shadow(play, r, play_size / 2.0, Tokens.glow(Tokens.GOLD_DEEP, 0.9, 14))
		Draw.rounded_rect(play, r, play_size / 2.0, Tokens.GOLD_BUTTON, true, Color.TRANSPARENT, 0,
				Tokens.GOLD_BUTTON_STOPS)
		var icon := 24.0 if dense else 28.0
		Draw.icon(play, "play_arrow_rounded", Rect2(r.get_center() - Vector2.ONE * icon / 2.0, Vector2.ONE * icon),
				Tokens.ON_GOLD))
	var row := UI.hbox(0, [_mode_icon(spec, 44 if dense else 52), UI.gap(0, 14), text, UI.gap(0, 10), play])
	return UI.pressable(UI.panel(box, row), func(): start_table(spec["mode"]), 0.97)


## The other three modes, side by side as square tiles.
func _tiles(dense: bool) -> Control:
	var row := UI.hbox(10)
	for i in range(1, MODES.size()):
		row.add_child(UI.expand(_staggered(i, _tile(MODES[i], dense))))
	return row


func _tile(spec: Dictionary, dense: bool) -> Control:
	var accent: Color = spec["accent"]
	var box := _mode_box(accent, 16, 0.2, 10 if dense else 12)
	box.shadows = Tokens.SHADOW_LOW
	var title := UI.label(GameSession.mode_label(spec["mode"]), 14, Tokens.TEXT_PRIMARY, "bold")
	title.clip_text = true
	var col := UI.vbox(0, [_mode_icon(spec, 30 if dense else 36), UI.gap(8 if dense else 10), title, UI.gap(4),
			_badge(spec)])
	if not dense:
		var subtitle := UI.paragraph(spec["subtitle"], 10.5, Tokens.TEXT_MUTED, "medium")
		subtitle.max_lines_visible = 3
		col.add_child(UI.gap(6))
		col.add_child(subtitle)
	# Background, then a large faint glyph in the corner for depth (cut off at
	# the tile's edge), then the content.
	var bg := Panel.new()
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_theme_stylebox_override("panel", box)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var mask := Control.new()
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.set_anchors_preset(Control.PRESET_FULL_RECT)
	mask.clip_contents = true
	var big := 54.0 if dense else 64.0
	var watermark := Control.new()
	watermark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	watermark.set_anchors_preset(Control.PRESET_FULL_RECT)
	watermark.draw.connect(func(): Draw.icon(watermark, spec["icon"],
			Rect2(watermark.size - Vector2(big - 10, big - 12), Vector2(big, big)), Color(accent, 0.1)))
	mask.add_child(watermark)
	var pad := 10.0 if dense else 12.0
	var content := UI.margin(col, UI.pad_all(pad))
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	var stack := Control.new()
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in [bg, mask, content]:
		stack.add_child(c)
	content.minimum_size_changed.connect(func(): stack.custom_minimum_size = content.get_combined_minimum_size())
	stack.custom_minimum_size = content.get_combined_minimum_size()
	return UI.pressable(stack, func(): start_table(spec["mode"]), 0.95)


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
			"You still have a seat held at table %s." % active["roomCode"], "Discard", "Rejoin", "history_rounded",
			Color.TRANSPARENT)
	if not rejoin:
		Settings.identity.clear_active_game()
		return
	var session := Sessions.remote(active["serverUrl"], active["roomCode"], active.get("mode", "private"), 0, false,
			active["resumeToken"], active.get("playerName", Settings.player_name))
	App.instance.push(TableScreen.new(session))


## Three card backs fanned above the wordmark. They spread out of a single
## stack when the screen opens, then drift very slowly — transform-only motion
## on nodes drawn once, so it costs next to nothing to keep alive.
class HeroFan:
	extends Control

	var card_width: float
	var fan_width: float
	var top: float
	var _cards: Array[CardView] = []
	var _t := 0.0

	func _init(card_width_in: float, fan_width_in: float, extra_height: float, top_in: float) -> void:
		card_width = card_width_in
		fan_width = fan_width_in
		top = top_in
		custom_minimum_size = Vector2(fan_width, card_width * CardView.FACE_ASPECT + extra_height)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		for i in 3:
			var card := CardView.back(card_width, true)
			# Turning about the bottom edge, like a hand fanning cards.
			card.pivot_offset = Vector2(card_width / 2.0, card.size.y)
			_cards.append(card)
		# Paint order: the outer two, then the middle one on top.
		for i in [0, 2, 1]:
			add_child(_cards[i])
		_place()

	func _process(delta: float) -> void:
		_t += delta
		_place()

	func _place() -> void:
		var spread := Motion.ease_out_back(clampf(_t / 0.9, 0.0, 1.0))
		var phase := fmod(_t, 4.2) / 4.2 * TAU
		for i in 3:
			var k := i - 1
			var bob := sin(phase + i * 1.3) * 3.0
			var card := _cards[i]
			card.position = Vector2(fan_width / 2.0 - card_width / 2.0 + k * card_width * 0.62 * spread,
					top + (-8.0 if k == 0 else 0.0) * spread + bob)
			card.rotation = k * 0.24 * spread + sin(phase + i) * 0.015
