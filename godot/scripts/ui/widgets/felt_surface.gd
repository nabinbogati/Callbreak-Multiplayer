class_name FeltSurface
extends Control

## The felt playing surface: a soft ellipse with a radial sheen, a gold
## hairline and a faint inner ring, sized to whatever box it is given.

var _sheen := GradientTexture2D.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sheen.fill = GradientTexture2D.FILL_RADIAL
	_sheen.fill_from = Vector2(0.5, 0.5)
	_sheen.fill_to = Vector2(1.0, 0.5)
	_sheen.width = 128
	_sheen.height = 128
	Settings.changed.connect(_refresh)
	resized.connect(queue_redraw)
	_refresh()


func _refresh() -> void:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.62, 1.0])
	g.colors = PackedColorArray(Settings.palette()["felt"])
	_sheen.gradient = g
	queue_redraw()


## The design's rounded rect with elliptical (400×300) corners, which on any
## phone-sized felt clamps to an ellipse-like stadium.
static func outline(rect: Rect2, rx := 400.0, ry := 300.0, segments := 16) -> PackedVector2Array:
	var ax := minf(rx, rect.size.x / 2.0)
	var ay := minf(ry, rect.size.y / 2.0)
	var pts := PackedVector2Array()
	var corners := [
		[Vector2(rect.end.x - ax, rect.position.y + ay), -PI / 2],
		[Vector2(rect.end.x - ax, rect.end.y - ay), 0.0],
		[Vector2(rect.position.x + ax, rect.end.y - ay), PI / 2],
		[Vector2(rect.position.x + ax, rect.position.y + ay), PI],
	]
	for c in corners:
		for i in segments + 1:
			var a: float = c[1] + (PI / 2) * i / segments
			pts.append(c[0] + Vector2(cos(a) * ax, sin(a) * ay))
	return pts


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	if rect.size.x < 4 or rect.size.y < 4:
		return
	# Depth: a broad soft shadow below, a tight one hugging the edge.
	for i in 5:
		var grow := 6.0 + i * 7.0
		var r := Rect2(rect.position + Vector2(0, 14), rect.size).grow(grow * 0.5)
		draw_colored_polygon(outline(r), Color(0, 0, 0, 0.11))
	draw_colored_polygon(outline(rect.grow(2)), Color(0, 0, 0, 0.25))

	var pts := outline(rect)
	var center := rect.get_center() + Vector2(0, -0.15 * rect.size.y / 2.0)
	var radius := 0.85 * minf(rect.size.x, rect.size.y)
	var uvs := PackedVector2Array()
	for p in pts:
		uvs.append(Vector2(0.5, 0.5) + (p - center) / (2.0 * radius))
	draw_polygon(pts, PackedColorArray([Color.WHITE]), uvs, _sheen)
	var rim := pts.duplicate()
	rim.append(pts[0])
	draw_polyline(rim, Settings.palette()["felt"][2], 1.0, true)

	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, Color(Tokens.GOLD_BORDER, 0.28), 2.0, true)

	var inner_size := rect.size * Vector2(0.72, 0.66)
	var inner := Rect2(rect.get_center() - inner_size / 2.0, inner_size)
	var ring := outline(inner, 300.0, 220.0)
	ring.append(ring[0])
	draw_polyline(ring, Color(Tokens.GOLD_BORDER, 0.12), 1.0, true)
