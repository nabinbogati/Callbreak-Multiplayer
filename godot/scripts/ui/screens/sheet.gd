class_name Sheet
extends Control

## Modal sheet chrome: pinned to the bottom with rounded top corners in
## portrait, a centred bounded panel in landscape so it never runs off a short
## screen. Tapping the scrim dismisses it. Content calls [method close] with a
## result; awaiting [signal closed] yields it (null when dismissed).

signal closed(result)

var content: Control
var _panel: PanelContainer
var _scrim: ColorRect
var _done := false
var _last_keyboard := 0


func _init(content_in: Control) -> void:
	content = content_in
	mouse_filter = Control.MOUSE_FILTER_STOP
	_scrim = ColorRect.new()
	_scrim.color = Color(0, 0, 0, 0.54)
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.gui_input.connect(func(e):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			dismiss())
	add_child(_scrim)
	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	# Scrolls once the content outgrows the screen: a short landscape window,
	# or the keyboard taking the bottom half.
	var scroller := UI.scroll(content)
	scroller.follow_focus = true
	_panel.add_child(scroller)
	add_child(_panel)
	if content.has_signal("finished"):
		content.connect("finished", close)
	content.set_meta("sheet", self)


func _ready() -> void:
	App.instance.layout_changed.connect(_layout)
	resized.connect(_layout)
	content.minimum_size_changed.connect(func(): _layout.call_deferred())
	_layout()
	modulate.a = 0.0
	var t := create_tween()
	t.tween_property(self, "modulate:a", 1.0, 0.18)


static func _keyboard_height() -> int:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		return 0
	return DisplayServer.virtual_keyboard_get_height()


func _process(_delta: float) -> void:
	# Ride above the on-screen keyboard.
	var kb := _keyboard_height()
	if kb != _last_keyboard:
		_last_keyboard = kb
		_layout()


func _layout() -> void:
	var view := size
	if view.x <= 0:
		return
	var palette := Settings.palette()
	var bg: Color = palette["table"][2]
	var kb := 0.0
	var window_h := float(DisplayServer.window_get_size().y)
	if window_h > 0:
		kb = _keyboard_height() * view.y / window_h
	if UI.portrait:
		var style := UI.flat(bg, 24)
		style.corner_radius_bottom_left = 0
		style.corner_radius_bottom_right = 0
		_panel.add_theme_stylebox_override("panel", style)
		var max_h := view.y - UI.safe.y - kb
		_panel.custom_minimum_size = Vector2(view.x, 0)
		_panel.size = Vector2(view.x, 0)
		_panel.reset_size()
		var h := minf(_natural_height(), max_h)
		_panel.size = Vector2(view.x, h)
		_panel.position = Vector2(0, view.y - h - kb)
	else:
		_panel.add_theme_stylebox_override("panel", UI.flat(bg, UI.sc(20, 16)))
		var w := minf(UI.sc(520, 560), view.x - 32)
		var max_h := (view.y - kb) * 0.92
		_panel.custom_minimum_size = Vector2(w, 0)
		_panel.reset_size()
		var h := minf(_natural_height(), max_h)
		_panel.size = Vector2(w, h)
		_panel.position = Vector2((view.x - w) / 2.0, (view.y - kb - h) / 2.0)


## The panel's height with all of its content showing. The scroller inside
## claims none of the content's height, so it is added back here.
func _natural_height() -> float:
	return _panel.get_combined_minimum_size().y + content.get_combined_minimum_size().y


func close(result = null) -> void:
	if _done:
		return
	_done = true
	closed.emit(result)


func dismiss() -> void:
	close(null)
