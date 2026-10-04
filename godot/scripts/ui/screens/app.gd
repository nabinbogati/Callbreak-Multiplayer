class_name App
extends Control

## The app shell (the main scene's root): scales the UI to the design, keeps a
## stack of screens, hosts modal sheets and dialogs above them, and routes the
## Android back button.
##
## Design pixels: the viewport is resized so its short side is the design's
## 390, grown up to 1.4× on tablets (and never below 0.78×) exactly as the
## Flutter `Metrics` class did. Every layout then works in plain design pixels.

signal layout_changed

const DESIGN_SHORT_SIDE := 390.0
const MIN_SCALE := 0.78
const MAX_SCALE := 1.4

static var instance: App

var _screens: Array[Control] = []
var _overlays: Array[Control] = []
var _screen_layer := Control.new()
var _overlay_layer := Control.new()
var _last_window := Vector2i.ZERO


func _ready() -> void:
	instance = self
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = _make_theme()
	for layer in [_screen_layer, _overlay_layer]:
		layer.set_anchors_preset(Control.PRESET_FULL_RECT)
		layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(layer)
	get_tree().root.size_changed.connect(_update_scale)
	_update_scale()
	push(HomeScreen.new())


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = Tokens.font("medium")
	t.default_font_size = 14
	t.set_color("font_color", "Label", Tokens.TEXT_PRIMARY)
	# Lines sit flush, as in the design; Godot's default adds 3px between them.
	t.set_constant("line_spacing", "Label", 0)
	var empty := StyleBoxEmpty.new()
	t.set_stylebox("panel", "PanelContainer", empty)
	t.set_stylebox("panel", "ScrollContainer", empty)
	t.set_stylebox("focus", "ScrollContainer", empty)
	return t


## Sizes the viewport in design pixels for the current window and orientation.
func _update_scale() -> void:
	var window := DisplayServer.window_get_size()
	if window == _last_window or window.x <= 0 or window.y <= 0:
		_relayout()
		return
	_last_window = window
	var density := _density_override()
	if density <= 0.0:
		density = maxf(DisplayServer.screen_get_dpi() / 160.0, 1.0) if OS.has_feature("mobile") else 1.0
	var dp := Vector2(window) / density
	var m := clampf(minf(dp.x, dp.y) / DESIGN_SHORT_SIDE, MIN_SCALE, MAX_SCALE)
	get_tree().root.content_scale_size = Vector2i((dp / m).round())
	_relayout()


## `-- --density=2` on the command line makes a desktop window behave like a
## phone of that pixel density — for previews and screenshots.
static func _density_override() -> float:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--density="):
			return float(arg.get_slice("=", 1))
	return 0.0


func _relayout() -> void:
	var view := get_viewport_rect().size
	UI.portrait = view.y >= view.x
	UI.safe = _safe_insets(view)
	layout_changed.emit()


## The OS safe area (notches, gesture bar) in design pixels.
func _safe_insets(view: Vector2) -> Vector4:
	if not OS.has_feature("mobile"):
		return Vector4.ZERO
	var window := Vector2(DisplayServer.window_get_size())
	var safe := DisplayServer.get_display_safe_area()
	if window.x <= 0 or safe.size.x <= 0:
		return Vector4.ZERO
	var k := view.x / window.x
	return Vector4(maxf(0, safe.position.x * k), maxf(0, safe.position.y * k),
			maxf(0, (window.x - safe.end.x) * k), maxf(0, (window.y - safe.end.y) * k))


# ---------------------------------------------------------------- screens

## One transition everywhere: the next screen fades up out of a slight zoom,
## which reads as moving *into* the table rather than sliding sideways past it.
const TRANSITION := 0.3


func push(screen: Control) -> void:
	var below: Control = _screens.back() if not _screens.is_empty() else null
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	_screens.append(screen)
	_screen_layer.add_child(screen)
	if below == null:
		return
	_animate(screen, true, func():
		# Hidden once covered, so it stops drawing (and taking touches).
		if is_instance_valid(below) and _screens.has(below) and _screens.back() != below:
			below.visible = false
			if below.has_method("on_hidden"):
				below.on_hidden())


func pop() -> void:
	if _screens.size() <= 1:
		return
	var top: Control = _screens.pop_back()
	_reveal(_screens.back())
	_animate(top, false, top.queue_free)


