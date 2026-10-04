extends SceneTree

## Renders the main screens to PNGs for a visual check. Needs a display:
##   xvfb-run godot --path godot --rendering-driver opengl3 --resolution 780x1688 \
##       -s res://tests/screenshots.gd -- <out_dir>


func _initialize() -> void:
	_go.call_deferred()


func _go() -> void:
	root.add_child(load("res://tests/screenshot_steps.gd").new())
