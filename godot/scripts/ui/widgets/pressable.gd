class_name Pressable
extends MarginContainer

## Instant press feedback for anything tappable: the content dips a little
## while held and springs back, so a surface reads as a button. Emits
## [signal pressed] on release inside the control. A drag that strays far
## from the touch-down point (a scroll) cancels the press.

signal pressed

var press_scale := 0.94
var enabled := true:
	set(v):
		enabled = v
		modulate.a = 1.0 if v else 0.55
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if v else Control.CURSOR_ARROW

var _down := false
var _down_pos := Vector2.ZERO
var _tween: Tween


func _init() -> void:
	# PASS, not STOP: a scroll list underneath still sees the touch, so a list
	# of buttons drags to scroll like any other.
	mouse_filter = Control.MOUSE_FILTER_PASS
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for side in ["left", "right", "top", "bottom"]:
		add_theme_constant_override("margin_" + side, 0)
	child_entered_tree.connect(func(_n): _make_content_click_through.call_deferred())


func _ready() -> void:
	resized.connect(func(): pivot_offset = size / 2.0)
	pivot_offset = size / 2.0
	_make_content_click_through()


## Content (panels default to STOP) must not swallow the touch meant for the
## button itself.
func _make_content_click_through(node: Node = self) -> void:
	for child in node.get_children():
		if child is Control:
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_make_content_click_through(child)


func _gui_input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_down = true
			_down_pos = event.position
			_animate(press_scale)
		elif _down:
			_down = false
			_animate(1.0)
			if Rect2(Vector2.ZERO, size).has_point(event.position):
				accept_event()
				pressed.emit()
	elif event is InputEventMouseMotion and _down:
		if event.position.distance_to(_down_pos) > 14.0:
			_down = false
			_animate(1.0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _down and not DisplayServer.is_touchscreen_available():
		_down = false
		_animate(1.0)


func _animate(to: float) -> void:
	if _tween != null:
		_tween.kill()
	_tween = create_tween().set_parallel().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "scale", Vector2(to, to), 0.09)
	_tween.tween_property(self, "modulate:a", 0.82 if to < 1.0 else 1.0, 0.09)
