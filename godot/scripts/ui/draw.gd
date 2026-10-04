class_name Draw
extends RefCounted

## Vector drawing shared by the custom widgets: suit glyphs, the app's icons,
## gradient fills and soft shadows. Suits are drawn from paths rather than a
## font so they render identically on every device — no emoji or symbol-font
## fallback to go missing; icons come from a bundled subset of the Material
## icon font, the same glyphs the design uses.


## One device pixel in design pixels. Edges are feathered by this much — the
## Compatibility renderer has no 2D MSAA, and Godot's own antialiased lines
## feather by a whole design pixel (two or three device pixels on a phone),
## which reads as a thick, soft border.
static func device_px() -> float:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return 0.5
	var k := tree.root.get_final_transform().get_scale().x
	return 1.0 / k if k > 0.0 else 1.0


## Fills a polygon with a one-device-pixel antialiased edge.
static func fill(ci: CanvasItem, points: PackedVector2Array, color: Color) -> void:
	ci.draw_colored_polygon(points, color)
	fringe(ci.get_canvas_item(), points, PackedColorArray([color]))


## [method fill] with per-vertex colours.
static func fill_colors(ci: CanvasItem, points: PackedVector2Array, colors: PackedColorArray) -> void:
	ci.draw_polygon(points, colors)
	fringe(ci.get_canvas_item(), points, colors)


## A one-device-pixel fade just outside a filled polygon's edge, from its edge
## colour to clear — the antialiasing for [method fill]. One colour, or one
## per point.
static func fringe(item: RID, points: PackedVector2Array, colors: PackedColorArray) -> void:
	_strip(item, points, true, colors, 0.0, device_px(), true)


## A line along [param points] (closed into a loop when [param closed]),
## [param width] wide, with one-device-pixel antialiased edges. Lines thinner
## than a device pixel draw as a pixel-wide line at proportionally less alpha.
static func stroke(ci: CanvasItem, points: PackedVector2Array, closed: bool, color: Color, width: float) -> void:
	stroke_rid(ci.get_canvas_item(), points, closed, PackedColorArray([color]), width)


static func stroke_rid(item: RID, points: PackedVector2Array, closed: bool, colors: PackedColorArray,
		width: float) -> void:
	_strip(item, points, closed, colors, width, device_px(), false)


## Builds the triangle strip behind [method stroke] and [method fringe]: four
## rails per point — clear, solid, solid, clear — offset along the miter. As a
## fringe the strip runs from the outline outward only.
static func _strip(item: RID, points: PackedVector2Array, closed: bool, colors: PackedColorArray, width: float,
		f: float, outer_only: bool) -> void:
	var n := points.size()
	if n < 2:
		return
	var alpha_k := 1.0
	var half := width / 2.0
	if not outer_only and width < f:
		alpha_k = width / f
		half = f / 2.0
	var core := maxf(half - f / 2.0, 0.0)
	var reach := half + f / 2.0
	# Which way is "outside": a fringe hugs a clockwise or anticlockwise loop.
	var sign := 1.0
	if outer_only:
		var area := 0.0
		for i in n:
			var a := points[i]
			var b := points[(i + 1) % n]
			area += a.x * b.y - b.x * a.y
		sign = -1.0 if area > 0.0 else 1.0
	var verts := PackedVector2Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	var count := n if closed else n
	for i in count:
		var p := points[i]
		var prev := points[(i - 1 + n) % n] if (closed or i > 0) else p
		var next := points[(i + 1) % n] if (closed or i < n - 1) else p
		var d1 := (p - prev).normalized() if p != prev else (next - p).normalized()
		var d2 := (next - p).normalized() if next != p else d1
		var n1 := Vector2(-d1.y, d1.x)
		var tangent := (d1 + d2)
		var normal := Vector2(-tangent.y, tangent.x).normalized() if tangent.length_squared() > 1e-8 else n1
		var miter := 1.0 / maxf(normal.dot(n1), 0.35)
		var nn := normal * miter * sign
		var c := colors[i] if colors.size() > 1 else colors[0]
		var solid := Color(c, c.a * alpha_k)
		var clear := Color(c, 0.0)
		if outer_only:
			verts.append_array([p, p + nn * f])
			cols.append_array([solid, clear])
		else:
			verts.append_array([p + nn * reach, p + nn * core, p - nn * core, p - nn * reach])
			cols.append_array([clear, solid, solid, clear])
	var rails := 2 if outer_only else 4
	var segments := n if closed else n - 1
	for i in segments:
		var a := i * rails
		var b := ((i + 1) % n) * rails
		for r in rails - 1:
			idx.append_array([a + r, b + r, b + r + 1, a + r, b + r + 1, a + r + 1])
	RenderingServer.canvas_item_add_triangle_array(item, idx, verts, cols)


