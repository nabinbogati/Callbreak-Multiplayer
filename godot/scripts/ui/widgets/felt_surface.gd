class_name FeltSurface
extends Control

## The playing surface: a leather rail with a gold inlay around a lit felt,
## plus two live layers on top of the static paint — a spotlight that swings
## toward whoever is to act, and a large faint suit mark in the middle (the
## trump spade between tricks, the led suit during one). The felt itself is
## drawn once per size or theme; the live layers redraw only while they move.

## The seat being waited on (a [enum SeatView.Slot]), or -1 when nobody is
## (the spotlight fades).
var spotlight := -1:
	set(v):
		if v != spotlight:
			spotlight = v
			_spot.aim(v)
## The suit led in the trick under way, or -1 between tricks.
var lead_suit := -1:
	set(v):
		if v != lead_suit:
			lead_suit = v
			_mark.show_suit(v)

var _base := _Base.new()
var _mark := _LeadMark.new()
var _spot := _Spotlight.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for layer in [_base, _mark, _spot]:
		layer.set_anchors_preset(Control.PRESET_FULL_RECT)
		layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(layer)
	Settings.changed.connect(_base.queue_redraw)


## The table's outline: a stadium whose ends are true semi-ellipses.
static func table_radii(size_in: Vector2) -> Vector2:
	return Vector2(size_in.x / 2.0, minf(size_in.y / 2.0, size_in.x * 0.62))


static func rail_width(size_in: Vector2) -> float:
	return minf(size_in.x, size_in.y) * 0.055


## A rounded rect with elliptical corners ([param radii]), as a polygon.
static func outline(rect: Rect2, radii: Vector2, segments := 20) -> PackedVector2Array:
	var ax := clampf(radii.x, 0.0, rect.size.x / 2.0)
	var ay := clampf(radii.y, 0.0, rect.size.y / 2.0)
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
			var p: Vector2 = c[0] + Vector2(cos(a) * ax, sin(a) * ay)
			# A full stadium end leaves no straight edge between two corners:
			# their shared point must appear once for the polygon to triangulate.
			if pts.is_empty() or p.distance_squared_to(pts[pts.size() - 1]) > 0.0001:
				pts.append(p)
	if pts.size() > 1 and pts[0].distance_squared_to(pts[pts.size() - 1]) <= 0.0001:
		pts.remove_at(pts.size() - 1)
	return pts


## The table outline shrunk by [param d] on every side, radii included — the
## way a Flutter RRect deflates.
static func deflated(size_in: Vector2, d: float) -> PackedVector2Array:
	var r := table_radii(size_in)
	return outline(Rect2(Vector2.ONE * d, size_in - Vector2.ONE * 2.0 * d), r - Vector2.ONE * d)


static func _stroke(ci: CanvasItem, pts: PackedVector2Array, color: Color, width: float) -> void:
	Draw.stroke(ci, pts, true, color, width)


class _Base:
	extends Control

	func _init() -> void:
		resized.connect(queue_redraw)

	func _draw() -> void:
		if size.x < 8 or size.y < 8:
			return
		var palette := Settings.palette()
		var felt_colors: Array = palette["felt"]
		var rail := FeltSurface.rail_width(size)
		var radii := FeltSurface.table_radii(size)
		var outer := FeltSurface.outline(Rect2(Vector2.ZERO, size), radii)

		# Cast shadow, so the table sits on the room rather than being printed
		# on it: layers of the outline spreading out and fading.
		var sigma := rail * 0.9
		const LAYERS := 10
		for i in LAYERS:
			var grow := sigma * 2.4 * (float(i) / (LAYERS - 1) - 0.4)
			var r := Rect2(Vector2(-grow, rail * 0.5 - grow), size + Vector2.ONE * 2.0 * grow)
			draw_colored_polygon(FeltSurface.outline(r, radii + Vector2.ONE * grow), Color(0, 0, 0, 0.55 / LAYERS))

		# Dark leather rail, tinted toward the felt so every colourway agrees.
		var leather := Color("#2B231E").lerp(felt_colors[2], 0.22)
		Draw.fill_linear(self, outer, Vector2.ZERO, Vector2(0, size.y),
				[leather.lerp(Color.WHITE, 0.1), leather, leather.lerp(Color.BLACK, 0.45)])
		FeltSurface._stroke(self, FeltSurface.deflated(size, 0.75), Color("#FFFFFF1F"), 1.5)

		# Gold inlay running round the rail.
		FeltSurface._stroke(self, FeltSurface.deflated(size, rail * 0.5), Color(Tokens.GOLD_BORDER, 0.55), 1.3)

		# The felt: lit from just above centre, falling off toward the rail.
		var felt_rect := Rect2(Vector2.ONE * rail, size - Vector2.ONE * 2.0 * rail)
		var felt := FeltSurface.deflated(size, rail)
		Draw.fill_radial(self, felt, Draw.align(felt_rect, Vector2(0, -0.12)),
				0.78 * minf(felt_rect.size.x, felt_rect.size.y),
				[(felt_colors[0] as Color).lerp(Color.WHITE, 0.06), felt_colors[1], felt_colors[2]], [0.0, 0.62, 1.0])

		# Where the felt meets the rail: a dark lip and a faint highlight inside it.
		FeltSurface._stroke(self, FeltSurface.deflated(size, rail * 1.12), Color("#00000073"), rail * 0.3)
		FeltSurface._stroke(self, FeltSurface.deflated(size, rail * 1.32), Color("#FFFFFF14"), 1.0)

		# The faint "pot" ring.
		FeltSurface._stroke(self, FeltSurface.deflated(size, rail + minf(size.x, size.y) * 0.16),
				Color(Tokens.GOLD_BORDER, 0.13), 1.0)


