class_name GradientBox
extends StyleBox

## A rounded box with a linear gradient fill, optional border and soft shadow —
## what StyleBoxFlat cannot do (it has no gradients). Used for the gold
## buttons, avatars and anything else the design paints with a gradient.

var stops: Array = [Color.WHITE]
var vertical := true
var radius := 12.0
var border_color := Color.TRANSPARENT
var border_width := 0.0
var shadow_color := Color.TRANSPARENT
var shadow_offset := Vector2.ZERO
var shadow_blur := 0.0


func _init(stops_in: Array = [Color.WHITE], radius_in := 12.0, vertical_in := false) -> void:
	stops = stops_in
	radius = radius_in
	vertical = vertical_in


func _draw(to_canvas_item: RID, rect: Rect2) -> void:
	if shadow_color.a > 0.0:
		var layers := 4
		for i in layers:
			var grow := shadow_blur * float(i + 1) / layers
			var c := shadow_color
			c.a = shadow_color.a / layers
			var pts := Draw.rounded_rect_points(Rect2(rect.position + shadow_offset, rect.size).grow(grow * 0.5),
					radius + grow * 0.5)
			RenderingServer.canvas_item_add_polygon(to_canvas_item, pts, PackedColorArray([c]))
	var points := Draw.rounded_rect_points(rect, radius)
	var colors := Draw.gradient_colors(points, rect, stops, vertical)
	RenderingServer.canvas_item_add_polygon(to_canvas_item, points, colors)
	# Feathered rim: there is no 2D MSAA on the Compatibility renderer.
	var rim := points.duplicate()
	rim.append(points[0])
	var rim_colors := colors.duplicate()
	rim_colors.append(colors[0])
	RenderingServer.canvas_item_add_polyline(to_canvas_item, rim, rim_colors, 1.0, true)
	if border_color.a > 0.0 and border_width > 0.0:
		var inset := Draw.rounded_rect_points(rect.grow(-border_width / 2.0), maxf(radius - border_width / 2.0, 0.0))
		inset.append(inset[0])
		RenderingServer.canvas_item_add_polyline(to_canvas_item, inset, PackedColorArray([border_color]),
				border_width, true)
