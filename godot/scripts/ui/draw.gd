class_name Draw
extends RefCounted

## Vector drawing shared by the custom widgets: suit glyphs, the app's small
## icon set, and rounded shapes with gradient fills. Drawn rather than taken
## from a font so they render identically on every device — no emoji or
## symbol-font fallback to go missing.


## Fills a polygon with a feathered, antialiased edge. The Compatibility
## renderer has no 2D MSAA, so a hairline stroke in the fill colour softens the
## stair-stepped rim.
static func fill(ci: CanvasItem, points: PackedVector2Array, color: Color) -> void:
	ci.draw_colored_polygon(points, color)
	var closed := points.duplicate()
	closed.append(points[0])
	ci.draw_polyline(closed, color, 1.0, true)


## [method fill] with per-vertex colours (gradients).
static func fill_colors(ci: CanvasItem, points: PackedVector2Array, colors: PackedColorArray) -> void:
	ci.draw_polygon(points, colors)
	var closed := points.duplicate()
	closed.append(points[0])
	var c2 := colors.duplicate()
	c2.append(colors[0])
	ci.draw_polyline_colors(closed, c2, 1.0, true)


## Draws a suit glyph centred on [param center], [param size] tall.
static func suit(ci: CanvasItem, suit_value: int, center: Vector2, size: float, color: Color) -> void:
	match suit_value:
		Cards.Suit.HEARTS:
			fill(ci, _heart(center, size, false), color)
		Cards.Suit.DIAMONDS:
			var w := size * 0.36
			var h := size * 0.5
			fill(ci, PackedVector2Array([
				center + Vector2(0, -h), center + Vector2(w, 0),
				center + Vector2(0, h), center + Vector2(-w, 0)]), color)
		Cards.Suit.SPADES:
			var body := center + Vector2(0, -size * 0.08)
			fill(ci, _heart(body, size * 0.86, true), color)
			fill(ci, _stem(center, size), color)
		Cards.Suit.CLUBS:
			var r := size * 0.2
			ci.draw_circle(center + Vector2(0, -size * 0.24), r, color, true, -1.0, true)
			ci.draw_circle(center + Vector2(-size * 0.22, size * 0.04), r, color, true, -1.0, true)
			ci.draw_circle(center + Vector2(size * 0.22, size * 0.04), r, color, true, -1.0, true)
			ci.draw_circle(center + Vector2(0, -size * 0.04), r * 0.7, color, true, -1.0, true)
			fill(ci, _stem(center, size), color)


## The classic parametric heart, optionally upside down (a spade's body).
static func _heart(center: Vector2, size: float, inverted: bool) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var steps := 40
	var s := size / 34.0
	for i in steps:
		var t := TAU * i / steps
		var x := 16.0 * pow(sin(t), 3)
		var y := 13.0 * cos(t) - 5.0 * cos(2 * t) - 2.0 * cos(3 * t) - cos(4 * t)
		y = -y if not inverted else y
		pts.append(center + Vector2(x * s, (y + (1.5 if not inverted else -1.5)) * s))
	return pts


static func _stem(center: Vector2, size: float) -> PackedVector2Array:
	return PackedVector2Array([
		center + Vector2(-size * 0.05, size * 0.12),
		center + Vector2(size * 0.05, size * 0.12),
		center + Vector2(size * 0.2, size * 0.5),
		center + Vector2(-size * 0.2, size * 0.5)])


## A rounded rectangle outline as a polygon (clockwise), [param segments] per
## corner.
static func rounded_rect_points(rect: Rect2, radius: float, segments := 6) -> PackedVector2Array:
	var r := minf(radius, minf(rect.size.x, rect.size.y) / 2.0)
	var pts := PackedVector2Array()
	if r <= 0.5:
		return PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end,
				Vector2(rect.position.x, rect.end.y)])
	var corners := [
		[Vector2(rect.end.x - r, rect.position.y + r), -PI / 2],
		[Vector2(rect.end.x - r, rect.end.y - r), 0.0],
		[Vector2(rect.position.x + r, rect.end.y - r), PI / 2],
		[Vector2(rect.position.x + r, rect.position.y + r), PI],
	]
	for c in corners:
		for i in segments + 1:
			var a: float = c[1] + (PI / 2) * i / segments
			pts.append(c[0] + Vector2(cos(a), sin(a)) * r)
	return pts