## Big, faint suit mark at the centre of the felt, cross-fading (with a little
## zoom) whenever the suit changes.
class _LeadMark:
	extends Control

	var _suit := -1
	var _old := -1
	var _t := 1.0

	func _init() -> void:
		resized.connect(queue_redraw)
		set_process(false)

	func show_suit(suit: int) -> void:
		_old = _suit
		_suit = suit
		_t = 0.0
		set_process(true)

	func _process(delta: float) -> void:
		_t = minf(_t + delta / 0.32, 1.0)
		if _t >= 1.0:
			set_process(false)
		queue_redraw()

	static func _color(suit: int) -> Color:
		if suit < 0:
			return Color(Tokens.GOLD_BORDER, 0.08)
		if suit == Cards.Suit.HEARTS or suit == Cards.Suit.DIAMONDS:
			return Color("#FF6F6126")
		return Color("#FFFFFF1F")

	func _draw() -> void:
		var glyph := minf(size.x, size.y) * 0.34
		var c := size / 2.0
		if _t < 1.0:
			# The old mark leaves on a plain fade, as Flutter's switcher does.
			var out := 1.0 - _t
			var col := _color(_old)
			Draw.suit(self, Cards.TRUMP_SUIT if _old < 0 else _old, c, glyph * (0.8 + 0.2 * out),
					Color(col, col.a * out))
		var e := Motion.enter(_t)
		var col := _color(_suit)
		Draw.suit(self, Cards.TRUMP_SUIT if _suit < 0 else _suit, c, glyph * (0.8 + 0.2 * e), Color(col, col.a * e))


## A warm pool of light on the felt in front of the seat being waited on. It
## glides round the table (the short way) as the turn passes, so the eye is
## pulled to the next player without anything blinking.
class _Spotlight:
	extends Control

	var _from_angle := 0.0
	var _to_angle := 0.0
	var _from_intensity := 0.0
	var _to_intensity := 0.0
	var _t := 1.0

	func _init() -> void:
		resized.connect(queue_redraw)
		set_process(false)

	static func _angle_of(slot: int) -> float:
		match slot:
			SeatView.Slot.BOTTOM: return PI / 2
			SeatView.Slot.TOP: return -PI / 2
			SeatView.Slot.LEFT: return PI
		return 0.0

	func _eased() -> float:
		return Motion.emphasized(_t)

	func _angle() -> float:
		return _from_angle + (_to_angle - _from_angle) * _eased()

	func _intensity() -> float:
		return _from_intensity + (_to_intensity - _from_intensity) * _eased()

	func aim(slot: int) -> void:
		var angle := _angle()
		var intensity := _intensity()
		_from_angle = angle
		_from_intensity = intensity
		if slot < 0:
			_to_angle = angle
			_to_intensity = 0.0
		else:
			var target := _angle_of(slot)
			# Always travel the short way round.
			while target - angle > PI:
				target -= TAU
			while target - angle < -PI:
				target += TAU
			# Fading in from nothing: start already pointing at the seat.
			if intensity < 0.05:
				_from_angle = target
			_to_angle = target
			_to_intensity = 1.0
		_t = 0.0
		set_process(true)

	func _process(delta: float) -> void:
		_t = minf(_t + delta / 0.42, 1.0)
		if _t >= 1.0:
			set_process(false)
		queue_redraw()

	func _draw() -> void:
		var intensity := _intensity()
		if intensity <= 0.01 or size.x < 8:
			return
		var angle := _angle()
		var c := size / 2.0
		var focus := c + Vector2(cos(angle) * size.x * 0.4, sin(angle) * size.y * 0.4)
		var radius := minf(size.x, size.y) * 0.62
		var felt := FeltSurface.deflated(size, FeltSurface.rail_width(size))
		for pool in Geometry2D.intersect_polygons(Draw.ellipse_points(focus, Vector2.ONE * radius, 48), felt):
			Draw.fill_radial(self, pool, focus, radius, [Color(Tokens.TURN_GLOW, 0.26),
					Color(Tokens.TURN_GLOW, 0.09), Color(Tokens.TURN_GLOW, 0.0)], [0.0, 0.45, 1.0],
					Color(1, 1, 1, intensity))
