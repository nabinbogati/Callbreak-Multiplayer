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
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_child(child)
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
	e.add_theme_stylebox_override("normal", flat(Tokens.PANEL, 12, Tokens.HAIRLINE_STRONG, 1, pad_hv(14, 12)))
	e.add_theme_stylebox_override("focus", flat(Color.TRANSPARENT, 12, Tokens.GOLD_BORDER, 1.5, pad_hv(14, 12)))
	e.custom_minimum_size.y = 46
	return e


## A segmented choice: [param options] are `[label, value]` pairs; the chip for
## [param current] is highlighted, and tapping another calls
## [param on_change] with its value.
static func choices(options: Array, current, on_change: Callable, font_size := 12.0) -> HBoxContainer:
	var row := hbox(6)
	for opt in options:
		var selected: bool = opt[1] == current
		var style := flat(Color(Tokens.GOLD, 0.16) if selected else Tokens.PANEL,
				10, Tokens.GOLD_BORDER if selected else Tokens.HAIRLINE_STRONG, 1, pad_hv(11, 7))
		var chip := pressable(panel(style, label(opt[0], font_size,
				Tokens.GOLD if selected else Tokens.TEXT_ON_DARK, "semibold", HORIZONTAL_ALIGNMENT_CENTER)),
				func(): on_change.call(opt[1]), 0.94)
		row.add_child(chip)
	return row


## A settings row: label on the left, its choice chips on the right.
static func setting_row(text: String, control: Control) -> HBoxContainer:
	var l := label(text, sc(13, 12), Tokens.TEXT_ON_DARK)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return hbox(10, [l, control])


static func free_children(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()
