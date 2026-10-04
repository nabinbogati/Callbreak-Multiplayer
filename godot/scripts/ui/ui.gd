class_name UI
extends RefCounted

## Factories for the app's building blocks, so screens read as layout rather
## than as style plumbing. Every measurement is in design pixels: the root
## viewport is scaled so its short side is the design's 390 (see main.gd), the
## same contract the Flutter `Metrics` class kept.

## Whether the viewport is taller than it is wide. Kept current by main.gd.
static var portrait := true
## The OS safe-area insets (left, top, right, bottom) in design pixels.
static var safe := Vector4.ZERO

const GOLD_SHADER := preload("res://scripts/ui/gold_text.gdshader")


## Picks a design-pixel value per orientation — landscape has far less height.
static func sc(portrait_px: float, landscape_px: float) -> float:
	return portrait_px if portrait else landscape_px


static func label(text: String, size: float, color: Color, weight := "medium",
		align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = align
	l.add_theme_font_override("font", Tokens.font(weight))
	l.add_theme_font_size_override("font_size", int(round(size)))
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## A label that wraps onto several lines within its width.
static func paragraph(text: String, size: float, color: Color, weight := "medium",
		align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := label(text, size, color, weight, align)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 40
	return l


## Text painted with the wordmark's gold gradient.
static func gold_text(text: String, size: float, weight := "display") -> Label:
	var l := label(text, size, Color.WHITE, weight, HORIZONTAL_ALIGNMENT_CENTER)
	var mat := ShaderMaterial.new()
	mat.shader = GOLD_SHADER
	l.material = mat
	var sync := func(): mat.set_shader_parameter("height", l.size.y)
	l.resized.connect(sync)
	if weight == "display":
		l.add_theme_constant_override("outline_size", 0)
	return l


static func flat(bg: Color, radius: float, border := Color.TRANSPARENT, border_width := 0.0,
		pad := Vector4.ZERO) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(int(round(radius)))
	s.corner_detail = 6
	s.anti_aliasing = true
	# Feathered by one device pixel, not one design pixel (see Draw.device_px).
	s.anti_aliasing_size = Draw.device_px()
	if border.a > 0.0 and border_width > 0.0:
		s.border_color = border
		s.set_border_width_all(int(ceil(border_width)))
	_pad(s, pad)
	return s


static func with_shadow(s: StyleBox, color := Color(0, 0, 0, 0.45), blur := 16.0, offset := Vector2(0, 6)) -> StyleBox:
	if s is StyleBoxFlat:
		s.shadow_color = color
		s.shadow_size = int(blur * 0.6)
		s.shadow_offset = offset
	elif s is GradientBox:
		s.shadow_color = color
		s.shadow_blur = blur
		s.shadow_offset = offset
	return s


static func gold(radius: float, pad := Vector4.ZERO) -> GradientBox:
	var g := GradientBox.new([Tokens.GOLD, Tokens.GOLD_DEEP], radius, false)
	_pad(g, pad)
	return g


## `pad` is (left, top, right, bottom).
static func _pad(s: StyleBox, pad: Vector4) -> void:
	s.content_margin_left = pad.x
	s.content_margin_top = pad.y
	s.content_margin_right = pad.z
	s.content_margin_bottom = pad.w


static func pad_all(v: float) -> Vector4:
	return Vector4(v, v, v, v)


static func pad_hv(h: float, v: float) -> Vector4:
	return Vector4(h, v, h, v)


static func panel(style: StyleBox, child: Control = null) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", style)
	if child != null:
		p.add_child(child)
	return p


static func vbox(separation := 0.0, children: Array = []) -> VBoxContainer:
	var b := VBoxContainer.new()
	b.add_theme_constant_override("separation", int(round(separation)))
	for c in children:
		if c != null:
			b.add_child(c)
	return b


static func hbox(separation := 0.0, children: Array = []) -> HBoxContainer:
	var b := HBoxContainer.new()
	b.add_theme_constant_override("separation", int(round(separation)))
	for c in children:
		if c != null:
			b.add_child(c)
	return b


static func margin(child: Control, pad: Vector4) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", int(pad.x))
	m.add_theme_constant_override("margin_top", int(pad.y))
	m.add_theme_constant_override("margin_right", int(pad.z))
	m.add_theme_constant_override("margin_bottom", int(pad.w))
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if child != null:
		m.add_child(child)
	return m


static func center(child: Control) -> CenterContainer:
	var c := CenterContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(child)
	return c


static func gap(height: float, width := 0.0) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(width, height)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func expand(node: Control, ratio := 1.0) -> Control:
	node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	node.size_flags_stretch_ratio = ratio
	return node


static func expand_v(node: Control) -> Control:
	node.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return node


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func icon(name: String, size: float, color: Color) -> IconView:
	return IconView.new(name, size, color)


static func scroll(child: Control) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Scrolls by drag with no bar, as lists do on Android.
	s.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_child(child)
	return s


## A [method scroll] as tall as [param child] up to [param max_height], so the
## panel around it fits its content where there is room and scrolls where
## there is not. A bare ScrollContainer claims no height at all, so a panel
## sized to its content would collapse round it.
static func fit_scroll(child: Control, max_height: float) -> ScrollContainer:
	var s := scroll(child)
	var fit := func():
		var h := child.get_combined_minimum_size().y
		s.custom_minimum_size.y = clampf(h, 0.0, maxf(max_height, 0.0))
		# Clipped only while it scrolls, so a button's glow can still spill
		# into the panel's padding.
		s.clip_contents = h > max_height
	child.minimum_size_changed.connect(fit)
	fit.call()
	return s


## Wraps content in a [Pressable] and connects [param on_press].
static func pressable(content: Control, on_press := Callable(), press_scale := 0.94) -> Pressable:
	var p := Pressable.new()
	p.press_scale = press_scale
	p.add_child(content)
	if on_press.is_valid():
		p.pressed.connect(on_press)
	return p


## The app's two button styles: gold gradient (primary) or outlined panel.
static func button(text: String, primary := true, on_press := Callable(), font_size := 14.0,
		pad := Vector4(28, 13, 28, 13)) -> Pressable:
	var style: StyleBox = gold(13, pad) if primary else flat(Tokens.PANEL, 13, Tokens.HAIRLINE_STRONG, 1, pad)
	var l := label(text, font_size, Tokens.ON_GOLD if primary else Tokens.TEXT_ON_DARK, "bold",
			HORIZONTAL_ALIGNMENT_CENTER)
	return pressable(panel(style, l), on_press)


## The primary action: a lit gold slab with a soft halo. One look for every
## "do the main thing" button — confirm a bid, start a game, play again.
static func gold_button(text: String, on_press := Callable(), icon_name := "", dense := false) -> Pressable:
	var box := GradientBox.new(Tokens.GOLD_BUTTON, sc(14, 12), true)
	box.offsets = Tokens.GOLD_BUTTON_STOPS
	box.border_color = Color("#FFF6D866")
	box.border_width = 1
	box.shadows = Tokens.glow(Tokens.GOLD_DEEP, 0.9, 16)
	_pad(box, pad_hv(18, sc(11, 8) if dense else sc(15, 11)))
	var l := label(text, sc(13, 12) if dense else sc(15, 13), Tokens.ON_GOLD, "bold", HORIZONTAL_ALIGNMENT_CENTER)
	return pressable(panel(box, _icon_row(icon_name, sc(18, 16), 8, Tokens.ON_GOLD, l)), on_press, 0.96)


## The secondary action: a quiet glass slab beside a [method gold_button].
static func ghost_button(text: String, on_press := Callable(), icon_name := "", dense := false) -> Pressable:
	var style := flat(Color("#FFFFFF14"), sc(14, 12), Tokens.HAIRLINE_STRONG, 1,
			pad_hv(16, sc(11, 8) if dense else sc(15, 11)))
	var l := label(text, sc(13, 12) if dense else sc(14, 13), Tokens.TEXT_ON_DARK, "semibold", HORIZONTAL_ALIGNMENT_CENTER)
	return pressable(panel(style, _icon_row(icon_name, sc(17, 15), 7, Tokens.TEXT_ON_DARK, l)), on_press, 0.96)


static func _icon_row(icon_name: String, icon_size: float, gap_px: float, color: Color, text: Label) -> Control:
	if icon_name.is_empty():
		return text
	var row := hbox(gap_px, [icon(icon_name, icon_size, color), text])
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	return row


## The raised glass surface every floating panel is painted with.
static func glass_box(pad := Vector4(20, 20, 20, 20), accent := Tokens.GOLD_BORDER, radius := 20.0) -> GradientBox:
	var box := GradientBox.new(Tokens.SURFACE, radius, true)
	box.border_color = Color(accent, 0.38)
	box.border_width = 1
	box.shadows = Tokens.SHADOW_HIGH
	_pad(box, pad)
	return box


## The raised glass card every floating panel sits in — dialogs, the bid
## panel, the scoreboard, the reconnect notice.
static func glass_panel(child: Control, pad := Vector4(20, 20, 20, 20), accent := Tokens.GOLD_BORDER) -> PanelContainer:
	return panel(glass_box(pad, accent), child)


## A one-shot scale-and-fade entrance for a panel appearing over the table.
static func pop_in(node: Control, duration := 0.28, from := 0.9) -> void:
	var run := func(t: float) -> void:
		var e := Motion.ease_out_back(t)
		node.modulate.a = clampf(e, 0.0, 1.0)
		node.pivot_offset = node.size / 2.0
		node.scale = Vector2.ONE * (from + (1.0 - from) * e)
	run.call(0.0)
	node.create_tween().tween_method(run, 0.0, 1.0, duration)


## A one-shot rise-and-fade: [param node] drifts up [param rise] px into place
## as it fades in over [param duration] (on the entrance curve). With a
## [param stagger], item [param index] holds back for the first part of its
## run. Returns a wrapper to add in the node's place — a container would
## otherwise pin the node's position.
static func rise_in(node: Control, duration: float, rise: float, index := 0, stagger := 0.0) -> Control:
	var wrap := Control.new()
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.size_flags_horizontal = node.size_flags_horizontal
	wrap.add_child(node)
	var fit := func(): wrap.custom_minimum_size = node.get_combined_minimum_size()
	node.minimum_size_changed.connect(fit)
	fit.call()
	var run := func(t: float) -> void:
		var local := clampf(Motion.enter(t) * (1.0 + index * stagger) - index * stagger, 0.0, 1.0)
		node.modulate.a = local
		node.position = Vector2(0, rise * (1.0 - local))
	wrap.resized.connect(func(): node.size = wrap.size)
	run.call(0.0)
	wrap.create_tween().tween_method(run, 0.0, 1.0, duration)
	return wrap


## A suit glyph as a control, [param size] tall.
static func suit_glyph(suit_value: int, size: float, color: Color) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(size * Draw.suit_aspect(suit_value), size)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	c.draw.connect(func(): Draw.suit(c, suit_value, c.size / 2.0, size, color))
	return c


## A translucent rounded pill — the home and table chrome.
static func glass_pill(content: Control, on_press := Callable(), radius := 22.0,
		pad := Vector4(15, 10, 15, 10), border := Tokens.HAIRLINE_STRONG, bg := Tokens.PANEL_SOFT) -> Pressable:
	return pressable(panel(flat(bg, radius, border, 1, pad), content), on_press)


static func line_edit(text := "", placeholder := "", font_size := 15.0) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.placeholder_text = placeholder
	e.add_theme_font_override("font", Tokens.font("semibold"))
	e.add_theme_font_size_override("font_size", int(font_size))
	e.add_theme_color_override("font_color", Tokens.TEXT_PRIMARY)
	e.add_theme_color_override("font_placeholder_color", Tokens.TEXT_FAINT)
	e.add_theme_color_override("caret_color", Tokens.GOLD)
	# A filled panel whose hairline border warms to gold while it has focus.
	var pad := pad_all(sc(14, 9))
	e.add_theme_stylebox_override("normal", flat(Tokens.PANEL, sc(12, 9), Tokens.HAIRLINE, 1, pad))
	e.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, sc(12, 9), Tokens.GOLD, 1.5, pad))
	return e


## A segmented choice: [param options] are `[label, value]` pairs; the chip for
## [param current] is filled gold, and tapping another calls
## [param on_change] with its value.
static func choices(options: Array, current, on_change: Callable, spacing := 6.0) -> HBoxContainer:
	var row := hbox(spacing)
	for opt in options:
		var selected: bool = opt[1] == current
		row.add_child(glass_pill(label(opt[0], sc(13, 11), Tokens.ON_GOLD if selected else Tokens.TEXT_ON_DARK, "semibold",
				HORIZONTAL_ALIGNMENT_CENTER), func(): on_change.call(opt[1]), sc(10, 8), pad_hv(sc(16, 11), sc(10, 6)),
				Tokens.GOLD if selected else Tokens.HAIRLINE, Tokens.GOLD if selected else Tokens.PANEL))
	return row


## A settings row: label on the left, its choice chips on the right.
static func setting_row(text: String, control: Control, gap_px := 12.0) -> HBoxContainer:
	var l := label(text, sc(13, 12), Tokens.TEXT_ON_DARK)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.max_lines_visible = 2
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	control.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return hbox(gap_px, [l, control])


static func free_children(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()