static func ellipse_points(center: Vector2, radii: Vector2, steps := 64) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in steps:
		var a := TAU * i / steps
		pts.append(center + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	return pts


## Per-vertex colours for a linear gradient across [param rect]
## (`vertical` top→bottom, else left→right) through [param stops].
static func gradient_colors(points: PackedVector2Array, rect: Rect2, stops: Array, vertical := true) -> PackedColorArray:
	var colors := PackedColorArray()
	for p in points:
		var t := (p.y - rect.position.y) / maxf(rect.size.y, 0.001) if vertical \
				else (p.x - rect.position.x) / maxf(rect.size.x, 0.001)
		colors.append(sample(stops, clampf(t, 0.0, 1.0)))
	return colors


## Samples evenly spaced colour [param stops] at [param t] in 0..1.
static func sample(stops: Array, t: float) -> Color:
	if stops.size() == 1:
		return stops[0]
	var f := t * (stops.size() - 1)
	var i := mini(int(f), stops.size() - 2)
	return (stops[i] as Color).lerp(stops[i + 1], f - i)


## Fills a rounded rect with a gradient and an optional antialiased border.
static func rounded_rect(ci: CanvasItem, rect: Rect2, radius: float, stops: Array, vertical := true,
		border := Color.TRANSPARENT, border_width := 0.0) -> void:
	var pts := rounded_rect_points(rect, radius)
	fill_colors(ci, pts, gradient_colors(pts, rect, stops, vertical))
	if border.a > 0.0 and border_width > 0.0:
		var closed := pts.duplicate()
		closed.append(pts[0])
		ci.draw_polyline(closed, border, border_width, true)


## A soft drop shadow under a rounded rect, built from a few expanding,
## fading layers.
static func shadow(ci: CanvasItem, rect: Rect2, radius: float, offset: Vector2, blur: float,
		color: Color) -> void:
	var layers := 4
	for i in layers:
		var grow := blur * float(i + 1) / layers
		var c := color
		c.a = color.a / layers
		var r := Rect2(rect.position + offset, rect.size).grow(grow * 0.5)
		ci.draw_colored_polygon(rounded_rect_points(r, radius + grow * 0.5), c)


# ------------------------------------------------------------------- icons

## Draws one of the app's icons inside [param rect].
static func icon(ci: CanvasItem, name: String, rect: Rect2, color: Color) -> void:
	var c := rect.get_center()
	var s := minf(rect.size.x, rect.size.y)
	var w := maxf(1.5, s * 0.1)
	match name:
		"back":
			ci.draw_line(c + Vector2(s * 0.32, 0), c + Vector2(-s * 0.3, 0), color, w, true)
			ci.draw_polyline(PackedVector2Array([c + Vector2(-s * 0.02, -s * 0.3), c + Vector2(-s * 0.32, 0),
					c + Vector2(-s * 0.02, s * 0.3)]), color, w, true)
		"chevron_right":
			ci.draw_polyline(PackedVector2Array([c + Vector2(-s * 0.12, -s * 0.26), c + Vector2(s * 0.14, 0),
					c + Vector2(-s * 0.12, s * 0.26)]), color, w, true)
		"close":
			ci.draw_line(c + Vector2(-s, -s) * 0.26, c + Vector2(s, s) * 0.26, color, w, true)
			ci.draw_line(c + Vector2(s, -s) * 0.26, c + Vector2(-s, s) * 0.26, color, w, true)
		"tune":
			for i in 3:
				var y := c.y + (i - 1) * s * 0.3
				ci.draw_line(Vector2(c.x - s * 0.38, y), Vector2(c.x + s * 0.38, y), color, w * 0.9, true)
				var kx: float = c.x + [-0.16, 0.18, -0.04][i] * s
				ci.draw_circle(Vector2(kx, y), s * 0.1, color, true, -1.0, true)
		"robot":
			var head := Rect2(c + Vector2(-s * 0.32, -s * 0.18), Vector2(s * 0.64, s * 0.5))
			var closed := rounded_rect_points(head, s * 0.12)
			closed.append(closed[0])
			ci.draw_polyline(closed, color, w * 0.9, true)
			ci.draw_circle(c + Vector2(-s * 0.13, s * 0.06), s * 0.07, color, true, -1.0, true)
			ci.draw_circle(c + Vector2(s * 0.13, s * 0.06), s * 0.07, color, true, -1.0, true)
			ci.draw_line(c + Vector2(0, -s * 0.18), c + Vector2(0, -s * 0.34), color, w * 0.9, true)
			ci.draw_circle(c + Vector2(0, -s * 0.38), s * 0.06, color, true, -1.0, true)
		"crown":
			fill(ci, PackedVector2Array([
				c + Vector2(-s * 0.4, s * 0.28), c + Vector2(-s * 0.42, -s * 0.22), c + Vector2(-s * 0.18, 0),
				c + Vector2(0, -s * 0.34), c + Vector2(s * 0.18, 0), c + Vector2(s * 0.42, -s * 0.22),
				c + Vector2(s * 0.4, s * 0.28)]), color)
		"person_add":
			ci.draw_circle(c + Vector2(-s * 0.1, -s * 0.16), s * 0.16, color, false, w * 0.9, true)
			ci.draw_arc(c + Vector2(-s * 0.1, s * 0.36), s * 0.3, PI * 1.05, PI * 1.95, 16, color, w * 0.9, true)
			ci.draw_line(c + Vector2(s * 0.3, -s * 0.12), c + Vector2(s * 0.3, s * 0.16), color, w * 0.9, true)
			ci.draw_line(c + Vector2(s * 0.16, s * 0.02), c + Vector2(s * 0.44, s * 0.02), color, w * 0.9, true)
		"wifi", "wifi_off":
			var base := c + Vector2(0, s * 0.3)
			for i in 3:
				ci.draw_arc(base, s * (0.2 + 0.18 * i), PI * 1.25, PI * 1.75, 12, color, w * 0.85, true)
			ci.draw_circle(base, s * 0.06, color, true, -1.0, true)
			if name == "wifi_off":
				ci.draw_line(c + Vector2(-s * 0.4, -s * 0.4), c + Vector2(s * 0.4, s * 0.4), color, w, true)
		"sync":
			ci.draw_arc(c, s * 0.32, PI * 0.15, PI * 0.95, 14, color, w, true)
			ci.draw_arc(c, s * 0.32, PI * 1.15, PI * 1.95, 14, color, w, true)
			ci.draw_colored_polygon(_arrow_head(c + Vector2(cos(PI * 0.95), sin(PI * 0.95)) * s * 0.32, PI * 1.45, s * 0.16), color)
			ci.draw_colored_polygon(_arrow_head(c + Vector2(cos(PI * 1.95), sin(PI * 1.95)) * s * 0.32, PI * 0.45, s * 0.16), color)
		"signal":
			ci.draw_circle(c, s * 0.1, color, true, -1.0, true)
			ci.draw_arc(c, s * 0.24, -PI * 0.3, PI * 0.3, 10, color, w * 0.8, true)
			ci.draw_arc(c, s * 0.24, PI * 0.7, PI * 1.3, 10, color, w * 0.8, true)
			ci.draw_arc(c, s * 0.4, -PI * 0.3, PI * 0.3, 10, color, w * 0.8, true)
			ci.draw_arc(c, s * 0.4, PI * 0.7, PI * 1.3, 10, color, w * 0.8, true)
		"touch":
			ci.draw_circle(c, s * 0.12, color, true, -1.0, true)
			ci.draw_circle(c, s * 0.3, color, false, w * 0.7, true)
		"check":
			ci.draw_polyline(PackedVector2Array([c + Vector2(-s * 0.3, 0), c + Vector2(-s * 0.08, s * 0.22),
					c + Vector2(s * 0.32, -s * 0.22)]), color, w, true)
		"copy":
			var a := rounded_rect_points(Rect2(c + Vector2(-s * 0.3, -s * 0.18), Vector2(s * 0.42, s * 0.5)), s * 0.06)
			a.append(a[0])
			ci.draw_polyline(a, color, w * 0.8, true)
			var b := rounded_rect_points(Rect2(c + Vector2(-s * 0.12, -s * 0.36), Vector2(s * 0.42, s * 0.5)), s * 0.06)
			b.append(b[0])
			ci.draw_polyline(b, color, w * 0.8, true)
		"spade":
			suit(ci, Cards.Suit.SPADES, c, s * 0.8, color)


static func _arrow_head(tip: Vector2, angle: float, size: float) -> PackedVector2Array:
	var dir := Vector2(cos(angle), sin(angle))
	var perp := Vector2(-dir.y, dir.x)
	return PackedVector2Array([tip + dir * size * 0.6, tip - dir * size * 0.4 + perp * size * 0.5,
			tip - dir * size * 0.4 - perp * size * 0.5])
