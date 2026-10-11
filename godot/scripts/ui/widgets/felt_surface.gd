class_name FeltSurface
extends Control

## The playing surface: a leather rail with a gold inlay around a lit felt,
## and a large faint suit mark in the middle (the trump spade between tricks,
## the led suit during one). The felt is drawn once per size or theme, the mark
## once per suit; neither moves.

## The suit led in the trick under way, or -1 between tricks.
var lead_suit := -1:
	set(v):
		if v != lead_suit:
			lead_suit = v
			_mark.show_suit(v)

var _base := _Base.new()
var _mark := _LeadMark.new()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for layer in [_base, _mark]:
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
		# on it: one soft band fading out from the rail. Only the band is
		# painted, never the area under the table, which nobody sees — on a
		# cheap phone's GPU every layer over the whole table costs.
		var shadow := Draw.Batch.new()
		shadow.strip(outer, true, PackedColorArray([Color(0, 0, 0, 0.4)]), 0.0, rail * 1.6, true)
		shadow.flush(self)

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


## Big, faint suit mark at the centre of the felt, swapped whenever the suit
## changes.
class _LeadMark:
	extends Control

	var _suit := -1

	func _init() -> void:
		resized.connect(queue_redraw)

	func show_suit(suit: int) -> void:
		_suit = suit
		queue_redraw()

	static func _color(suit: int) -> Color:
		if suit < 0:
			return Color(Tokens.GOLD_BORDER, 0.08)
		if suit == Cards.Suit.HEARTS or suit == Cards.Suit.DIAMONDS:
			return Color("#FF6F6126")
		return Color("#FFFFFF1F")

	func _draw() -> void:
		Draw.suit(self, Cards.TRUMP_SUIT if _suit < 0 else _suit, size / 2.0, minf(size.x, size.y) * 0.34,
				_color(_suit))
