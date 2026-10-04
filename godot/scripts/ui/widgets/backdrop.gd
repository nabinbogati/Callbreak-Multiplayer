class_name Backdrop
extends Control

## The full-bleed background every screen sits on: a three-stop gradient in
## the theme's colours (top→bottom in portrait, left→right in landscape) with a
## soft radial bloom of the theme's glow colour.

## Which palette key to paint: "background" (home) or "table".
var palette_key := "background"
## Flutter-style alignment of the bloom's centre, -1..1 on each axis, per
## orientation.
var glow_alignment_portrait := Vector2(-0.85, 0.0)
var glow_alignment_landscape := Vector2(-0.55, -0.1)
var glow_scale := 1.1

var _linear := GradientTexture2D.new()
var _radial := GradientTexture2D.new()


func _init(key := "background") -> void:
	palette_key = key
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_radial.fill = GradientTexture2D.FILL_RADIAL
	_radial.fill_from = Vector2(0.5, 0.5)
	_radial.fill_to = Vector2(1.0, 0.5)
	_radial.width = 128
	_radial.height = 128
	_linear.width = 4
	_linear.height = 256
	Settings.changed.connect(_refresh)
	resized.connect(queue_redraw)
	_refresh()


func _refresh() -> void:
	var palette := Settings.palette()
	var stops: Array = palette[palette_key]
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.45, 1.0])
	g.colors = PackedColorArray(stops)
	_linear.gradient = g
	var glow: Color = palette["glow"]
	var r := Gradient.new()
	r.offsets = PackedFloat32Array([0.0, 0.4, 0.7, 1.0])
	r.colors = PackedColorArray([Color(glow, 0.42), Color(glow, 0.24), Color(glow, 0.11), Color(glow, 0.0)])
	_radial.gradient = r
	queue_redraw()


func _draw() -> void:
	var horizontal := size.x > size.y
	_linear.fill_from = Vector2(0, 0)
	_linear.fill_to = Vector2(1, 0) if horizontal else Vector2(0, 1)
	_linear.width = 256 if horizontal else 4
	_linear.height = 4 if horizontal else 256
	draw_texture_rect(_linear, Rect2(Vector2.ZERO, size), false)
	var align := glow_alignment_portrait if not horizontal else glow_alignment_landscape
	# A circle, as wide as the shorter side of the scaled box.
	var d := minf(size.x * glow_scale, size.y * glow_scale)
	var box := Vector2(size.x * glow_scale, size.y * glow_scale)
	var box_pos := (size - box) / 2.0 * (Vector2.ONE + align)
	var center := box_pos + box / 2.0
	draw_texture_rect(_radial, Rect2(center - Vector2(d, d) / 2.0, Vector2(d, d)), false)
