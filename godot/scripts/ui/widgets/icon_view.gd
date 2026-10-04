class_name IconView
extends Control

## One of the [Draw] icons as a control.

var icon_name := ""
var color := Color.WHITE:
	set(v):
		color = v
		queue_redraw()


func _init(name_in := "", size_in := 20.0, color_in := Color.WHITE) -> void:
	icon_name = name_in
	color = color_in
	custom_minimum_size = Vector2(size_in, size_in)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	Draw.icon(self, icon_name, Rect2(Vector2.ZERO, size), color)
