class_name PulseRipple
extends Control

## Rings that swell out of a small gold glyph and fade — "something is being
## looked for". Each ring's phase is staggered so they never stack.

const PERIOD := 1.8

var icon_name := "signal"
var ring_count := 3
var _t := 0.0


func _init(size_in := 68.0, icon_in := "signal", rings := 3) -> void:
	icon_name = icon_in
	ring_count = rings
	custom_minimum_size = Vector2(size_in, size_in)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_t = fmod(_t + delta / PERIOD, 1.0)
	queue_redraw()


func _draw() -> void:
	var c := size / 2.0
	var full := minf(size.x, size.y) / 2.0
	var core := full * 0.56
	for i in ring_count:
		var phase := fmod(_t + float(i) / ring_count, 1.0)
		var r := lerpf(core, full, phase)
		draw_arc(c, r, 0, TAU, 48, Color(Tokens.GOLD, (1.0 - phase) * 0.45), 1.5, true)
	draw_circle(c, core, Color(Tokens.GOLD, 0.14), true, -1.0, true)
	draw_arc(c, core - 0.75, 0, TAU, 40, Color(Tokens.GOLD_BORDER, 0.6), 1.5, true)
	Draw.icon(self, icon_name, Rect2(c - Vector2.ONE * core * 0.5, Vector2.ONE * core), Tokens.GOLD)