func replace(screen: Control) -> void:
	if _screens.size() <= 1:
		push(screen)
		return
	var top: Control = _screens.pop_back()
	push(screen)
	# The outgoing screen stays under the incoming one until it is covered.
	get_tree().create_timer(TRANSITION).timeout.connect(top.queue_free)


func pop_to_root() -> void:
	close_overlays()
	if _screens.size() <= 1:
		return
	var top: Control = _screens.pop_back()
	while _screens.size() > 1:
		_screens.pop_back().queue_free()
	_reveal(_screens[0])
	_animate(top, false, top.queue_free)


func _reveal(screen: Control) -> void:
	screen.visible = true
	if screen.has_method("on_shown"):
		screen.on_shown()


## Fades [param screen] in from a 0.96 zoom (or back out to it), then calls
## [param done].
func _animate(screen: Control, entering: bool, done: Callable) -> void:
	var step := func(t: float) -> void:
		var e := Motion.emphasized(t) if entering else Motion.ease_in_cubic(t)
		screen.modulate.a = e
		screen.pivot_offset = screen.size / 2.0
		screen.scale = Vector2.ONE * (0.96 + 0.04 * e)
	step.call(0.0 if entering else 1.0)
	var tween := screen.create_tween()
	tween.tween_method(step, 0.0 if entering else 1.0, 1.0 if entering else 0.0, TRANSITION)
	tween.tween_callback(done)


func top_screen() -> Control:
	return _screens.back() if not _screens.is_empty() else null


# --------------------------------------------------------------- overlays

## Shows [param content] in the standard sheet chrome: a bottom sheet in
## portrait, a centred bounded panel in landscape. Await `closed` on the
## returned [Sheet] for its result.
func sheet(content: Control) -> Sheet:
	var s := Sheet.new(content)
	_add_overlay(s)
	s.closed.connect(func(_r): _remove_overlay(s))
	return s


## A two-button confirmation; resolves true for the primary choice.
func confirm(title: String, message: String, cancel_label: String, ok_label: String, icon := "",
		scrim := Color("#0000008C")) -> bool:
	var d := ConfirmDialog.new(title, message, cancel_label, ok_label, icon, scrim)
	_add_overlay(d)
	var result: bool = await d.closed
	_remove_overlay(d)
	return result


## A short message that fades on its own, like a snackbar.
func toast(text: String) -> void:
	var t := UI.panel(UI.with_shadow(UI.flat(Color(0.039, 0.071, 0.027, 0.94), 12, Tokens.HAIRLINE_STRONG, 1,
			UI.pad_hv(16, 11))), UI.paragraph(text, 13, Tokens.TEXT_PRIMARY, "semibold", HORIZONTAL_ALIGNMENT_CENTER))
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(t)
	var view := get_viewport_rect().size
	t.custom_minimum_size.x = minf(view.x - 32, 360)
	t.reset_size()
	t.position = Vector2((view.x - t.size.x) / 2.0, view.y - t.size.y - 28 - UI.safe.w)
	var tw := t.create_tween()
	t.modulate.a = 0.0
	tw.tween_property(t, "modulate:a", 1.0, 0.2)
	tw.tween_interval(2.6)
	tw.tween_property(t, "modulate:a", 0.0, 0.3)
	tw.tween_callback(t.queue_free)


func close_overlays() -> void:
	for o in _overlays.duplicate():
		if o.has_method("dismiss"):
			o.dismiss()
		else:
			_remove_overlay(o)


func has_overlay() -> bool:
	return not _overlays.is_empty()


func _add_overlay(o: Control) -> void:
	o.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlays.append(o)
	_overlay_layer.add_child(o)


func _remove_overlay(o: Control) -> void:
	_overlays.erase(o)
	if is_instance_valid(o):
		o.queue_free()


# ------------------------------------------------------------------- back

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		_handle_back()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_handle_back()
		get_viewport().set_input_as_handled()


func _handle_back() -> void:
	if not _overlays.is_empty():
		var top: Control = _overlays.back()
		if top.has_method("dismiss"):
			top.dismiss()
		return
	var screen := top_screen()
	if screen != null and screen.has_method("handle_back"):
		screen.handle_back()
	elif _screens.size() > 1:
		pop()
	else:
		get_tree().quit()