## A filled circle with an antialiased edge.
static func disc(ci: CanvasItem, center: Vector2, radius: float, color: Color) -> void:
	fill(ci, ellipse_points(center, Vector2.ONE * radius, _circle_steps(radius)), color)


static func _circle_steps(radius: float) -> int:
	return clampi(int(radius * 2.0), 24, 96)


# ------------------------------------------------------------------ suits

## Width of a suit glyph relative to its height.
static func suit_aspect(suit_value: int) -> float:
	return 0.82 if suit_value == Cards.Suit.DIAMONDS else 1.0


## Draws a suit glyph [param size] tall, centred on [param center].
static func suit(ci: CanvasItem, suit_value: int, center: Vector2, size: float, color: Color) -> void:
	var box := Vector2(size * suit_aspect(suit_value), size)
	var origin := center - box / 2.0
	for poly in suit_polygons(suit_value):
		var pts := PackedVector2Array()
		pts.resize(poly.size())
		for i in poly.size():
			pts[i] = origin + poly[i] * box
		fill(ci, pts, color)


static var _suit_cache := {}


## The suit's outline in the unit square (0..1 on both axes), as one or more
## filled polygons. Built once per suit from the same curves the design uses.
static func suit_polygons(suit_value: int) -> Array:
	if _suit_cache.has(suit_value):
		return _suit_cache[suit_value]
	var shapes: Array = []
	match suit_value:
		Cards.Suit.HEARTS:
			shapes = [_path([[0.5, 0.95], ["c", 0.2, 0.72, 0.0, 0.52, 0.0, 0.3], ["c", 0.0, 0.13, 0.12, 0.03, 0.27, 0.03],
				["c", 0.38, 0.03, 0.46, 0.09, 0.5, 0.19], ["c", 0.54, 0.09, 0.62, 0.03, 0.73, 0.03],
				["c", 0.88, 0.03, 1.0, 0.13, 1.0, 0.3], ["c", 1.0, 0.52, 0.8, 0.72, 0.5, 0.95]])]
		Cards.Suit.DIAMONDS:
			shapes = [_path([[0.5, 0.0], ["q", 0.7, 0.3, 1.0, 0.5], ["q", 0.7, 0.7, 0.5, 1.0], ["q", 0.3, 0.7, 0.0, 0.5],
				["q", 0.3, 0.3, 0.5, 0.0]])]
		Cards.Suit.SPADES:
			shapes = [_path([[0.5, 0.0], ["c", 0.64, 0.17, 1.0, 0.36, 1.0, 0.6], ["c", 1.0, 0.75, 0.88, 0.84, 0.75, 0.84],
				["c", 0.65, 0.84, 0.57, 0.79, 0.53, 0.72], ["l", 0.47, 0.72], ["c", 0.43, 0.79, 0.35, 0.84, 0.25, 0.84],
				["c", 0.12, 0.84, 0.0, 0.75, 0.0, 0.6], ["c", 0.0, 0.36, 0.36, 0.17, 0.5, 0.0]]), _stem()]
		Cards.Suit.CLUBS:
			shapes = [_circle(Vector2(0.5, 0.26), 0.22), _circle(Vector2(0.24, 0.57), 0.22),
				_circle(Vector2(0.76, 0.57), 0.22), _circle(Vector2(0.5, 0.5), 0.14), _stem()]
	var merged: Array = [shapes[0]]
	for i in range(1, shapes.size()):
		var next: Array = []
		for poly in Geometry2D.merge_polygons(merged[0], shapes[i]):
			if not Geometry2D.is_polygon_clockwise(poly) or next.is_empty():
				next.append(poly)
		merged = next
	_suit_cache[suit_value] = merged
	return merged


