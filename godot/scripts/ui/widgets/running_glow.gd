class_name RunningGlow
extends Control

## A slow, soft light travelling around a rounded border, so a card feels
## gently alive without any movement of its content. Sits over the card it
## decorates and ignores input.

const PERIOD := 1.8

var accent := Color.WHITE
var radius := 14.0
var _t := 0.0
var _path := PackedVector2Array()
var _lengths := PackedFloat32Array()


func _init(accent_in: Color, radius_in := 14.0) -> void:
	accent = accent_in
	radius = radius_in
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	resized.connect(_rebuild)


func _rebuild() -> void:
	_path = Draw.rounded_rect_points(Rect2(Vector2.ZERO, size).grow(-0.5), radius, 10)
	_path.append(_path[0])
	_lengths = PackedFloat32Array([0.0])
	for i in range(1, _path.size()):
		_lengths.append(_lengths[i - 1] + _path[i].distance_to(_path[i - 1]))


func _process(delta: float) -> void:
	_t = fmod(_t + delta / PERIOD, 1.0)
	queue_redraw()


func _draw() -> void:
	if _path.size() < 3:
		return
	draw_polyline(_path, Color(accent, 0.22), 1.0, true)
	var total := _lengths[_lengths.size() - 1]
	var start := _t * total
	var seg := total * 0.14
	var pts := _segment(start, start + seg, total)
	if pts.size() >= 2:
		draw_polyline(pts, Color(accent, 0.18), 7.0, true)
		draw_polyline(pts, Color(accent, 0.7), 2.5, true)


## The stretch of the border between two distances along it, wrapping round.
func _segment(from: float, to: float, total: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var steps := 24
	for i in steps + 1:
		out.append(_point_at(fmod(from + (to - from) * i / steps, total)))
	return out


func _point_at(d: float) -> Vector2:
	var lo := 0
	var hi := _lengths.size() - 1
	while lo < hi - 1:
		var mid := (lo + hi) / 2
		if _lengths[mid] <= d:
			lo = mid
		else:
			hi = mid
	var span := _lengths[hi] - _lengths[lo]
	var f := 0.0 if span <= 0.0 else (d - _lengths[lo]) / span
	return _path[lo].lerp(_path[hi], f)
