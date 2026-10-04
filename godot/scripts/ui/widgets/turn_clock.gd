class_name TurnClock
extends Control

## The last stretch of a turn, drawn as a draining ring around a seat's avatar.
##
## It says nothing for most of a turn — a clock that is always visible stops
## being read. It appears for the final [constant WINDOW_MS] and turns red,
## pulses and (for the viewer's own seat only) ticks below
## [constant ALARM_SECONDS]: past the deadline the table plays the seat.

const WINDOW_MS := 10000
const ALARM_SECONDS := 5

## The deadline on this device's monotonic clock, or 0 for none.
var deadline_ms := 0:
	set(v):
		if v != deadline_ms:
			_set_ticking(false)
		deadline_ms = v
		set_process(v > 0)
		queue_redraw()
## Only the viewer's own clock may tick out loud.
var audible := false

var _ticking := false


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)


func _process(_delta: float) -> void:
	var left := deadline_ms - Time.get_ticks_msec()
	var seconds := ceili(left / 1000.0)
	_set_ticking(audible and seconds > 0 and seconds <= ALARM_SECONDS)
	if left <= 0:
		set_process(false)
	queue_redraw()


func _exit_tree() -> void:
	_set_ticking(false)


func _set_ticking(on: bool) -> void:
	if _ticking == on:
		return
	_ticking = on
	if on:
		Audio.start_tick()
	else:
		Audio.stop_tick()


func _draw() -> void:
	if deadline_ms <= 0:
		return
	var left := deadline_ms - Time.get_ticks_msec()
	if left >= WINDOW_MS or left <= 0:
		return
	var fraction := clampf(float(left) / WINDOW_MS, 0.0, 1.0)
	var seconds := ceili(left / 1000.0)
	var alarm := seconds <= ALARM_SECONDS
	var urgency := clampf(1.0 - fraction / 0.6, 0.0, 1.0)
	var colour := Tokens.GOLD_MID.lerp(Tokens.DANGER, urgency)
	var beat := 1.0 + 0.06 * sin(left / 1000.0 * TAU) if alarm else 1.0
	var d := minf(size.x, size.y) * beat
	var stroke := d * 0.075
	var c := size / 2.0
	var r := d / 2.0 - stroke / 2.0
	draw_arc(c, r, 0, TAU, 48, Color(0, 0, 0, 0.4), stroke, true)
	draw_arc(c, r, -PI / 2, -PI / 2 + TAU * fraction, 48, Color(colour, 0.55), stroke * 1.8, true)
	draw_arc(c, r, -PI / 2, -PI / 2 + TAU * fraction, 48, colour, stroke, true)
	# The count itself, for players who want the number rather than the shape.
	var badge := d * 0.4
	var bc := c + Vector2(d * 0.36, d * 0.36)
	draw_circle(bc, badge / 2.0, Color(0.039, 0.071, 0.027, 0.9), true, -1.0, true)
	draw_arc(bc, badge / 2.0 - badge * 0.035, 0, TAU, 24, colour, badge * 0.07, true)
	var font := Tokens.font("bold")
	var fs := int(badge * 0.55)
	var text := str(seconds)
	var tw := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(font, bc + Vector2(-tw / 2.0, fs * 0.36), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, colour)