## The flared foot shared by spades and clubs.
static func _stem() -> PackedVector2Array:
	return _path([[0.46, 0.6], ["q", 0.45, 0.9, 0.3, 1.0], ["l", 0.7, 1.0], ["q", 0.55, 0.9, 0.54, 0.6]])


static func _circle(c: Vector2, r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 48:
		var a := TAU * i / 48.0
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts


## Flattens a path: a start point, then segments — `["l", x, y]`,
## `["q", cx, cy, x, y]` or `["c", c1x, c1y, c2x, c2y, x, y]`.
static func _path(cmds: Array) -> PackedVector2Array:
	var pts := PackedVector2Array([Vector2(cmds[0][0], cmds[0][1])])
	const STEPS := 14
	for i in range(1, cmds.size()):
		var c: Array = cmds[i]
		var p0 := pts[pts.size() - 1]
		match c[0]:
			"l":
				pts.append(Vector2(c[1], c[2]))
			"q":
				var p1 := Vector2(c[1], c[2])
				var p2 := Vector2(c[3], c[4])
				for s in range(1, STEPS + 1):
					var t := float(s) / STEPS
					pts.append(p0 * (1 - t) * (1 - t) + p1 * 2 * (1 - t) * t + p2 * t * t)
			"c":
				var p1 := Vector2(c[1], c[2])
				var p2 := Vector2(c[3], c[4])
				var p3 := Vector2(c[5], c[6])
				for s in range(1, STEPS + 1):
					var t := float(s) / STEPS
					var u := 1.0 - t
					pts.append(p0 * u * u * u + p1 * 3 * u * u * t + p2 * 3 * u * t * t + p3 * t * t * t)
	if pts[pts.size() - 1].is_equal_approx(pts[0]):
		pts.remove_at(pts.size() - 1)
	return pts


# ------------------------------------------------------------- gradients

static var _textures := {}


## A cached horizontal gradient strip for [param stops] at [param offsets]
## (evenly spaced when empty).
static func linear_texture(stops: Array, offsets: Array = []) -> GradientTexture1D:
	var key := "l" + str(stops) + str(offsets)
	if not _textures.has(key):
		_trim_cache()
		var tex := GradientTexture1D.new()
		tex.gradient = _gradient(stops, offsets)
		tex.width = 256
		_textures[key] = tex
	return _textures[key]


## A cached radial gradient: the centre of the texture is offset 0, its
## inscribed circle's rim is offset 1.
static func radial_texture(stops: Array, offsets: Array = []) -> GradientTexture2D:
	var key := "r" + str(stops) + str(offsets)
	if not _textures.has(key):
		_trim_cache()
		var tex := GradientTexture2D.new()
		tex.gradient = _gradient(stops, offsets)
		tex.fill = GradientTexture2D.FILL_RADIAL
		tex.fill_from = Vector2(0.5, 0.5)
		tex.fill_to = Vector2(1.0, 0.5)
		tex.width = 128
		tex.height = 128
		_textures[key] = tex
	return _textures[key]


## A safety net: animated colours belong in a draw's tint, not in its stops.
static func _trim_cache() -> void:
	if _textures.size() > 200:
		_textures.clear()


static func _gradient(stops: Array, offsets: Array) -> Gradient:
	var g := Gradient.new()
	var offs := PackedFloat32Array()
	for i in stops.size():
		offs.append(offsets[i] if i < offsets.size() else (float(i) / maxf(stops.size() - 1, 1)))
	g.offsets = offs
	g.colors = PackedColorArray(stops)
	return g


## Fills [param points] with a linear gradient running from [param from] to
## [param to] (local pixels), clamped past either end — like a CSS or Flutter
## linear gradient, whatever the shape's vertex layout.
## [param tint] multiplies the whole fill — for fading a gradient in or out
## without minting a new gradient every frame.
static func fill_linear(ci: CanvasItem, points: PackedVector2Array, from: Vector2, to: Vector2, stops: Array,
		offsets: Array = [], rim := true, tint := Color.WHITE) -> void:
	if stops.size() == 1:
		if rim:
			fill(ci, points, stops[0] * tint)
		else:
			ci.draw_colored_polygon(points, stops[0] * tint)
		return
	var d := to - from
	var len2 := maxf(d.length_squared(), 0.0001)
	var uvs := PackedVector2Array()
	uvs.resize(points.size())
	for i in points.size():
		uvs[i] = Vector2(clampf((points[i] - from).dot(d) / len2, 0.002, 0.998), 0.5)
	ci.draw_polygon(points, PackedColorArray([tint]), uvs, linear_texture(stops, offsets))
	if rim:
		var colors := PackedColorArray()
		for p in points:
			colors.append(sample(stops, clampf((p - from).dot(d) / len2, 0.0, 1.0), offsets) * tint)
		fringe(ci.get_canvas_item(), points, colors)


## Fills [param points] with a circular gradient centred on [param center],
## reaching its last stop at [param radius] pixels.
static func fill_radial(ci: CanvasItem, points: PackedVector2Array, center: Vector2, radius: float, stops: Array,
		offsets: Array = [], tint := Color.WHITE) -> void:
	var uvs := PackedVector2Array()
	uvs.resize(points.size())
	var r := maxf(radius, 0.001)
	for i in points.size():
		uvs[i] = Vector2(0.5, 0.5) + (points[i] - center) / (2.0 * r)
	ci.draw_polygon(points, PackedColorArray([tint]), uvs, radial_texture(stops, offsets))


## A Flutter-style alignment (-1..1 on each axis) as a point in [param rect].
static func align(rect: Rect2, alignment: Vector2) -> Vector2:
	return rect.position + rect.size * (alignment + Vector2.ONE) / 2.0


## Samples colour [param stops] at [param t] in 0..1 ([param offsets] default
## to evenly spaced).
static func sample(stops: Array, t: float, offsets: Array = []) -> Color:
	if stops.size() == 1:
		return stops[0]
	if offsets.is_empty():
		var f := t * (stops.size() - 1)
		var i := mini(int(f), stops.size() - 2)
		return (stops[i] as Color).lerp(stops[i + 1], f - i)
	if t <= offsets[0]:
		return stops[0]
	for i in range(1, stops.size()):
		if t <= offsets[i]:
			var span: float = offsets[i] - offsets[i - 1]
			return (stops[i - 1] as Color).lerp(stops[i], (t - offsets[i - 1]) / maxf(span, 0.0001))
	return stops[stops.size() - 1]


## Per-vertex colours for a linear gradient across [param rect]
## (`vertical` top→bottom, else left→right) through [param stops].
static func gradient_colors(points: PackedVector2Array, rect: Rect2, stops: Array, vertical := true) -> PackedColorArray:
	var colors := PackedColorArray()
	for p in points:
		var t := (p.y - rect.position.y) / maxf(rect.size.y, 0.001) if vertical \
				else (p.x - rect.position.x) / maxf(rect.size.x, 0.001)
		colors.append(sample(stops, clampf(t, 0.0, 1.0)))
	return colors


# ----------------------------------------------------------------- shapes

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


## A rounded rect with only its top corners rounded.
static func top_rounded_rect_points(rect: Rect2, radius: float, segments := 6) -> PackedVector2Array:
	var r := minf(radius, minf(rect.size.x / 2.0, rect.size.y))
	var pts := PackedVector2Array()
	for i in segments + 1:
		var a := PI + (PI / 2) * i / segments
		pts.append(Vector2(rect.position.x + r, rect.position.y + r) + Vector2(cos(a), sin(a)) * r)
	for i in segments + 1:
		var a := -PI / 2 + (PI / 2) * i / segments
		pts.append(Vector2(rect.end.x - r, rect.position.y + r) + Vector2(cos(a), sin(a)) * r)
	pts.append(rect.end)
	pts.append(Vector2(rect.position.x, rect.end.y))
	return pts


static func ellipse_points(center: Vector2, radii: Vector2, steps := 64) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in steps:
		var a := TAU * i / steps
		pts.append(center + Vector2(cos(a) * radii.x, sin(a) * radii.y))
	return pts


## Fills a rounded rect with a gradient (`vertical` top→bottom, else
## left→right) and an optional antialiased border drawn inside its edge.
static func rounded_rect(ci: CanvasItem, rect: Rect2, radius: float, stops: Array, vertical := true,
		border := Color.TRANSPARENT, border_width := 0.0, offsets: Array = []) -> void:
	var pts := rounded_rect_points(rect, radius)
	var to := Vector2(rect.position.x, rect.end.y) if vertical else Vector2(rect.end.x, rect.position.y)
	fill_linear(ci, pts, rect.position, to, stops, offsets)
	stroke_rounded_rect(ci, rect, radius, border, border_width)


## A border just inside [param rect]'s edge, like a CSS / Flutter box border.
static func stroke_rounded_rect(ci: CanvasItem, rect: Rect2, radius: float, color: Color, width: float) -> void:
	if color.a <= 0.0 or width <= 0.0:
		return
	stroke(ci, rounded_rect_points(rect.grow(-width / 2.0), maxf(radius - width / 2.0, 0.0), 8), true, color, width)


## A circle's border drawn inside its edge.
static func circle_border(ci: CanvasItem, center: Vector2, radius: float, color: Color, width: float) -> void:
	if color.a <= 0.0 or width <= 0.0:
		return
	var r := radius - width / 2.0
	stroke(ci, ellipse_points(center, Vector2.ONE * r, _circle_steps(radius)), true, color, width)


static var _shadow_box := StyleBoxFlat.new()


## Soft drop shadows under a rounded rect: each entry of [param shadows] is
## `[colour, blur, offset]` or `[colour, blur, offset, spread]` (see
## [constant Tokens.SHADOW_LOW]), with blur meaning what a design-tool (or
## Flutter BoxShadow) blur radius means.
static func box_shadow(ci: CanvasItem, rect: Rect2, radius: float, shadows: Array) -> void:
	for s in shadows:
		var spread: float = s[3] if s.size() > 3 else 0.0
		var ramp := shadow_ramp(s[1])
		var inset := spread - ramp / 2.0
		ci.draw_style_box(_shadow_style(s[0], ramp, radius + inset), Rect2(rect.position + s[2], rect.size).grow(inset))


## The whole blurred silhouette — centre and fade — as Flutter paints a shadow,
## so a translucent box shows its shadow evenly through it.
static func _shadow_style(color: Color, ramp: float, radius: float, top_only := false) -> StyleBoxFlat:
	var sb := _shadow_box
	sb.draw_center = true
	# The shadow fills its interior only while the centre is drawn; the centre
	# itself stays clear so the interior is not painted twice.
	sb.bg_color = Color(color, 0.0)
	sb.anti_aliasing = false
	sb.corner_detail = 8
	sb.shadow_color = color
	sb.shadow_size = maxi(1, int(round(ramp)))
	sb.shadow_offset = Vector2.ZERO
	# A blur rounds every corner of what it blurs; a flat box only rounds its
	# fade where its own corners are round, and bevels them otherwise.
	sb.set_corner_radius_all(int(round(maxf(radius, ramp * 0.5))))
	if top_only:
		sb.corner_radius_bottom_left = 0
		sb.corner_radius_bottom_right = 0
	return sb


## The length of the linear fade that stands in for a Gaussian blur of
## [param blur]: a box's shadow then reads half-strength at the box's edge and
## falls off at the same rate a blur does there. (The blur's sigma is
## `blur × 0.577 + 0.5`, as Flutter and the web convert it.)
static func shadow_ramp(blur: float) -> float:
	return 2.5 * (blur * 0.57735 + 0.5)


## A soft drop shadow under a rounded rect.
static func shadow(ci: CanvasItem, rect: Rect2, radius: float, offset: Vector2, blur: float, color: Color) -> void:
	box_shadow(ci, rect, radius, [[color, blur, offset]])


# ------------------------------------------------------------------- icons

## Codepoints in the bundled Material icon subset, by Material name.
const ICONS := {
	"arrow_back_rounded": 0xf572, "arrow_forward_rounded": 0xf57a, "auto_awesome_rounded": 0xf596,
	"block_rounded": 0xf5be, "check_rounded": 0xf636, "chevron_right_rounded": 0xf63b,
	"close_rounded": 0xf647, "cloud_done_rounded": 0xf64c, "cloud_off_rounded": 0xf64e,
	"copy_rounded": 0xf66c, "devices_other_rounded": 0xf6a7, "devices_rounded": 0xf6a8,
	"emoji_events_rounded": 0xf707, "error_outline_rounded": 0xf712, "group_rounded": 0xf7c6,
	"history_rounded": 0xf7ef, "home_rounded": 0xf7f5, "hourglass_top_rounded": 0xf800,
	"inventory_2_outlined": 0xf134, "leaderboard_rounded": 0xf848, "logout_rounded": 0xf88b,
	"paste_rounded": 0xf66f, "person_add_alt_1_outlined": 0xf275, "person_outline_rounded": 0xf006c,
	"play_arrow_rounded": 0xf00a0, "public_rounded": 0xf00c6, "radar_rounded": 0xf00d6,
	"receipt_long_outlined": 0xf2ef, "refresh_rounded": 0xf00e9, "replay_rounded": 0xf00fc,
	"schedule_rounded": 0xf012b, "smart_toy_outlined": 0xf3a8, "smart_toy_rounded": 0xf019a,
	"sports_esports_outlined": 0xf3ca, "star_rounded": 0xf01d4, "sync_rounded": 0xf0207,
	"tag_rounded": 0xf0216, "touch_app_outlined": 0xf453, "touch_app_rounded": 0xf0245,
	"tune_rounded": 0xf0258, "verified_rounded": 0xf026e, "wifi_off_rounded": 0xf02bd,
	"wifi_rounded": 0xf02bf, "wifi_tethering_rounded": 0xf02c2, "workspace_premium_rounded": 0xf03c0,
}

## The short names the screens use.
const ALIASES := {
	"back": "arrow_back_rounded", "chevron_right": "chevron_right_rounded", "close": "close_rounded",
	"tune": "tune_rounded", "robot": "smart_toy_outlined", "crown": "workspace_premium_rounded",
	"person_add": "person_add_alt_1_outlined", "wifi": "wifi_rounded", "wifi_off": "wifi_off_rounded",
	"sync": "sync_rounded", "signal": "wifi_tethering_rounded", "touch": "touch_app_outlined",
	"check": "check_rounded", "copy": "copy_rounded",
}


## Draws one of the app's icons filling the square centred in [param rect].
static func icon(ci: CanvasItem, name: String, rect: Rect2, color: Color) -> void:
	var s := minf(rect.size.x, rect.size.y)
	if name == "spade":
		suit(ci, Cards.Suit.SPADES, rect.get_center(), s * 0.8, color)
		return
	var key: String = ALIASES.get(name, name)
	if not ICONS.has(key):
		push_warning("unknown icon %s" % name)
		return
	var size := maxi(1, int(round(s)))
	# The icon font's em square sits on the baseline with no descent.
	var pos := rect.get_center() + Vector2(-size / 2.0, size / 2.0)
	ci.draw_char(Tokens.font("icons"), pos, String.chr(ICONS[key]), size, color)
