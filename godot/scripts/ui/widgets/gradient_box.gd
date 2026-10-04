class_name GradientBox
extends StyleBox

## A rounded box with a linear gradient fill, optional border and soft
## shadows — what StyleBoxFlat cannot do (it has no gradients). Used for the
## gold buttons, glass panels, avatars and anything else the design paints
## with a gradient.

var stops: Array = [Color.WHITE]
## Where each of [member stops] sits, 0..1; evenly spaced when empty.
var offsets: Array = []
## Top→bottom when true, else left→right. Ignored when [member from_align] and
## [member to_align] are set.
var vertical := true
## Flutter-style alignments (-1..1) the gradient runs between, for diagonal
## fills. Both zero means "use [member vertical]".
var from_align := Vector2.ZERO
var to_align := Vector2.ZERO
var radius := 12.0
## Top corners only (a pedestal).
var top_only := false
var border_color := Color.TRANSPARENT
var border_width := 0.0
## Shadows as `[colour, blur, offset(, spread)]` entries, like
## [constant Tokens.SHADOW_HIGH]. The single-shadow fields below still work.
var shadows: Array = []
var shadow_color := Color.TRANSPARENT
var shadow_offset := Vector2.ZERO
var shadow_blur := 0.0


func _init(stops_in: Array = [Color.WHITE], radius_in := 12.0, vertical_in := false) -> void:
	stops = stops_in
	radius = radius_in
	vertical = vertical_in


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	var all := shadows.duplicate()
	if shadow_color.a > 0.0:
		all.append([shadow_color, shadow_blur, shadow_offset])
	for s in all:
		var spread: float = s[3] if s.size() > 3 else 0.0
		# See Draw.shadow_ramp for how a Gaussian blur maps onto this fade.
		var ramp := Draw.shadow_ramp(s[1])
		var inset := spread - ramp / 2.0
		Draw._shadow_style(s[0], ramp, radius + inset, top_only).draw(to_canvas_item,
				Rect2(rect.position + s[2], rect.size).grow(inset))

	var points := Draw.top_rounded_rect_points(rect, radius) if top_only else Draw.rounded_rect_points(rect, radius)
	var from := rect.position
	var to := Vector2(rect.position.x, rect.end.y) if vertical else Vector2(rect.end.x, rect.position.y)
	if from_align != Vector2.ZERO or to_align != Vector2.ZERO:
		from = Draw.align(rect, from_align)
		to = Draw.align(rect, to_align)
	var d := to - from
	var len2 := maxf(d.length_squared(), 0.0001)
	if stops.size() == 1:
		RenderingServer.canvas_item_add_polygon(to_canvas_item, points, PackedColorArray([stops[0]]))
	else:
		var uvs := PackedVector2Array()
		uvs.resize(points.size())
		for i in points.size():
			uvs[i] = Vector2(clampf((points[i] - from).dot(d) / len2, 0.002, 0.998), 0.5)
		RenderingServer.canvas_item_add_polygon(to_canvas_item, points, PackedColorArray([Color.WHITE]), uvs,
				Draw.linear_texture(stops, offsets).get_rid())
	# Antialiased rim: there is no 2D MSAA on the Compatibility renderer.
	var rim_colors := PackedColorArray()
	for p in points:
		rim_colors.append(Draw.sample(stops, clampf((p - from).dot(d) / len2, 0.0, 1.0), offsets))
	Draw.fringe(to_canvas_item, points, rim_colors)
	if border_color.a > 0.0 and border_width > 0.0:
		var r := maxf(radius - border_width / 2.0, 0.0)
		var inner := rect.grow(-border_width / 2.0)
		var inset := Draw.top_rounded_rect_points(inner, r, 8) if top_only else Draw.rounded_rect_points(inner, r, 8)
		Draw.stroke_rid(to_canvas_item, inset, true, PackedColorArray([border_color]), border_width)
